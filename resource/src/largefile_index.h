#ifndef LARGEFILE_INDEX_H
#define LARGEFILE_INDEX_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct LargeFileIndex {
  uint64_t *line_offsets;
  size_t line_count;
  size_t line_capacity;
  uint64_t file_size;
  bool complete;
  bool crlf;
} LargeFileIndex;

void largefile_index_init(LargeFileIndex *index, uint64_t file_size);
void largefile_index_destroy(LargeFileIndex *index);
bool largefile_index_append_line(LargeFileIndex *index, uint64_t offset);
size_t largefile_index_visible_line_count(const LargeFileIndex *index);
bool largefile_index_has_line_end(const LargeFileIndex *index, size_t line);
uint64_t largefile_index_line_start(const LargeFileIndex *index, size_t line);
uint64_t largefile_index_line_end(const LargeFileIndex *index, size_t line);

#endif
