//==============================================================================
//
// OpenSPARC T1 VPI port: TF/acc shim layer (tfacc_vpi.cc)
//
// Maps the handful of VCS TF/acc calls used by the untouched SJM engine and
// main.cc onto the IEEE 1364 VPI API used by Icarus Verilog:
//
//   acc_initialize/acc_close    -> capture/forget the current systf instance
//   acc_handle_tfarg(n)         -> nth vpiArgument of the current systf call
//   acc_fetch_value(h, fmt)     -> vpi_get_value formatted to a rotating buffer
//   acc_set_value(accNoDelay)   -> vpi_put_value with vpiNoDelay
//   mc_scan_plusargs            -> scan of argv (via vpi_get_vlog_info)
//   tf_getp/tf_putp/...         -> same argument mechanism
//   dprintf                     -> simple printf logger (monitor.cc is VCS-only)
//   PLIModulesDone              -> constant 1 (no monitor modules in this port)
//
//==============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include <cctype>

#include "vpi_user.h"
#include "acc_user.h"
#include "veriuser.h"

// The -Ddprintf=... used for engine compiles is not set here; instead shadow
// the POSIX dprintf(int, ...) prototype locally.
#include <cstdio>
void sjm_dprintf(const char *mod_name, ...); // fwd decl (below), C++ linkage:
// engine sources see the renamed globals.h prototype with C++ linkage and
// reference the mangled symbol.
#define dprintf sjm_dprintf

extern "C" int PLIModulesDone(void);

//------------------------------------------------------------------------------

// Per-call state: the systf instance being serviced and its argument handles.
static vpiHandle cur_systf = NULL;
static vpiHandle cur_args[64];
static int       cur_nargs = 0;

void acc_initialize(void)
{
  cur_systf = vpi_handle(vpiSysTfCall, NULL);
  cur_nargs = 0;
  if (cur_systf) {
    vpiHandle arg, iter = vpi_iterate(vpiArgument, cur_systf);
    if (iter) {
      while ((arg = vpi_scan(iter)) != NULL && cur_nargs < 64) {
        cur_args[cur_nargs++] = arg;
      }
    }
  }
}

void acc_close(void)
{
  cur_systf = NULL;
  cur_nargs = 0;
}

handle acc_handle_tfarg(int n)
{
  if (n < 1 || n > cur_nargs) {
    vpi_printf("SJM VPI ERROR: acc_handle_tfarg(%d) out of range, systf has %d args\n",
               n, cur_nargs);
    return NULL;
  }
  return cur_args[n - 1];
}

int tf_typep(int n)
{
  vpiHandle h = acc_handle_tfarg(n);
  if (!h) return 0;
  return (int) vpi_get(vpiSize, h);
}

int tf_nump(void) { return cur_nargs; }

// Rotating pool of static buffers so several acc_fetch_value results can be
// live at once (front_set_inputs keeps up to ~G_MAXPORTS+10 pointers).
#define NVALBUF 64
#define VALBUF_SZ 1300
static char valbuf[NVALBUF][VALBUF_SZ];
static int  valbuf_next = 0;

static char *next_valbuf(void)
{
  char *p = valbuf[valbuf_next];
  valbuf_next = (valbuf_next + 1) % NVALBUF;
  return p;
}

char *acc_fetch_value(handle h, char *fmt, void *unused)
{
  (void) unused;
  if (!h) return NULL;

  s_vpi_value val;
  val.format = vpiIntVal;
  vpi_get_value(h, &val);

  char *out = next_valbuf();
  if (strcmp(fmt, "%d") == 0) {
    snprintf(out, VALBUF_SZ, "%d", val.value.integer);
  } else if (strcmp(fmt, "%b") == 0) {
    val.format = vpiBinStrVal;
    vpi_get_value(h, &val);
    snprintf(out, VALBUF_SZ, "%s", val.value.str ? val.value.str : "x");
  } else { // "%h", "%s", anything else -> decimal fallback
    snprintf(out, VALBUF_SZ, "%d", val.value.integer);
  }
  return out;
}

