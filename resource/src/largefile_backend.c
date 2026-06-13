#include "largefile_backend.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_stdinc.h>

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <windows.h>
#include "utfconv.h"
#endif

#define LARGEFILE_INDEX_CHUNK_SIZE (256 * 1024)

typedef struct LargeFileSaveLine {
  char *text;
  size_t len;
} LargeFileSaveLine;

typedef struct LargeFileSaveAddBlock {
  long long id;
  LargeFileSaveLine *lines;
  size_t line_count;
  size_t line_capacity;
} LargeFileSaveAddBlock;

typedef struct LargeFileSaveAddStore {
  LargeFileSaveAddBlock *blocks;
  size_t count;
  size_t capacity;
} LargeFileSaveAddStore;

typedef struct LargeFileSavePiece {
  bool is_origin;
  long long source_id;
  size_t source_start_line;
  size_t line_count;
} LargeFileSavePiece;

typedef struct LargeFileSaveSnapshot {
  bool crlf;
  uint64_t source_mtime_ms;
  uint64_t source_size;
  LargeFileSavePiece *pieces;
  size_t piece_count;
  size_t piece_capacity;
} LargeFileSaveSnapshot;

typedef struct LargeFileSaveFileInfo {
  uint64_t modified_ms;
  uint64_t size;
} LargeFileSaveFileInfo;

static int largefile_backend_worker(void *userdata);
static int largefile_backend_save_worker(void *userdata);
static bool largefile_backend_try_prepare_window(LargeFileBackend *backend);
static bool largefile_backend_load_window(LargeFileBackend *backend, size_t start_line, size_t end_line, size_t requested_start_line, size_t requested_end_line, size_t margin, size_t epoch);
static bool largefile_backend_read_normalized_line(FILE *fp, const LargeFileBackend *backend, size_t line, char **buffer, size_t *len);
static bool largefile_read_normalized_line_from_index(FILE *fp, const LargeFileIndex *index, size_t line, char **buffer, size_t *len);

static size_t largefile_saturating_add_size(size_t a, size_t b) {
  return a > SIZE_MAX - b ? SIZE_MAX : a + b;
}

static FILE *largefile_open_utf8(const char *path, const char *mode) {
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  LPWSTR wmode = utfconv_utf8towc(mode);
  if (wpath == NULL || wmode == NULL) {
    SDL_free(wpath);
    SDL_free(wmode);
    return NULL;
  }
  FILE *fp = _wfopen(wpath, wmode);
  SDL_free(wpath);
  SDL_free(wmode);
  return fp;
#else
  return fopen(path, mode);
#endif
}

static int largefile_seek_u64(FILE *fp, uint64_t offset) {
#ifdef _WIN32
  return _fseeki64(fp, (__int64) offset, SEEK_SET);
#else
  return fseeko(fp, (off_t) offset, SEEK_SET);
#endif
}

static int largefile_seek_end(FILE *fp) {
#ifdef _WIN32
  return _fseeki64(fp, 0, SEEK_END);
#else
  return fseeko(fp, 0, SEEK_END);
#endif
}

static uint64_t largefile_tell_u64(FILE *fp) {
#ifdef _WIN32
  __int64 pos = _ftelli64(fp);
  return pos < 0 ? 0 : (uint64_t) pos;
#else
  off_t pos = ftello(fp);
  return pos < 0 ? 0 : (uint64_t) pos;
#endif
}

static size_t largefile_backend_align_chunk_start(const LargeFileBackend *backend, size_t line) {
  size_t chunk = backend && backend->chunk_line_count > 0 ? backend->chunk_line_count : 256;
  return ((SDL_max((size_t) 1, line) - 1) / chunk) * chunk + 1;
}

static size_t largefile_backend_align_chunk_end(const LargeFileBackend *backend, size_t line) {
  size_t chunk = backend && backend->chunk_line_count > 0 ? backend->chunk_line_count : 256;
  size_t start = largefile_backend_align_chunk_start(backend, line);
  return largefile_saturating_add_size(start, chunk - 1);
}

bool largefile_backend_module_available(void) {
  return true;
}

const char *largefile_backend_module_kind(void) {
  return "native-windowed-v1";
}

const char *largefile_backend_module_version(void) {
  return "native-windowed-v1";
}

static uint64_t get_file_size(FILE *fp) {
  if (largefile_seek_end(fp) != 0) {
    return 0;
  }
  uint64_t size = largefile_tell_u64(fp);
  if (size == 0 && ferror(fp)) return 0;
  rewind(fp);
  return size;
}

static void largefile_save_add_store_destroy(LargeFileSaveAddStore *store) {
  if (!store) return;
  for (size_t i = 0; i < store->count; i++) {
    LargeFileSaveAddBlock *block = &store->blocks[i];
    for (size_t j = 0; j < block->line_count; j++) {
      SDL_free(block->lines[j].text);
    }
    SDL_free(block->lines);
  }
  SDL_free(store->blocks);
  SDL_memset(store, 0, sizeof(*store));
}

static void largefile_save_snapshot_destroy(LargeFileSaveSnapshot *snapshot) {
  if (!snapshot) return;
  SDL_free(snapshot->pieces);
  SDL_memset(snapshot, 0, sizeof(*snapshot));
}

static void largefile_backend_clear_save_paths(LargeFileBackend *backend) {
  if (!backend) return;
  SDL_free(backend->save_job.snapshot_path);
  SDL_free(backend->save_job.add_buffer_path);
  SDL_free(backend->save_job.source_path);
  SDL_free(backend->save_job.target_path);
  backend->save_job.snapshot_path = NULL;
  backend->save_job.add_buffer_path = NULL;
  backend->save_job.source_path = NULL;
  backend->save_job.target_path = NULL;
}

static void largefile_backend_reset_save_job(LargeFileBackend *backend) {
  if (!backend) return;
  largefile_backend_clear_save_paths(backend);
  backend->save_job.active = false;
  backend->save_job.running = false;
  backend->save_job.complete = false;
  backend->save_job.failed = false;
  backend->save_job.cancel_requested = false;
  backend->save_job.written_bytes = 0;
  backend->save_job.total_bytes = 0;
  backend->save_job.error_message[0] = '\0';
}

static char *largefile_next_field(char **cursor) {
  if (!cursor || !*cursor) return NULL;
  char *start = *cursor;
  char *sep = SDL_strchr(start, '|');
  if (sep) {
    *sep = '\0';
    *cursor = sep + 1;
  } else {
    *cursor = NULL;
  }
  return start;
}

static uint64_t largefile_parse_u64(const char *text) {
#ifdef _WIN32
  return (uint64_t) _strtoui64(text ? text : "0", NULL, 10);
#else
  return (uint64_t) strtoull(text ? text : "0", NULL, 10);
#endif
}

