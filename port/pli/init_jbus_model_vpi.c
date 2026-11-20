/*
 * port/pli/init_jbus_model_vpi.c - open-source $init_jbus_model shim.
 *
 * Legacy: verif/env/cmp/cmp_top.v:735 calls $init_jbus_model("mem.image")
 * (a Denali/SJM-front-end systf) to load the memory image into the DDR
 * models.  The open-source cmp_dram uses inert dimm_stub DIMMs with no
 * addressable storage, so this shim:
 *   1. reads the filename argument (or "+mem.image=<file>" plusarg form),
 *   2. if a real target array exists in the design, writes the image into
 *      it (currently cmp_top.mem_backdoor.mem, see port/env/mem_backdoor.v),
 *   3. otherwise reports and returns without error.
 *
 * Image format: $readmemh-style ASCII hex words; an optional "@<hexaddr>"
 * line sets the next word index (index = byte address >> 3 for
 * "mem.image"-style byte-addressed images).
 *
 * Build:  iverilog-vpi init_jbus_model_vpi.c   ->  init_jbus_model.vpi
 * Load:   vvp -M port/pli -m init_jbus_model ...
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vpi_user.h>

#define BACKDOOR_PATH "cmp_top.mem_backdoor.mem"

/*
 * IVPORT: functional-DIMM preload support.
 *
 * The functional DIMM (port/env/dram/dimm_mem.v) keeps a local array:
 *     reg [71:0] mem [0:(1<<MEM_AW)-1];   MEM_AW = 20
 * indexed by the LOW 20 bits of the flattened DRAM address faddr the
 * dimm model forms as
 *     faddr = { RowAddr[ba], ColAddr[10:2], ba, ColAddr[1:0] }
 * i.e.  index[1:0]=col[1:0]  [4:2]=bank  [13:5]=col[10:2]  [19:14]=row[5:0]
 *
 * PA -> dimm index (CALIBRATED from the RTL, reset-default config):
 *
 *   dram_addr_gen_lo.v, bank-high select (que_addr_bank_low_sel resets 0,
 *   dram_que.v:5103 dffrl), 4 channels (two_channel_mode=0), no stacked
 *   DIMM (chip_config_reg[0] resets 0, dram_que.v:4934 dffrl), no rank1
 *   (que_rank1_present), 8-bank mode (que_eight_bank_mode resets 1,
 *   dram_que.v:5114 dffsl), RAS width 0xF and CAS width 0xF (both reset
 *   all-1s, dram_que.v:4944/4960 dffsl).  With config_reg[4:1] != 4'hc the
 *   CAS-11 path applies:
 *
 *     ras  = PA[34:20]          (dram_addr_gen_lo.v:70-74)
 *     cas  = {0,0, PA[18], 1, PA[17:10], PA[5:4]}   (:242-244)
 *     bank = PA[10:8] ^ PA[20:18] ^ PA[30:28]       (:266)
 *     channel = PA[7:6]         (L2 bank interleave, 4 channels)
 *     rank = 0, stack = 0
 *
 *   The DIMM drives ColAddr = {addr[11], addr[9:0]} (dimm_mem.v:203), and
 *   cas_adr[13:11] are the two zero pads plus PA[18], so col[10] = PA[18]
 *   and col[9:0] = {PA[17:10], PA[5:4]}.  Flattening gives the index:
 *
 *     index[1:0]   = PA[5:4]
 *     index[4:2]   = PA[10:8] ^ PA[20:18] ^ PA[30:28]
 *     index[12:5]  = PA[17:10]
 *     index[13]    = PA[18]
 *     index[19:14] = PA[25:20]          (row low 6 bits; rows alias above)
 *
 *   Each 64-bit image word (PA aligned to 8) is written into the ONE
 *   channel it maps to, at that index.  The other seven DIMMs are left
 *   alone, so interleaved channels no longer alias onto each other.
 *   Known limits: PA above bit 25 aliases inside a DIMM (64-row window),
 *   and a DIMM only returns data the controller actually reads.
 */
#define DIMM_MEM_DEPTH (1u << 20)
#define DIMM_INDEX_MASK (DIMM_MEM_DEPTH - 1)

/* Channel a 64-bit-aligned PA lands in (L2 4-way bank interleave). */
static unsigned pa_channel(unsigned long long pa)
{
    return (unsigned)((pa >> 6) & 0x3u);
}

