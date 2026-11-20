// Shim: pre-ANSI <fstream.h> -> modern <fstream>, without pulling in all of
// namespace std (which would make ::byte ambiguous with std::byte).
#ifndef SHIM_FSTREAM_H
#define SHIM_FSTREAM_H
#include <fstream>
using std::ifstream;
using std::ofstream;
using std::fstream;
using std::ios;
using std::streamsize;
using std::ios_base;
#endif