static int64_t largefile_parse_i64(const char *text) {
#ifdef _WIN32
  return (int64_t) _strtoi64(text ? text : "0", NULL, 10);
#else
  return (int64_t) strtoll(text ? text : "0", NULL, 10);
#endif
}

static void largefile_trim_line_endings(char *line) {
  if (!line) return;
  size_t len = SDL_strlen(line);
  while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
    line[--len] = '\0';
  }
}

static bool largefile_read_line_dynamic(FILE *fp, char **line_out) {
  if (!fp || !line_out) return false;
  size_t len = 0;
  size_t cap = 256;
  char *buffer = SDL_malloc(cap);
  if (!buffer) return false;
  while (1) {
    int ch = fgetc(fp);
    if (ch == EOF) {
      if (ferror(fp) || len == 0) {
        SDL_free(buffer);
        return false;
      }
      break;
    }
    if (len + 2 > cap) {
      size_t next_cap = cap * 2;
      char *next = SDL_realloc(buffer, next_cap);
      if (!next) {
        SDL_free(buffer);
        return false;
      }
      buffer = next;
      cap = next_cap;
    }
    buffer[len++] = (char) ch;
    if (ch == '\n') {
      break;
    }
  }
  buffer[len] = '\0';
  *line_out = buffer;
  return true;
}

static int largefile_hex_value(char ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return 10 + (ch - 'a');
  if (ch >= 'A' && ch <= 'F') return 10 + (ch - 'A');
  return -1;
}

static char *largefile_hex_decode(const char *hex, size_t *len_out) {
  size_t hex_len = hex ? SDL_strlen(hex) : 0;
  if ((hex_len % 2) != 0) {
    return NULL;
  }
  char *buffer = SDL_malloc((hex_len / 2) + 1);
  if (!buffer) return NULL;
  size_t out_len = 0;
  for (size_t i = 0; i < hex_len; i += 2) {
    int hi = largefile_hex_value(hex[i]);
    int lo = largefile_hex_value(hex[i + 1]);
    if (hi < 0 || lo < 0) {
      SDL_free(buffer);
      return NULL;
    }
    buffer[out_len++] = (char) ((hi << 4) | lo);
  }
  buffer[out_len] = '\0';
  if (len_out) *len_out = out_len;
  return buffer;
}

static LargeFileSaveAddBlock *largefile_save_add_store_find_block(LargeFileSaveAddStore *store, long long id) {
  if (!store) return NULL;
  for (size_t i = 0; i < store->count; i++) {
    if (store->blocks[i].id == id) {
      return &store->blocks[i];
    }
  }
  return NULL;
}

static LargeFileSaveAddBlock *largefile_save_add_store_append_block(LargeFileSaveAddStore *store, long long id) {
  if (!store) return NULL;
  if (store->count >= store->capacity) {
    size_t next_capacity = store->capacity == 0 ? 16 : store->capacity * 2;
    LargeFileSaveAddBlock *next = SDL_realloc(store->blocks, next_capacity * sizeof(LargeFileSaveAddBlock));
    if (!next) return NULL;
    store->blocks = next;
    store->capacity = next_capacity;
  }
  LargeFileSaveAddBlock *block = &store->blocks[store->count++];
  SDL_memset(block, 0, sizeof(*block));
  block->id = id;
  return block;
}

static bool largefile_save_add_block_append_line(LargeFileSaveAddBlock *block, char *text, size_t len) {
  if (!block) return false;
  if (block->line_count >= block->line_capacity) {
    size_t next_capacity = block->line_capacity == 0 ? 32 : block->line_capacity * 2;
    LargeFileSaveLine *next = SDL_realloc(block->lines, next_capacity * sizeof(LargeFileSaveLine));
    if (!next) return false;
    block->lines = next;
    block->line_capacity = next_capacity;
  }
  block->lines[block->line_count].text = text;
  block->lines[block->line_count].len = len;
  block->line_count += 1;
  return true;
}

static bool largefile_save_snapshot_append_piece(LargeFileSaveSnapshot *snapshot, const LargeFileSavePiece *piece) {
  if (!snapshot || !piece) return false;
  if (snapshot->piece_count >= snapshot->piece_capacity) {
    size_t next_capacity = snapshot->piece_capacity == 0 ? 32 : snapshot->piece_capacity * 2;
    LargeFileSavePiece *next = SDL_realloc(snapshot->pieces, next_capacity * sizeof(LargeFileSavePiece));
    if (!next) return false;
    snapshot->pieces = next;
    snapshot->piece_capacity = next_capacity;
  }
  snapshot->pieces[snapshot->piece_count++] = *piece;
  return true;
}

static bool largefile_get_file_info_utf8(const char *path, LargeFileSaveFileInfo *info, char *error, size_t error_size) {
  if (!path || !info) return false;
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (!wpath) {
    if (error && error_size > 0) SDL_strlcpy(error, "utf8 path conversion failed", error_size);
    return false;
  }
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!GetFileAttributesExW(wpath, GetFileExInfoStandard, &data)) {
    if (error && error_size > 0) {
      SDL_snprintf(error, error_size, "GetFileAttributesExW failed (%lu)", (unsigned long) GetLastError());
    }
    SDL_free(wpath);
    return false;
  }
  SDL_free(wpath);
  ULARGE_INTEGER large_int = {0};
  large_int.HighPart = data.ftLastWriteTime.dwHighDateTime;
  large_int.LowPart = data.ftLastWriteTime.dwLowDateTime;
  {
    const uint64_t ticks_per_millisecond = 10000ULL;
    const uint64_t epoch_difference_ms = 11644473600000ULL;
    uint64_t filetime_ms = large_int.QuadPart / ticks_per_millisecond;
    info->modified_ms = filetime_ms > epoch_difference_ms ? (filetime_ms - epoch_difference_ms) : 0;
  }
  large_int.HighPart = data.nFileSizeHigh;
  large_int.LowPart = data.nFileSizeLow;
  info->size = large_int.QuadPart;
  return true;
#else
  struct stat s;
  if (stat(path, &s) < 0) {
    if (error && error_size > 0) SDL_strlcpy(error, strerror(errno), error_size);
    return false;
  }
  #if _BSD_SOURCE || _SVID_SOURCE || _XOPEN_SOURCE > 700 || _POSIX_C_SOURCE >= 200809L
    info->modified_ms = ((uint64_t) s.st_mtim.tv_sec * 1000ULL) + ((uint64_t) s.st_mtim.tv_nsec / 1000000ULL);
  #elif __APPLE__
    #if !defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)
      info->modified_ms = ((uint64_t) s.st_mtimespec.tv_sec * 1000ULL) + ((uint64_t) s.st_mtimespec.tv_nsec / 1000000ULL);
    #else
      info->modified_ms = (uint64_t) s.st_mtime * 1000ULL;
    #endif
  #else
    info->modified_ms = (uint64_t) s.st_mtime * 1000ULL;
  #endif
  info->size = (uint64_t) s.st_size;
  return true;
