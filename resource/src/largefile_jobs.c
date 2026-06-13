#include "largefile_jobs.h"

#include <string.h>

void largefile_jobs_init(LargeFileJobState *state) {
  memset(state, 0, sizeof(*state));
  state->running = true;
}

void largefile_jobs_fail(LargeFileJobState *state, const char *message) {
  state->running = false;
  state->failed = true;
  if (!message) {
    state->error_message[0] = '\0';
    return;
  }
  strncpy(state->error_message, message, sizeof(state->error_message) - 1);
  state->error_message[sizeof(state->error_message) - 1] = '\0';
}
