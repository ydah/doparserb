#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#if defined(CUSTOM_LOCATION)
typedef struct { int offset; } YYLTYPE;
#define YYLTYPE_IS_TRIVIAL 0
#else
typedef struct { int first_line, first_column, last_line, last_column; } YYLTYPE;
#define YYLTYPE_IS_TRIVIAL 1
#endif

#include "runtime.inc"

static void parse(const char *mode)
{
  int i;
  YYLTYPE location = { 0 };
  DOPA_DECL();
  (void) location;
#if YYLTYPE_IS_TRIVIAL
  location.first_line = 3;
  location.first_column = 7;
#endif
  errno = EDOM;
  DOPA_BEGIN();
  DOPA_TOKEN(4, &location);
  DOPA_SHIFT(4, 2, 1);
  DOPA_REDUCE(3, 1, 2, 1);
  DOPA_REDUCE(5, 0, 3, 1);
  if (strcmp(mode, "eager") == 0)
    {
      DOPA_FLUSH();
      if (getchar() != 'x') exit(5);
    }
  if (strcmp(mode, "overflow") == 0 || strcmp(mode, "cutoff") == 0)
    {
      int fd = atoi(getenv("DOPAPARSER_FD"));
      int flags = 0;
      char padding[2048] = "padding";
#ifdef MSG_DONTWAIT
      flags = MSG_DONTWAIT;
#else
      if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) exit(7);
#endif
      DOPA_FLUSH();
      while (send(fd, padding, sizeof padding, flags) >= 0) {}
      while (send(fd, padding, 1, flags) >= 0) {}
      errno = EDOM;
      for (i = 0; i < (strcmp(mode, "cutoff") == 0 ? 100 : 8); ++i)
        {
          DOPA_SHIFT(4, 2, 1);
          DOPA_FLUSH();
        }
      puts("drain");
      fflush(stdout);
      if (getchar() != 'x') exit(5);
    }
  if (strcmp(mode, "bulk") == 0)
    for (i = 0; i < 350; ++i) DOPA_SHIFT(4, 2, 1);
  DOPA_ERROR(3, 5, &location);
  DOPA_POP(1, 0);
  DOPA_ERROR_SHIFT(6, 1);
  DOPA_REPAIR_PLAN(2);
  DOPA_REPAIR_TOKEN(8);
  DOPA_REPAIR_DONE();
  DOPA_SHIFT(8, 9, 3);
  if (strcmp(mode, "abort") == 0) { DOPA_ABORT(); }
  else if (strcmp(mode, "exhausted") == 0) { DOPA_EXHAUSTED(); }
  else { DOPA_ACCEPT(); }
  DOPA_END();
  if (errno != EDOM) exit(6);
}

int main(int argc, char **argv)
{
  const char *mode = argc > 1 ? argv[1] : "all";
  parse(mode);
  if (strcmp(mode, "repeat") == 0) parse(mode);
  return 0;
}
