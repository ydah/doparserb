#include <pthread.h>
#define main harness_serial_main
#include "runtime_harness.c"
#undef main

static void *thread_parse(void *argument)
{
  int i;
  (void) argument;
  for (i = 0; i < 4; ++i) parse("all");
  return NULL;
}

int main(void)
{
  pthread_t threads[8];
  int i;
  for (i = 0; i < 8; ++i)
    if (pthread_create(&threads[i], NULL, thread_parse, NULL) != 0) return 8;
  for (i = 0; i < 8; ++i)
    if (pthread_join(threads[i], NULL) != 0) return 9;
  return 0;
}