#endif
}

static char *largefile_make_temp_path(const char *target_path) {
  static const char *suffix = ".lite-xl-save.tmp";
  size_t target_len = target_path ? SDL_strlen(target_path) : 0;
  size_t suffix_len = SDL_strlen(suffix);
  char *path = SDL_malloc(target_len + suffix_len + 1);
  if (!path) return NULL;
  SDL_memcpy(path, target_path, target_len);
  SDL_memcpy(path + target_len, suffix, suffix_len + 1);
  return path;
}

static bool largefile_replace_file_utf8(const char *tmp_path, const char *target_path) {
#ifdef _WIN32
  LPWSTR wtmp = utfconv_utf8towc(tmp_path);
  LPWSTR wtarget = utfconv_utf8towc(target_path);
  if (!wtmp || !wtarget) {
    SDL_free(wtmp);
    SDL_free(wtarget);
    return false;
  }
  BOOL ok = MoveFileExW(wtmp, wtarget, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED | MOVEFILE_WRITE_THROUGH);
  SDL_free(wtmp);
  SDL_free(wtarget);
  return ok != 0;
#else
  return rename(tmp_path, target_path) == 0;
#endif
}

static void largefile_remove_file_utf8(const char *path) {
  if (!path) return;
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath) {
    DeleteFileW(wpath);
    SDL_free(wpath);
  }
#else
  remove(path);
#endif
}

static bool largefile_parse_snapshot_file(const char *path, LargeFileSaveSnapshot *snapshot, char *error, size_t error_size) {
  FILE *fp = largefile_open_utf8(path, "rb");
  if (!fp) {
    if (error && error_size > 0) SDL_strlcpy(error, strerror(errno), error_size);
    return false;
  }
  char *line = NULL;
  while (largefile_read_line_dynamic(fp, &line)) {
    largefile_trim_line_endings(line);
    if (SDL_strncmp(line, "CRLF|", 5) == 0) {
      snapshot->crlf = line[5] == '1';
    } else if (SDL_strncmp(line, "SOURCE_MTIME_MS|", 16) == 0) {
      size_t decoded_len = 0;
      char *decoded = largefile_hex_decode(line + 16, &decoded_len);
      if (!decoded) {
        if (error && error_size > 0) SDL_strlcpy(error, "invalid SOURCE_MTIME_MS", error_size);
        SDL_free(line);
        fclose(fp);
        return false;
      }
      snapshot->source_mtime_ms = largefile_parse_u64(decoded);
      SDL_free(decoded);
    } else if (SDL_strncmp(line, "SOURCE_SIZE|", 12) == 0) {
      size_t decoded_len = 0;
      char *decoded = largefile_hex_decode(line + 12, &decoded_len);
      if (!decoded) {
        if (error && error_size > 0) SDL_strlcpy(error, "invalid SOURCE_SIZE", error_size);
        SDL_free(line);
        fclose(fp);
        return false;
      }
      snapshot->source_size = largefile_parse_u64(decoded);
      SDL_free(decoded);
    } else if (SDL_strncmp(line, "PIECE|", 6) == 0) {
      char *fields = SDL_strdup(line + 6);
      char *ctx = fields;
      char *kind = largefile_next_field(&ctx);
      char *source_id = largefile_next_field(&ctx);
      char *source_start_line = largefile_next_field(&ctx);
      char *line_count = largefile_next_field(&ctx);
      LargeFileSavePiece piece;
      SDL_memset(&piece, 0, sizeof(piece));
      if (!kind || !source_start_line || !line_count) {
        SDL_free(fields);
        SDL_free(line);
        fclose(fp);
        if (error && error_size > 0) SDL_strlcpy(error, "invalid PIECE record", error_size);
        return false;
      }
      piece.is_origin = SDL_strcmp(kind, "origin") == 0;
      piece.source_id = source_id ? (long long) largefile_parse_i64(source_id) : 0;
      piece.source_start_line = (size_t) largefile_parse_u64(source_start_line);
      piece.line_count = (size_t) largefile_parse_u64(line_count);
      SDL_free(fields);
      if (!largefile_save_snapshot_append_piece(snapshot, &piece)) {
        SDL_free(line);
        fclose(fp);
        if (error && error_size > 0) SDL_strlcpy(error, "out of memory appending piece", error_size);
        return false;
      }
    }
    SDL_free(line);
    line = NULL;
  }
  fclose(fp);
  return snapshot->piece_count > 0;
}

static bool largefile_parse_add_file(const char *path, LargeFileSaveAddStore *store, char *error, size_t error_size) {
  FILE *fp = largefile_open_utf8(path, "rb");
  if (!fp) {
    if (error && error_size > 0) SDL_strlcpy(error, strerror(errno), error_size);
    return false;
  }
  char *line = NULL;
  LargeFileSaveAddBlock *current = NULL;
  while (largefile_read_line_dynamic(fp, &line)) {
    largefile_trim_line_endings(line);
    if (SDL_strncmp(line, "BLOCK|", 6) == 0) {
      char *fields = SDL_strdup(line + 6);
      char *ctx = fields;
      char *id = largefile_next_field(&ctx);
      if (!id) {
        SDL_free(fields);
        SDL_free(line);
        fclose(fp);
        if (error && error_size > 0) SDL_strlcpy(error, "invalid BLOCK record", error_size);
        return false;
      }
      current = largefile_save_add_store_append_block(store, (long long) largefile_parse_i64(id));
      SDL_free(fields);
      if (!current) {
        SDL_free(line);
        fclose(fp);
        if (error && error_size > 0) SDL_strlcpy(error, "out of memory appending add block", error_size);
        return false;
      }
    } else if (SDL_strncmp(line, "LINE|", 5) == 0) {
      size_t decoded_len = 0;
      char *decoded = largefile_hex_decode(line + 5, &decoded_len);
      if (!current || !decoded) {
        SDL_free(decoded);
        SDL_free(line);
        fclose(fp);
        if (error && error_size > 0) SDL_strlcpy(error, "invalid LINE record", error_size);
        return false;
      }
      if (!largefile_save_add_block_append_line(current, decoded, decoded_len)) {
        SDL_free(decoded);
        SDL_free(line);
        fclose(fp);
        if (error && error_size > 0) SDL_strlcpy(error, "out of memory appending add line", error_size);
        return false;
      }
    }
    SDL_free(line);
    line = NULL;
  }
  fclose(fp);
  return true;
}