int tf_getp(int n)
{
  vpiHandle h = acc_handle_tfarg(n);
  if (!h) return 0;
  s_vpi_value val;
  val.format = vpiIntVal;
  vpi_get_value(h, &val);
  return val.value.integer;
}

char *tf_getcstringp(int n)
{
  vpiHandle h = acc_handle_tfarg(n);
  if (!h) return NULL;
  s_vpi_value val;
  val.format = vpiStringVal;
  vpi_get_value(h, &val);
  char *out = next_valbuf();
  snprintf(out, VALBUF_SZ, "%s", val.value.str ? val.value.str : "");
  return out;
}

void tf_putp(int n, int value)
{
  vpiHandle h = acc_handle_tfarg(n);
  if (!h) return;
  s_vpi_value val;
  val.format = vpiIntVal;
  val.value.integer = value;
  vpi_put_value(h, &val, NULL, vpiNoDelay);
}

char *tf_strgettime(void)
{
  static char tbuf[64];
  s_vpi_time t;
  t.type = vpiSimTime;
  vpi_get_time(NULL, &t);
  snprintf(tbuf, sizeof(tbuf), "%llu",
           (unsigned long long) t.high * 4294967296ULL + t.low);
  return tbuf;
}

int tf_dofinish(void) { vpi_control(vpiFinish, 1); return 0; }
int tf_dostop(void)   { vpi_control(vpiStop, 1);   return 0; }

//------------------------------------------------------------------------------

void acc_set_value(handle h, s_setval_value *vp, s_setval_delay *dp)
{
  (void) dp; // accNoDelay is the only model used; -> vpiNoDelay
  if (!h || !vp) return;

  s_vpi_value val;
  memset(&val, 0, sizeof(val));

  switch (vp->format) {
  case accBinStrVal:
    val.format = vpiBinStrVal;
    val.value.str = vp->value.str;
    break;
  case accHexStrVal:
    val.format = vpiHexStrVal;
    val.value.str = vp->value.str;
    break;
  case accStringVal:
    val.format = vpiStringVal;
    val.value.str = vp->value.str;
    break;
  case accIntVal:
  default:
    val.format = vpiIntVal;
    val.value.integer = vp->value.integer;
    break;
  }

  vpi_put_value(h, &val, NULL, vpiNoDelay);
}

//------------------------------------------------------------------------------

// VCS mc_scan_plusargs(name): scan the command line for +name[=value]; returns
// pointer to the value part (possibly "") or NULL if absent.
char *mc_scan_plusargs(char *name)
{
  static s_vpi_vlog_info info;
  static int initialized = 0;
  if (!initialized) {
    vpi_get_vlog_info(&info);
    initialized = 1;
  }
  size_t len = strlen(name);
  for (int i = 0; i < info.argc; i++) {
    char *a = info.argv[i];
    if (a && a[0] == '+' && strncmp(a + 1, name, len) == 0) {
      return a + 1 + len;
    }
  }
  return NULL;
}

//------------------------------------------------------------------------------

// Replacement for monitor.cc's VCS-only dprintf. Logs to stdout with a simple
// prefix; flags >= 4 are treated as errors. Message suppression counters of the
// old $dispmon system are not reproduced.
// Engine convention: dprintf(unit, tag, flags, "fmt", args...).
void sjm_dprintf(const char *mod_name, ...)
{
  va_list ap;
  va_start(ap, mod_name);
  int tag = va_arg(ap, int);
  int flags = va_arg(ap, int);
  const char *fmt = va_arg(ap, const char *);
  printf("SJM-%s[%s:%d] ", (flags >= 4) ? "ERR" : "MSG", mod_name, tag);
  vprintf(fmt, ap);
  printf("\n");
  fflush(stdout);
  va_end(ap);
}

//------------------------------------------------------------------------------

extern "C" int PLIModulesDone(void)
{
  // No $dispmon monitor modules are registered in this port.
  return 1;
}
