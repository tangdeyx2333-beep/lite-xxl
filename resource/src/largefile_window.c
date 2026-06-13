#include "largefile_window.h"

#include <SDL3/SDL_stdinc.h>
#include <string.h>

void largefile_window_snapshot_init(LargeFileWindowSnapshot *snapshot) {
  memset(snapshot, 0, sizeof(*snapshot));
}

void largefile_window_snapshot_reset(LargeFileWindowSnapshot *snapshot) {
  if (!snapshot) return;
  for (size_t i = 0; i < snapshot->line_count; i++) {
    SDL_free(snapshot->lines[i].text);
  }
  SDL_free(snapshot->lines);
  memset(snapshot, 0, sizeof(*snapshot));
}

bool largefile_window_snapshot_reserve(LargeFileWindowSnapshot *snapshot, size_t line_count) {
  LargeFileWindowLine *lines = SDL_calloc(line_count, sizeof(LargeFileWindowLine));
  if (!lines) return false;
  largefile_window_snapshot_reset(snapshot);
  snapshot->lines = lines;
  snapshot->line_count = line_count;
  return true;
}