static bool largefile_build_index_for_file(const char *path, LargeFileIndex *index, char *error, size_t error_size) {
  LargeFileSaveFileInfo info;
  if (!largefile_get_file_info_utf8(path, &info, error, error_size)) {
    return false;
  }
  FILE *fp = largefile_open_utf8(path, "rb");
  if (!fp) {
    if (error && error_size > 0) SDL_strlcpy(error, strerror(errno), error_size);
    return false;
  }
  largefile_index_init(index, info.size);
  char *buffer = SDL_malloc(LARGEFILE_INDEX_CHUNK_SIZE);
  if (!buffer) {
    fclose(fp);
    if (error && error_size > 0) SDL_strlcpy(error, "out of memory building source index", error_size);
    return false;
  }
  uint64_t offset = 0;
  bool last_was_cr = false;
  while (1) {
    size_t read = fread(buffer, 1, LARGEFILE_INDEX_CHUNK_SIZE, fp);
    if (read == 0) {
      if (feof(fp)) break;
      SDL_free(buffer);
      fclose(fp);
      if (error && error_size > 0) SDL_strlcpy(error, strerror(errno), error_size);
      largefile_index_destroy(index);
      return false;
    }
    for (size_t i = 0; i < read; i++) {
      char ch = buffer[i];
      if (ch == '\n') {
        uint64_t next_line_offset = offset + i + 1;
        if (next_line_offset < index->file_size && !largefile_index_append_line(index, next_line_offset)) {
          SDL_free(buffer);
          fclose(fp);
          if (error && error_size > 0) SDL_strlcpy(error, "source index append failed", error_size);
          largefile_index_destroy(index);
          return false;
        }
      }
      if (last_was_cr && ch == '\n') {
        index->crlf = true;
      }
      last_was_cr = (ch == '\r');
    }
    offset += read;
  }
  index->complete = true;
  SDL_free(buffer);
  fclose(fp);
  return true;
}

static bool largefile_write_output_line(FILE *fp, const char *text, size_t len, bool crlf, uint64_t *written_bytes) {
  if (!fp) return false;
  if (!crlf) {
    if (len > 0 && fwrite(text, 1, len, fp) != len) {
      return false;
    }
    if (written_bytes) *written_bytes += len;
    return true;
  }
  if (len > 0 && text[len - 1] == '\n') {
    if (len > 1 && fwrite(text, 1, len - 1, fp) != (len - 1)) {
      return false;
    }
    if (fwrite("\r\n", 1, 2, fp) != 2) {
      return false;
    }
    if (written_bytes) *written_bytes += len + 1;
    return true;
  }
  if (len > 0 && fwrite(text, 1, len, fp) != len) {
    return false;
  }
  if (written_bytes) *written_bytes += len;
  return true;
}

LargeFileBackend *largefile_backend_new(const char *path, size_t chunk_line_count) {
  if (!path) return NULL;

  FILE *fp = largefile_open_utf8(path, "rb");
  if (!fp) return NULL;
  uint64_t file_size = get_file_size(fp);
  fclose(fp);

  LargeFileBackend *backend = SDL_calloc(1, sizeof(LargeFileBackend));
  if (!backend) return NULL;

  backend->path = SDL_strdup(path);
  backend->file_size = file_size;
  backend->chunk_line_count = chunk_line_count > 0 ? chunk_line_count : 256;
  backend->mutex = SDL_CreateMutex();
  largefile_index_init(&backend->index, file_size);
  largefile_window_snapshot_init(&backend->snapshot);
  largefile_jobs_init(&backend->job);
  if (!backend->path || !backend->mutex) {
    largefile_backend_free(backend);
    return NULL;
  }

  backend->worker_thread = SDL_CreateThread(largefile_backend_worker, "largefile-index", backend);
  if (!backend->worker_thread) {
    largefile_backend_free(backend);
    return NULL;
  }
  return backend;
}

void largefile_backend_free(LargeFileBackend *backend) {
  if (!backend) return;
  if (backend->mutex) {
    SDL_LockMutex((SDL_Mutex *) backend->mutex);
    backend->job.cancel_requested = true;
    backend->save_job.cancel_requested = true;
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
  }
  if (backend->worker_thread) {
    SDL_WaitThread((SDL_Thread *) backend->worker_thread, NULL);
  }
  if (backend->save_thread) {
    SDL_WaitThread((SDL_Thread *) backend->save_thread, NULL);
  }
  if (backend->mutex) {
    SDL_DestroyMutex((SDL_Mutex *) backend->mutex);
  }
  largefile_backend_clear_save_paths(backend);
  SDL_free(backend->path);
  largefile_index_destroy(&backend->index);
  largefile_window_snapshot_reset(&backend->snapshot);
  SDL_free(backend);
}

const char *largefile_backend_kind(const LargeFileBackend *backend) {
  (void) backend;
  return largefile_backend_module_kind();
}

size_t largefile_backend_line_count(const LargeFileBackend *backend) {
  if (!backend) return 1;
  return SDL_max((size_t) 1, largefile_index_visible_line_count(&backend->index));
}

void largefile_backend_request_window(LargeFileBackend *backend, size_t start_line, size_t end_line, size_t margin) {
  if (!backend || !backend->mutex) return;
  if (start_line < 1) start_line = 1;
  if (end_line < start_line) end_line = start_line;
  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  backend->requested_start_line = start_line;
  backend->requested_end_line = end_line;
  backend->requested_margin = margin;
  backend->requested_epoch += 1;
  backend->request_dirty = true;
  largefile_backend_try_prepare_window(backend);
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
}

bool largefile_backend_poll_window(LargeFileBackend *backend, lua_State *L) {
  if (!backend || !backend->mutex) return false;
  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  largefile_backend_try_prepare_window(backend);
  if (!backend->snapshot_ready || backend->snapshot.line_count == 0) {
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
    return false;
  }

  lua_newtable(L);
  lua_pushinteger(L, (lua_Integer) backend->snapshot.start_line);
  lua_setfield(L, -2, "start_line");
  lua_pushinteger(L, (lua_Integer) backend->snapshot.end_line);
  lua_setfield(L, -2, "end_line");
  lua_pushinteger(L, (lua_Integer) backend->snapshot.requested_start_line);
  lua_setfield(L, -2, "requested_start_line");
  lua_pushinteger(L, (lua_Integer) backend->snapshot.requested_end_line);
  lua_setfield(L, -2, "requested_end_line");
  lua_pushinteger(L, (lua_Integer) backend->snapshot.margin);
  lua_setfield(L, -2, "margin");
  lua_pushinteger(L, (lua_Integer) backend->snapshot.epoch);
  lua_setfield(L, -2, "epoch");
  lua_pushinteger(L, (lua_Integer) backend->chunk_line_count);
  lua_setfield(L, -2, "chunk_line_count");

  lua_createtable(L, (int) backend->snapshot.line_count, 0);
  for (size_t i = 0; i < backend->snapshot.line_count; i++) {
    lua_pushlstring(L, backend->snapshot.lines[i].text, backend->snapshot.lines[i].len);
    lua_rawseti(L, -2, (int) i + 1);
  }
  lua_setfield(L, -2, "lines");

  backend->snapshot_ready = false;
  backend->delivered_epoch = backend->snapshot.epoch;
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
  return true;
}