/* DIMM array index for a 64-bit-aligned PA.  See the header above. */
static unsigned long pa_dimm_index(unsigned long long pa)
{
    unsigned long long b;
    unsigned long idx = 0;

    idx |= (unsigned long)((pa >> 4) & 0x3u);                 /* col[1:0]  */
    b = ((pa >> 8) ^ (pa >> 18) ^ (pa >> 28)) & 0x7u;
    idx |= (unsigned long)(b << 2);                           /* bank      */
    idx |= (unsigned long)(((pa >> 10) & 0xffu) << 5);        /* col[9:2]  */
    idx |= (unsigned long)(((pa >> 18) & 0x1u) << 13);        /* col[10]   */
    idx |= (unsigned long)(((pa >> 20) & 0x3fu) << 14);       /* row[5:0]  */
    return idx & DIMM_INDEX_MASK;
}

static const char *dimm_paths[8] = {
    "cmp_top.cmp_dram.mem0.dimm0.mem",
    "cmp_top.cmp_dram.mem0.dimm1.mem",
    "cmp_top.cmp_dram.mem1.dimm0.mem",
    "cmp_top.cmp_dram.mem1.dimm1.mem",
    "cmp_top.cmp_dram.mem2.dimm0.mem",
    "cmp_top.cmp_dram.mem2.dimm1.mem",
    "cmp_top.cmp_dram.mem3.dimm0.mem",
    "cmp_top.cmp_dram.mem3.dimm1.mem",
};

/* Locate one DIMM memory array by name; NULL if absent. */
static vpiHandle find_dimm(const char *path)
{
    vpiHandle h = vpi_handle_by_name((PLI_BYTE8 *)path, NULL);
    return h;
}

/* Put a 64-bit value at one index of a memory array (vpi_handle_by_index). */
static int dimm_put(vpiHandle memh, unsigned long idx, unsigned long long val)
{
    vpiHandle word;
    s_vpi_value v;
    static char buf[32];

    word = vpi_handle_by_index(memh, (PLI_INT32)idx);
    if (word == NULL)
        return 0;
    snprintf(buf, sizeof(buf), "%016llx", (unsigned long long)val);
    v.format = vpiHexStrVal;
    v.value.str = buf;
    vpi_put_value(word, &v, NULL, vpiNoDelay);
    return 1;
}

static int dimm_get(vpiHandle memh, unsigned long idx, char *out, size_t outsz)
{
    vpiHandle word;
    s_vpi_value v;

    word = vpi_handle_by_index(memh, (PLI_INT32)idx);
    if (word == NULL)
        return 0;
    v.format = vpiHexStrVal;
    vpi_get_value(word, &v);
    snprintf(out, outsz, "%s", v.value.str ? v.value.str : "x");
    return 1;
}


/* Locate the back-door memory array; NULL if absent. */
static vpiHandle find_backdoor(void)
{
    /* try a few naming variants, iverilog top-scope naming differs by
     * how the bench is instantiated */
    static const char *candidates[] = {
        "cmp_top.mem_backdoor.mem",
        "cmp_top_probe.mem_backdoor.mem",
        "tb.mem_backdoor.mem",
        NULL
    };
    vpiHandle memh = NULL;
    for (int i = 0; candidates[i] != NULL && memh == NULL; i++) {
        memh = vpi_handle_by_name((PLI_BYTE8 *)candidates[i], NULL);
        if (memh != NULL)
            vpi_printf("[init_jbus_model] found backdoor at '%s'\n",
                       candidates[i]);
    }
    if (memh == NULL) {
        /* fall back to a hierarchy walk: cmp_top.mem_backdoor.<array> */
        vpiHandle top = vpi_handle_by_name((PLI_BYTE8 *)"cmp_top", NULL);
        if (top == NULL)
            top = vpi_handle_by_name((PLI_BYTE8 *)"tb", NULL);
        if (top != NULL) {
            vpiHandle it, ch;
            it = vpi_iterate(vpiModule, top);
            if (it) {
                while ((ch = vpi_scan(it)) != NULL) {
                    if (strcmp(vpi_get_str(vpiName, ch), "mem_backdoor") == 0) {
                        vpiHandle ait = vpi_iterate(vpiMemory, ch);
                        if (ait == NULL)
                            ait = vpi_iterate(vpiReg, ch);
                        if (ait) {
                            vpiHandle arr;
                            while ((arr = vpi_scan(ait)) != NULL) {
                                if (strcmp(vpi_get_str(vpiName, arr), "mem") == 0)
                                    memh = arr;
                                else
                                    vpi_free_object(arr);
                            }
                            if (!memh) vpi_free_object(ait);
                        }
                    } else {
                        vpi_free_object(ch);
                    }
                }
            }
            if (memh != NULL)
                vpi_printf("[init_jbus_model] found backdoor via hierarchy walk\n");
        }
    }
    return memh;
}

