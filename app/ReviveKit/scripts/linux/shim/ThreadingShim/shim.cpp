// Works around libswiftObservation.so on Linux referencing a symbol libswiftCore does not export.
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
namespace swift { namespace threading {
[[noreturn]] void fatal(const char *msg, ...) {
  va_list ap; va_start(ap, msg); vfprintf(stderr, msg, ap); va_end(ap); abort();
}
}}