bool largefile_backend_push_range_text(lua_State *L, LargeFileBackend *backend, size_t start_line, size_t start_col, size_t end_line, size_t end_col, bool inclusive) {
  if (!backend || !backend->mutex) return false;
  if (start_line == 0 || end_line == 0 || start_col == 0 || end_col == 0) return false;

  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  bool complete = backend->index.complete;
  bool has_end = largefile_index_has_line_end(&backend->index, end_line);
  size_t visible_count = largefile_index_visible_line_count(&backend->index);
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);

  if (!complete || !has_end || start_line > end_line || end_line > visible_count) {
    return false;
  }

  FILE *fp = largefile_open_utf8(backend->path, "rb");
  if (!fp) {
    return false;
  }

  char *result = NULL;
  size_t result_len = 0;
  size_t result_cap = 0;
  size_t col2_offset = inclusive ? 0 : 1;

  for (size_t line = start_line; line <= end_line; line++) {
    char *line_buffer = NULL;
    size_t line_len = 0;
    if (!largefile_backend_read_normalized_line(fp, backend, line, &line_buffer, &line_len)) {
      SDL_free(result);
      fclose(fp);
      return false;
    }

    size_t slice_start = 1;
    size_t slice_end = line_len;
    if (line == start_line) {
      slice_start = SDL_min(start_col, line_len);
    }
    if (line == end_line) {
      if (end_col <= col2_offset) {
        slice_end = 0;
      } else {
        slice_end = SDL_min(end_col - col2_offset, line_len);
      }
    }

    size_t slice_len = 0;
    if (slice_end >= slice_start && slice_start >= 1) {
      slice_len = slice_end - slice_start + 1;
    }

    if (slice_len > 0) {
      size_t needed = result_len + slice_len;
      if (needed > result_cap) {
        size_t next_cap = result_cap == 0 ? needed : result_cap;
        while (next_cap < needed) {
          next_cap = largefile_saturating_add_size(next_cap, SDL_max(next_cap, (size_t) 256));
          if (next_cap < needed) {
            SDL_free(line_buffer);
            SDL_free(result);
            fclose(fp);
            return false;
          }
        }
        char *next = SDL_realloc(result, next_cap);
        if (!next) {
          SDL_free(line_buffer);
          SDL_free(result);
          fclose(fp);
          return false;
        }
        result = next;
        result_cap = next_cap;
      }
      SDL_memcpy(result + result_len, line_buffer + slice_start - 1, slice_len);
      result_len += slice_len;
    }

    SDL_free(line_buffer);
  }

  fclose(fp);
  lua_pushlstring(L, result ? result : "", result_len);
  SDL_free(result);
  return true;
}

void largefile_backend_cancel_noncritical_work(LargeFileBackend *backend) {
  if (!backend || !backend->mutex) return;
  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  backend->request_dirty = false;
  backend->requested_start_line = 0;
  backend->requested_end_line = 0;
  backend->requested_margin = 0;
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
}

void largefile_backend_push_loading_state(lua_State *L, const LargeFileBackend *backend) {
  lua_newtable(L);
  lua_pushboolean(L, backend ? backend->job.running : 0);
  lua_setfield(L, -2, "loading");
  lua_pushboolean(L, backend ? backend->job.failed : 0);
  lua_setfield(L, -2, "failed");
  lua_pushboolean(L, backend ? backend->job.complete : 0);
  lua_setfield(L, -2, "complete");
  lua_pushstring(L, largefile_backend_module_kind());
  lua_setfield(L, -2, "backend_kind");
  lua_pushinteger(L, (lua_Integer) (backend ? backend->job.bytes_read : 0));
  lua_setfield(L, -2, "progress_bytes");
  lua_pushinteger(L, (lua_Integer) (backend ? backend->file_size : 0));
  lua_setfield(L, -2, "total_bytes");
  lua_pushinteger(L, (lua_Integer) (backend ? largefile_index_visible_line_count(&backend->index) : 1));
  lua_setfield(L, -2, "progress_lines");
  lua_pushinteger(L, (lua_Integer) (backend ? largefile_backend_line_count(backend) : 1));
  lua_setfield(L, -2, "line_count");
  lua_pushinteger(L, (lua_Integer) (backend ? backend->chunk_line_count : 256));
  lua_setfield(L, -2, "chunk_line_count");
  if (backend && backend->job.error_message[0] != '\0') {
    lua_pushstring(L, backend->job.error_message);
    lua_setfield(L, -2, "error");
  }
}

static bool largefile_read_normalized_line_from_index(FILE *fp, const LargeFileIndex *index, size_t line, char **buffer, size_t *len) {
  if (!fp || !index || !buffer || !len) return false;

  uint64_t start = largefile_index_line_start(index, line);
  uint64_t end = largefile_index_line_end(index, line);
  uint64_t raw_len_u64 = end >= start ? (end - start) : 0;
  if (raw_len_u64 > (uint64_t) (SIZE_MAX - 2)) {
    return false;
  }

  size_t raw_len = (size_t) raw_len_u64;
  char *line_buffer = SDL_malloc(raw_len + 2);
  if (!line_buffer) {
    return false;
  }

  if (largefile_seek_u64(fp, start) != 0) {
    SDL_free(line_buffer);
    return false;
  }
  if (raw_len > 0 && fread(line_buffer, 1, raw_len, fp) != raw_len) {
    SDL_free(line_buffer);
    return false;
  }

  size_t text_len = raw_len;
  if (text_len > 0 && line_buffer[text_len - 1] == '\n') text_len--;
  if (text_len > 0 && line_buffer[text_len - 1] == '\r') text_len--;
  line_buffer[text_len++] = '\n';
  line_buffer[text_len] = '\0';

  *buffer = line_buffer;
  *len = text_len;
  return true;
}

static bool largefile_backend_save_cancelled(LargeFileBackend *backend) {
  bool cancelled = false;
  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  cancelled = backend->save_job.cancel_requested;
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
  return cancelled;
}

static void largefile_backend_save_set_total_bytes(LargeFileBackend *backend, uint64_t total_bytes) {
  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  backend->save_job.total_bytes = total_bytes;
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
}

static void largefile_backend_save_set_written_bytes(LargeFileBackend *backend, uint64_t written_bytes) {
  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  backend->save_job.written_bytes = written_bytes;
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
}

static void largefile_backend_save_finish(LargeFileBackend *backend, bool ok, const char *message) {
  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  backend->save_job.running = false;
  backend->save_job.complete = ok;
  backend->save_job.failed = !ok;
  if (message) {
    SDL_strlcpy(backend->save_job.error_message, message, sizeof(backend->save_job.error_message));
  } else {
    backend->save_job.error_message[0] = '\0';
  }
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
}

static uint64_t largefile_output_line_size(const char *text, size_t len, bool crlf) {
  if (!crlf) {
    return (uint64_t) len;
  }
  if (len > 0 && text[len - 1] == '\n') {
    return (uint64_t) len + 1ULL;
  }
  return (uint64_t) len;
}

