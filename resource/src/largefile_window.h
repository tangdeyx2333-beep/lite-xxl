#ifndef LARGEFILE_WINDOW_H
#define LARGEFILE_WINDOW_H

#include <stddef.h>
#include <stdbool.h>

typedef struct LargeFileWindowLine {
  char *text;
  size_t len;
} LargeFileWindowLine;

typedef struct LargeFileWindowSnapshot {
  size_t start_line;
  size_t end_line;
  size_t requested_start_line;
  size_t requested_end_line;
  size_t margin;
  size_t epoch;
  LargeFileWindowLine *lines;
  size_t line_count;
} LargeFileWindowSnapshot;

void largefile_window_snapshot_init(LargeFileWindowSnapshot *snapshot);
void largefile_window_snapshot_reset(LargeFileWindowSnapshot *snapshot);
bool largefile_window_snapshot_reserve(LargeFileWindowSnapshot *snapshot, size_t line_count);

#endif