static unsigned long mem_left, mem_right;

static int word_in_range(unsigned long idx)
{
    if (mem_left <= mem_right)
        return (idx >= mem_left) && (idx <= mem_right);
    return (idx >= mem_right) && (idx <= mem_left);
}

static void write_word(vpiHandle memh, unsigned long idx,
                       unsigned long long val)
{
    vpiHandle iter, word;
    s_vpi_value v;
    unsigned long n;

    iter = vpi_iterate(vpiMemoryWord, memh);
    if (iter == NULL)
        return;
    n = 0;
    while ((word = vpi_scan(iter)) != NULL) {
        if (n == idx) {
            v.format = vpiHexStrVal;
            v.value.str = (PLI_BYTE8 *)"";
            /* compose hex string manually (64 bits) */
            {
                static char buf[32];
                snprintf(buf, sizeof(buf), "%016llx",
                         (unsigned long long)val);
                v.value.str = buf;
                vpi_put_value(word, &v, NULL, vpiNoDelay);
            }
            /* Cannot break out of vpi_scan early without leaking the
             * iterator; keep scanning to the end. */
        }
        n++;
        vpi_free_object(word);  /* no-op for scanned handles, safe */
    }
}

/* Parse $readmemh-style image and slam into the memory. */
static void load_image(vpiHandle memh, const char *fname)
{
    FILE *fp = fopen(fname, "r");
    char line[512];
    unsigned long idx = 0;
    unsigned long words = 0;
    int first_idx_valid = 0;
    unsigned long first_idx = 0;

    if (fp == NULL) {
        vpi_printf("[init_jbus_model] WARNING: image '%s' not found; "
                   "skipping (no error)\n", fname);
        return;
    }

    /* Discover array size.  NOTE: vpi_get(vpiLeft/RightRange) on an
     * Icarus vpiMemory may not reflect the address range, so derive the
     * bounds from vpiSize and index from 0 (image @addr is already
     * converted to a 0-based word index). */
    {
        long sz = vpi_get(vpiSize, memh);
        mem_left  = 0;
        mem_right = (sz > 0) ? (unsigned long)(sz - 1) : 0;
        vpi_printf("[init_jbus_model] backdoor size=%ld words\n", sz);
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        char *p = line;
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == '\0' || *p == '#' || *p == '/' || *p == '\n')
            continue;
        if (*p == '@') {
            idx = strtoul(p + 1, NULL, 16);
            /* mem.image addresses are byte addresses; index by word */
            idx = idx >> 3;
            continue;
        }
        if (!word_in_range(idx))
            continue;
        if (words == 0) {
            first_idx = idx;
            first_idx_valid = 1;
        }
        write_word(memh, idx, strtoull(p, NULL, 16));
        idx++;
        words++;
    }
    fclose(fp);
    vpi_printf("[init_jbus_model] loaded %lu words from '%s' into %s\n",
               words, fname, BACKDOOR_PATH);

    /* read-back sanity check of the first written word */
    if (words > 0 && first_idx_valid) {
        vpiHandle it2 = vpi_iterate(vpiMemoryWord, memh);
        if (it2 != NULL) {
            vpiHandle w2;
            unsigned long n2 = 0;
            while ((w2 = vpi_scan(it2)) != NULL) {
                if (n2 == first_idx) {
                    s_vpi_value rv;
                    rv.format = vpiHexStrVal;
                    vpi_get_value(w2, &rv);
                    vpi_printf("[init_jbus_model] read-back mem[%lu]=%s\n",
                               first_idx, rv.value.str ? rv.value.str : "x");
                }
                n2++;
            }
        }
    }
}