static bool largefile_compute_total_output_bytes(
  const LargeFileSaveSnapshot *snapshot,
  const LargeFileSaveAddStore *add_store,
  FILE *source_fp,
  const LargeFileIndex *source_index,
  uint64_t *total_bytes,
  char *error,
  size_t error_size
) {
  uint64_t total = 0;
  if (!snapshot || !source_index || !total_bytes) {
    if (error && error_size > 0) SDL_strlcpy(error, "invalid save total input", error_size);
    return false;
  }

  for (size_t piece_idx = 0; piece_idx < snapshot->piece_count; piece_idx++) {
    const LargeFileSavePiece *piece = &snapshot->pieces[piece_idx];
    if (piece->is_origin) {
      for (size_t offset = 0; offset < piece->line_count; offset++) {
        char *line_buffer = NULL;
        size_t line_len = 0;
        size_t line_no = piece->source_start_line + offset;
        if (!largefile_read_normalized_line_from_index(source_fp, source_index, line_no, &line_buffer, &line_len)) {
          if (error && error_size > 0) {
            SDL_snprintf(error, error_size, "failed to read source line %zu while computing size", line_no);
          }
          return false;
        }
        total += largefile_output_line_size(line_buffer, line_len, snapshot->crlf);
        SDL_free(line_buffer);
      }
    } else {
      LargeFileSaveAddBlock *block = largefile_save_add_store_find_block((LargeFileSaveAddStore *) add_store, piece->source_id);
      if (!block) {
        if (error && error_size > 0) SDL_snprintf(error, error_size, "missing add block %lld", piece->source_id);
        return false;
      }
      size_t start_idx = piece->source_start_line > 0 ? piece->source_start_line - 1 : 0;
      if (start_idx + piece->line_count > block->line_count) {
        if (error && error_size > 0) SDL_snprintf(error, error_size, "add block %lld line range out of bounds", piece->source_id);
        return false;
      }
      for (size_t offset = 0; offset < piece->line_count; offset++) {
        LargeFileSaveLine *line = &block->lines[start_idx + offset];
        total += largefile_output_line_size(line->text, line->len, snapshot->crlf);
      }
    }
  }

  *total_bytes = total;
  return true;
}

static int largefile_backend_save_worker(void *userdata) {
  LargeFileBackend *backend = userdata;
  LargeFileSaveSnapshot snapshot;
  LargeFileSaveAddStore add_store;
  LargeFileIndex source_index;
  LargeFileSaveFileInfo info_before;
  LargeFileSaveFileInfo info_after;
  FILE *source_fp = NULL;
  FILE *target_fp = NULL;
  char error[256] = {0};
  char *tmp_path = NULL;
  bool source_index_init = false;
  bool save_ok = false;

  SDL_memset(&snapshot, 0, sizeof(snapshot));
  SDL_memset(&add_store, 0, sizeof(add_store));
  SDL_memset(&source_index, 0, sizeof(source_index));

  if (!largefile_parse_snapshot_file(backend->save_job.snapshot_path, &snapshot, error, sizeof(error))) {
    largefile_backend_save_finish(backend, false, error[0] != '\0' ? error : "failed to parse snapshot");
    goto cleanup;
  }
  if (!largefile_parse_add_file(backend->save_job.add_buffer_path, &add_store, error, sizeof(error))) {
    largefile_backend_save_finish(backend, false, error[0] != '\0' ? error : "failed to parse add buffer");
    goto cleanup;
  }
  if (!largefile_get_file_info_utf8(backend->save_job.source_path, &info_before, error, sizeof(error))) {
    largefile_backend_save_finish(backend, false, error[0] != '\0' ? error : "failed to stat source");
    goto cleanup;
  }
  if ((snapshot.source_mtime_ms > 0 && info_before.modified_ms != snapshot.source_mtime_ms)
    || (snapshot.source_size > 0 && info_before.size != snapshot.source_size)) {
    largefile_backend_save_finish(backend, false, "source baseline changed before save");
    goto cleanup;
  }
  if (!largefile_build_index_for_file(backend->save_job.source_path, &source_index, error, sizeof(error))) {
    largefile_backend_save_finish(backend, false, error[0] != '\0' ? error : "failed to build source index");
    goto cleanup;
  }
  source_index_init = true;
  source_fp = largefile_open_utf8(backend->save_job.source_path, "rb");
  if (!source_fp) {
    largefile_backend_save_finish(backend, false, strerror(errno));
    goto cleanup;
  }
  {
    uint64_t total_bytes = 0;
    if (!largefile_compute_total_output_bytes(&snapshot, &add_store, source_fp, &source_index, &total_bytes, error, sizeof(error))) {
      largefile_backend_save_finish(backend, false, error[0] != '\0' ? error : "failed to compute output size");
      goto cleanup;
    }
    largefile_backend_save_set_total_bytes(backend, total_bytes);
  }

  tmp_path = largefile_make_temp_path(backend->save_job.target_path);
  if (!tmp_path) {
    largefile_backend_save_finish(backend, false, "failed to allocate temp path");
    goto cleanup;
  }
  target_fp = largefile_open_utf8(tmp_path, "wb");
  if (!target_fp) {
    largefile_backend_save_finish(backend, false, strerror(errno));
    goto cleanup;
  }

  uint64_t written_bytes = 0;
  uint64_t last_reported = 0;
  for (size_t piece_idx = 0; piece_idx < snapshot.piece_count; piece_idx++) {
    const LargeFileSavePiece *piece = &snapshot.pieces[piece_idx];
    if (largefile_backend_save_cancelled(backend)) {
      largefile_backend_save_finish(backend, false, "save cancelled");
      goto cleanup;
    }
    if (piece->is_origin) {
      for (size_t offset = 0; offset < piece->line_count; offset++) {
        char *line_buffer = NULL;
        size_t line_len = 0;
        size_t line_no = piece->source_start_line + offset;
        if (!largefile_read_normalized_line_from_index(source_fp, &source_index, line_no, &line_buffer, &line_len)) {
          largefile_backend_save_finish(backend, false, "failed to read source line");
          goto cleanup;
        }
        if (!largefile_write_output_line(target_fp, line_buffer, line_len, snapshot.crlf, &written_bytes)) {
          SDL_free(line_buffer);
          largefile_backend_save_finish(backend, false, strerror(errno));
          goto cleanup;
        }
        SDL_free(line_buffer);
        if (written_bytes - last_reported >= (256 * 1024)) {
          last_reported = written_bytes;
          largefile_backend_save_set_written_bytes(backend, written_bytes);
        }
      }
    } else {
      LargeFileSaveAddBlock *block = largefile_save_add_store_find_block(&add_store, piece->source_id);
      if (!block) {
        largefile_backend_save_finish(backend, false, "missing add block during save");
        goto cleanup;
      }
      size_t start_idx = piece->source_start_line > 0 ? piece->source_start_line - 1 : 0;
      if (start_idx + piece->line_count > block->line_count) {
        largefile_backend_save_finish(backend, false, "add block line range out of bounds");
        goto cleanup;
      }
      for (size_t offset = 0; offset < piece->line_count; offset++) {
        LargeFileSaveLine *line = &block->lines[start_idx + offset];
        if (!largefile_write_output_line(target_fp, line->text, line->len, snapshot.crlf, &written_bytes)) {
          largefile_backend_save_finish(backend, false, strerror(errno));
          goto cleanup;
        }
        if (written_bytes - last_reported >= (256 * 1024)) {
          last_reported = written_bytes;
          largefile_backend_save_set_written_bytes(backend, written_bytes);
        }
      }
    }
  }

  if (fflush(target_fp) != 0) {
    largefile_backend_save_finish(backend, false, strerror(errno));
    goto cleanup;
  }
  fclose(target_fp);
  target_fp = NULL;

  if (!largefile_get_file_info_utf8(backend->save_job.source_path, &info_after, error, sizeof(error))) {
    largefile_backend_save_finish(backend, false, error[0] != '\0' ? error : "failed to re-stat source");
    goto cleanup;
  }
  if ((snapshot.source_mtime_ms > 0 && info_after.modified_ms != snapshot.source_mtime_ms)
    || (snapshot.source_size > 0 && info_after.size != snapshot.source_size)) {
    largefile_backend_save_finish(backend, false, "source baseline changed during save");
    goto cleanup;
  }
  fclose(source_fp);
  source_fp = NULL;
  if (!largefile_replace_file_utf8(tmp_path, backend->save_job.target_path)) {
    largefile_backend_save_finish(backend, false, "failed to replace target file");
    goto cleanup;
  }
  largefile_backend_save_set_written_bytes(backend, written_bytes);
  largefile_backend_save_finish(backend, true, NULL);
  save_ok = true;

cleanup:
  if (source_fp) fclose(source_fp);
  if (target_fp) fclose(target_fp);
  if (tmp_path && !save_ok) {
    largefile_remove_file_utf8(tmp_path);
  }
  SDL_free(tmp_path);
  largefile_save_snapshot_destroy(&snapshot);
  largefile_save_add_store_destroy(&add_store);
  if (source_index_init) {
    largefile_index_destroy(&source_index);
  }
  return 0;
}

