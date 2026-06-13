#ifndef LARGEFILE_JOBS_H
#define LARGEFILE_JOBS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct LargeFileJobState {
  bool running;
  bool complete;
  bool failed;
  bool cancel_requested;
  uint64_t bytes_read;
  size_t lines_indexed;
  char error_message[256];
} LargeFileJobState;

void largefile_jobs_init(LargeFileJobState *state);
void largefile_jobs_fail(LargeFileJobState *state, const char *message);

#endif
