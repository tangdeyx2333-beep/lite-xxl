#include "largefile_index.h"

#include <SDL3/SDL_stdinc.h>
#include <string.h>

void largefile_index_init(LargeFileIndex *index, uint64_t file_size) {
  memset(index, 0, sizeof(*index));
  index->file_size = file_size;
  largefile_index_append_line(index, 0);
}

void largefile_index_destroy(LargeFileIndex *index) {
  if (!index) return;
  SDL_free(index->line_offsets);
  memset(index, 0, sizeof(*index));
}

bool largefile_index_append_line(LargeFileIndex *index, uint64_t offset) {
  if (index->line_count > 0 && index->line_offsets[index->line_count - 1] == offset) {
    return true;
  }
  if (index->line_count >= index->line_capacity) {
    size_t next_capacity = index->line_capacity == 0 ? 1024 : index->line_capacity * 2;
    uint64_t *next_offsets = SDL_realloc(index->line_offsets, next_capacity * sizeof(uint64_t));
    if (!next_offsets) {
      return false;
    }
    index->line_offsets = next_offsets;
    index->line_capacity = next_capacity;
  }
  index->line_offsets[index->line_count++] = offset;
  return true;
}

size_t largefile_index_visible_line_count(const LargeFileIndex *index) {
  if (!index || index->line_count == 0) return 1;
  return index->line_count;
}

bool largefile_index_has_line_end(const LargeFileIndex *index, size_t line) {
  if (!index || line == 0 || line > largefile_index_visible_line_count(index)) return false;
  if (line < index->line_count) return true;
  return index->complete;
}

uint64_t largefile_index_line_start(const LargeFileIndex *index, size_t line) {
  if (!index || line == 0 || line > largefile_index_visible_line_count(index)) return 0;
  return index->line_offsets[line - 1];
}

uint64_t largefile_index_line_end(const LargeFileIndex *index, size_t line) {
  if (!index || line == 0) return 0;
  if (line < index->line_count) {
    return index->line_offsets[line];
  }
  return (uint64_t) index->file_size;
}