bool largefile_backend_begin_save(
  LargeFileBackend *backend,
  const char *snapshot_path,
  const char *add_buffer_path,
  const char *source_path,
  const char *target_path,
  const char **error_out
) {
  if (!backend || !backend->mutex) {
    if (error_out) *error_out = "invalid backend";
    return false;
  }
  if (!snapshot_path || !add_buffer_path || !source_path || !target_path) {
    if (error_out) *error_out = "missing save path";
    return false;
  }

  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  if (backend->save_job.running || backend->save_job.active) {
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
    if (error_out) *error_out = "save already active";
    return false;
  }
  largefile_backend_reset_save_job(backend);
  backend->save_job.snapshot_path = SDL_strdup(snapshot_path);
  backend->save_job.add_buffer_path = SDL_strdup(add_buffer_path);
  backend->save_job.source_path = SDL_strdup(source_path);
  backend->save_job.target_path = SDL_strdup(target_path);
  if (!backend->save_job.snapshot_path || !backend->save_job.add_buffer_path || !backend->save_job.source_path || !backend->save_job.target_path) {
    largefile_backend_reset_save_job(backend);
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
    if (error_out) *error_out = "out of memory creating save job";
    return false;
  }
  backend->save_job.active = true;
  backend->save_job.running = true;
  backend->save_job.complete = false;
  backend->save_job.failed = false;
  backend->save_job.cancel_requested = false;
  backend->save_job.written_bytes = 0;
  backend->save_job.total_bytes = 0;
  backend->save_job.error_message[0] = '\0';
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);

  backend->save_thread = SDL_CreateThread(largefile_backend_save_worker, "largefile-save", backend);
  if (!backend->save_thread) {
    SDL_LockMutex((SDL_Mutex *) backend->mutex);
    largefile_backend_reset_save_job(backend);
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
    if (error_out) *error_out = "failed to create save thread";
    return false;
  }
  return true;
}

bool largefile_backend_poll_save(LargeFileBackend *backend, lua_State *L) {
  bool active = false;
  bool running = false;
  bool complete = false;
  bool failed = false;
  uint64_t written_bytes = 0;
  uint64_t total_bytes = 0;
  char error[256] = {0};

  if (!backend || !backend->mutex) return false;

  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  active = backend->save_job.active;
  running = backend->save_job.running;
  complete = backend->save_job.complete;
  failed = backend->save_job.failed;
  written_bytes = backend->save_job.written_bytes;
  total_bytes = backend->save_job.total_bytes;
  if (backend->save_job.error_message[0] != '\0') {
    SDL_strlcpy(error, backend->save_job.error_message, sizeof(error));
  }
  if (active && !running && backend->save_thread) {
    SDL_Thread *thread = (SDL_Thread *) backend->save_thread;
    backend->save_thread = NULL;
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
    SDL_WaitThread(thread, NULL);
    SDL_LockMutex((SDL_Mutex *) backend->mutex);
  }
  if (!active) {
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
    return false;
  }

  lua_newtable(L);
  lua_pushboolean(L, running);
  lua_setfield(L, -2, "saving");
  lua_pushboolean(L, complete);
  lua_setfield(L, -2, "complete");
  lua_pushboolean(L, failed);
  lua_setfield(L, -2, "failed");
  lua_pushinteger(L, (lua_Integer) written_bytes);
  lua_setfield(L, -2, "progress_bytes");
  lua_pushinteger(L, (lua_Integer) total_bytes);
  lua_setfield(L, -2, "total_bytes");
  if (error[0] != '\0') {
    lua_pushstring(L, error);
    lua_setfield(L, -2, "error");
  }

  if (!running) {
    largefile_backend_reset_save_job(backend);
  }
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
  return true;
}

void largefile_backend_cancel_save(LargeFileBackend *backend) {
  if (!backend || !backend->mutex) return;
  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  backend->save_job.cancel_requested = true;
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
}