static PLI_INT32 init_jbus_model_calltf(PLI_BYTE8 *user_data)
{
    vpiHandle systf, argv, argh;
    s_vpi_value v;
    const char *fname = "mem.image";
    static char namebuf[512];

    (void) user_data;

    systf = vpi_handle(vpiSysTfCall, NULL);
    argv = vpi_iterate(vpiArgument, systf);
    if (argv != NULL) {
        argh = vpi_scan(argv);
        if (argh != NULL) {
            v.format = vpiStringVal;
            vpi_get_value(argh, &v);
            if (v.value.str != NULL) {
                strncpy(namebuf, v.value.str, sizeof(namebuf) - 1);
                namebuf[sizeof(namebuf) - 1] = '\0';
                /* accept "+mem.image=<file>" plusarg-style arg */
                if (strncmp(namebuf, "+mem.image=", 11) == 0)
                    fname = namebuf + 11;
                else if (namebuf[0] != '\0')
                    fname = namebuf;
            }
            vpi_free_object(argh);
        }
        vpi_free_object(argv);
    }

    vpi_printf("[init_jbus_model] request for image '%s'\n", fname);

    {
        vpiHandle memh = find_backdoor();
        if (memh != NULL) {
            load_image(memh, fname);
            vpi_free_object(memh);
        } else {
            vpi_printf("[init_jbus_model] NOTE: no backdoor memory at "
                       "'%s' (dimm_stub DIMMs are inert); image NOT "
                       "delivered to DDR. Real DRAM-content delivery is a "
                       "documented follow-up. Continuing without error.\n",
                       BACKDOOR_PATH);
        }
    }

    /* IVPORT: also preload the functional DIMM arrays (dimm_mem.v). */
    {
        vpiHandle dimm[8];
        int nd = 0, i;
        FILE *fp;
        char line[512];
        unsigned long widx = 0;         /* word number (byte addr >> 3) */
        unsigned long words = 0;
        unsigned long first_idx = 0;
        int first_valid = 0;
        char rb[64];

        for (i = 0; i < 8; i++) {
            dimm[i] = find_dimm(dimm_paths[i]);
            if (dimm[i] != NULL)
                nd++;
        }
        if (nd == 0) {
            vpi_printf("[init_jbus_model] no functional DIMM arrays found "
                       "(inert dimm_stub build?); image NOT written to "
                       "DDR storage\n");
        } else {
            vpi_printf("[init_jbus_model] found %d functional DIMM arrays "
                       "(cmp_top.cmp_dram.mem[0-3].dimm[0-1].mem)\n", nd);
            fp = fopen(fname, "r");
            if (fp == NULL) {
                vpi_printf("[init_jbus_model] WARNING: image '%s' not "
                           "found; skipping DIMM preload\n", fname);
            } else {
                while (fgets(line, sizeof(line), fp) != NULL) {
                    char *p = line;
                    while (*p == ' ' || *p == '\t')
                        p++;
                    if (*p == '\0' || *p == '#' || *p == '/' || *p == '\n')
                        continue;
                    if (*p == '@') {
                        /* mem.image addresses are byte addresses */
                        widx = strtoul(p + 1, NULL, 16) >> 3;
                        continue;
                    }
                    {
                        unsigned long long val = strtoull(p, NULL, 16);
                        unsigned long long pa = (unsigned long long)widx << 3;
                        unsigned ch = pa_channel(pa);
                        unsigned long di = pa_dimm_index(pa);
                        int ok = 0;
                        /* rank 0 of the channel the PA maps to */
                        if (dimm[2 * ch] != NULL)
                            ok = dimm_put(dimm[2 * ch], di, val);
                        if (ok && words == 0) {
                            first_idx = di;
                            first_valid = 1;
                        }
                        words++;
                    }
                    widx++;
                }
                fclose(fp);
                vpi_printf("[init_jbus_model] dimm preload: wrote %lu words "
                           "into %d DIMM arrays (calibrated PA->dimm map: "
                           "ch=PA[7:6], idx from dram_addr_gen_lo reset "
                           "config, one channel per word)\n",
                           words, nd);
                /* read-back sanity check of the first written word */
                if (first_valid && dimm_get(dimm[0], first_idx, rb, sizeof(rb))) {
                    vpi_printf("[init_jbus_model] dimm read-back "
                               "mem0.dimm0.mem[%lu]=%s\n", first_idx, rb);
                }
            }
        }
    }
    return 0;
}

static PLI_INT32 init_jbus_model_compiletf(PLI_BYTE8 *user_data)
{
    (void) user_data;
    return 0;
}

static void init_jbus_model_register(void)
{
    s_vpi_systf_data tf;
    vpiHandle h;

    tf.type      = vpiSysTask;
    tf.tfname    = (PLI_BYTE8 *)"$init_jbus_model";
    tf.calltf    = init_jbus_model_calltf;
    tf.compiletf = init_jbus_model_compiletf;
    tf.sizetf    = NULL;
    tf.user_data = NULL;
    h = vpi_register_systf(&tf);
    vpi_free_object(h);
}

/* iverilog-vpi looks for the vlog_startup_routines symbol table */
void (*vlog_startup_routines[])(void) = {
    init_jbus_model_register,
    0
};