static bool largefile_backend_try_prepare_window(LargeFileBackend *backend) {
  if (!backend->request_dirty || backend->requested_start_line == 0) {
    return false;
  }

  size_t visible_count = largefile_index_visible_line_count(&backend->index);
  size_t request_start = backend->requested_start_line > backend->requested_margin
    ? backend->requested_start_line - backend->requested_margin
    : 1;
  size_t request_end = largefile_saturating_add_size(backend->requested_end_line, backend->requested_margin);
  size_t start_line = largefile_backend_align_chunk_start(backend, request_start);
  size_t end_line = largefile_backend_align_chunk_end(backend, request_end);
  if (backend->index.complete) {
    end_line = SDL_min(end_line, visible_count);
  } else {
    end_line = SDL_min(end_line, visible_count);
  }
  if (end_line < start_line) {
    end_line = start_line;
  }
  if (!largefile_index_has_line_end(&backend->index, end_line)) {
    return false;
  }

  if (!largefile_backend_load_window(
    backend,
    start_line,
    end_line,
    backend->requested_start_line,
    backend->requested_end_line,
    backend->requested_margin,
    backend->requested_epoch
  )) {
    largefile_jobs_fail(&backend->job, "window load failed");
    return false;
  }

  backend->request_dirty = false;
  backend->snapshot_ready = true;
  return true;
}

static bool largefile_backend_load_window(
  LargeFileBackend *backend,
  size_t start_line,
  size_t end_line,
  size_t requested_start_line,
  size_t requested_end_line,
  size_t margin,
  size_t epoch
) {
  FILE *fp = largefile_open_utf8(backend->path, "rb");
  if (!fp) {
    return false;
  }

  size_t line_count = end_line >= start_line ? (end_line - start_line + 1) : 0;
  if (!largefile_window_snapshot_reserve(&backend->snapshot, line_count)) {
    fclose(fp);
    return false;
  }

  backend->snapshot.start_line = start_line;
  backend->snapshot.end_line = end_line;
  backend->snapshot.requested_start_line = requested_start_line;
  backend->snapshot.requested_end_line = requested_end_line;
  backend->snapshot.margin = margin;
  backend->snapshot.epoch = epoch;

  for (size_t line = start_line; line <= end_line; line++) {
    uint64_t start = largefile_index_line_start(&backend->index, line);
    uint64_t end = largefile_index_line_end(&backend->index, line);
    uint64_t raw_len_u64 = end >= start ? (end - start) : 0;
    if (raw_len_u64 > (uint64_t) (SIZE_MAX - 2)) {
      fclose(fp);
      return false;
    }
    size_t raw_len = (size_t) raw_len_u64;
    char *buffer = SDL_malloc(raw_len + 2);
    if (!buffer) {
      fclose(fp);
      return false;
    }
    if (largefile_seek_u64(fp, start) != 0) {
      SDL_free(buffer);
      fclose(fp);
      return false;
    }
    if (raw_len > 0 && fread(buffer, 1, raw_len, fp) != raw_len) {
      SDL_free(buffer);
      fclose(fp);
      return false;
    }

    size_t text_len = raw_len;
    if (text_len > 0 && buffer[text_len - 1] == '\n') text_len--;
    if (text_len > 0 && buffer[text_len - 1] == '\r') text_len--;
    buffer[text_len++] = '\n';
    buffer[text_len] = '\0';

    backend->snapshot.lines[line - start_line].text = buffer;
    backend->snapshot.lines[line - start_line].len = text_len;
  }

  fclose(fp);
  return true;
}

static bool largefile_backend_read_normalized_line(FILE *fp, const LargeFileBackend *backend, size_t line, char **buffer, size_t *len) {
  if (!fp || !backend || !buffer || !len) return false;

  uint64_t start = largefile_index_line_start(&backend->index, line);
  uint64_t end = largefile_index_line_end(&backend->index, line);
  uint64_t raw_len_u64 = end >= start ? (end - start) : 0;
  if (raw_len_u64 > (uint64_t) (SIZE_MAX - 2)) {
    return false;
  }

  size_t raw_len = (size_t) raw_len_u64;
  char *line_buffer = SDL_malloc(raw_len + 2);
  if (!line_buffer) {
    return false;
  }

  if (largefile_seek_u64(fp, start) != 0) {
    SDL_free(line_buffer);
    return false;
  }
  if (raw_len > 0 && fread(line_buffer, 1, raw_len, fp) != raw_len) {
    SDL_free(line_buffer);
    return false;
  }

  size_t text_len = raw_len;
  if (text_len > 0 && line_buffer[text_len - 1] == '\n') text_len--;
  if (text_len > 0 && line_buffer[text_len - 1] == '\r') text_len--;
  line_buffer[text_len++] = '\n';
  line_buffer[text_len] = '\0';

  *buffer = line_buffer;
  *len = text_len;
  return true;
}

static int largefile_backend_worker(void *userdata) {
  LargeFileBackend *backend = userdata;
  FILE *fp = largefile_open_utf8(backend->path, "rb");
  if (!fp) {
    SDL_LockMutex((SDL_Mutex *) backend->mutex);
    largefile_jobs_fail(&backend->job, strerror(errno));
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
    return 0;
  }

  char *buffer = SDL_malloc(LARGEFILE_INDEX_CHUNK_SIZE);
  if (!buffer) {
    fclose(fp);
    SDL_LockMutex((SDL_Mutex *) backend->mutex);
    largefile_jobs_fail(&backend->job, "out of memory");
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
    return 0;
  }

  uint64_t offset = 0;
  bool last_was_cr = false;
  while (1) {
    SDL_LockMutex((SDL_Mutex *) backend->mutex);
    bool cancelled = backend->job.cancel_requested;
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
    if (cancelled) break;

    size_t read = fread(buffer, 1, LARGEFILE_INDEX_CHUNK_SIZE, fp);
    if (read == 0) {
      if (feof(fp)) break;
      SDL_LockMutex((SDL_Mutex *) backend->mutex);
      largefile_jobs_fail(&backend->job, strerror(errno));
      SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
      SDL_free(buffer);
      fclose(fp);
      return 0;
    }

    SDL_LockMutex((SDL_Mutex *) backend->mutex);
    backend->job.bytes_read += read;
    for (size_t i = 0; i < read; i++) {
      char ch = buffer[i];
      if (ch == '\n') {
        uint64_t next_line_offset = offset + i + 1;
        if (next_line_offset < backend->file_size && !largefile_index_append_line(&backend->index, next_line_offset)) {
          largefile_jobs_fail(&backend->job, "index append failed");
          SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
          SDL_free(buffer);
          fclose(fp);
          return 0;
        }
        backend->job.lines_indexed = largefile_index_visible_line_count(&backend->index);
      }
      if (last_was_cr && ch == '\n') {
        backend->index.crlf = true;
      }
      last_was_cr = (ch == '\r');
    }
    offset += read;
    largefile_backend_try_prepare_window(backend);
    SDL_UnlockMutex((SDL_Mutex *) backend->mutex);
  }

  SDL_LockMutex((SDL_Mutex *) backend->mutex);
  backend->index.complete = true;
  backend->job.running = false;
  backend->job.complete = true;
  backend->job.lines_indexed = largefile_index_visible_line_count(&backend->index);
  largefile_backend_try_prepare_window(backend);
  SDL_UnlockMutex((SDL_Mutex *) backend->mutex);

  SDL_free(buffer);
  fclose(fp);
  return 0;
}
