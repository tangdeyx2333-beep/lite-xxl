#include <SDL3/SDL.h>
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>
#include <ctype.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include "api.h"
#include "../rencache.h"
#include "../renwindow.h"
#include "arena_allocator.h"
#include "custom_events.h"
#ifdef _WIN32
  #include <direct.h>
  #include <windows.h>
  #include <fileapi.h>
  #include "../utfconv.h"
  #define fileno _fileno
  #define ftruncate _chsize
#else

#include <dirent.h>
#include <unistd.h>

#ifdef __linux__
  #include <sys/vfs.h>
#endif
#endif

#define dialogfinished_event_name "dialogfinished"
#define fileloadprogress_event_name "fileloadprogress"
#define fileloadcomplete_event_name "fileloadcomplete"
#define fileloaderror_event_name "fileloaderror"
#define fileindexprogress_event_name "fileindexprogress"
#define fileindexcomplete_event_name "fileindexcomplete"
#define fileindexerror_event_name "fileindexerror"
#define FILE_LOAD_CHUNK_SIZE (64 * 1024)
#define FILE_LOAD_PROGRESS_STEP (256 * 1024)
#define FILE_LOAD_QUEUE_CHUNK_LINES 24

#if defined(_MSC_VER)
  #define LITE_XL_NOINLINE __declspec(noinline)
#elif defined(__GNUC__) || defined(__clang__)
  #define LITE_XL_NOINLINE __attribute__((noinline))
#else
  #define LITE_XL_NOINLINE
#endif

#ifdef _WIN32
static char *win32_error(DWORD rc);
static void push_win32_error(lua_State *L, DWORD rc);
#endif

typedef enum {
  DIALOG_OK,
  DIALOG_CANCEL,
  DIALOG_ERROR,
} DialogState;

typedef struct {
  char *data;
  size_t len;
} FileLoadLine;

typedef struct FileLoadChunk {
  struct FileLoadChunk *next;
  FileLoadLine *lines;
  size_t line_count;
  size_t line_capacity;
} FileLoadChunk;

typedef enum {
  FILE_LOAD_RUNNING = 0,
  FILE_LOAD_COMPLETE,
  FILE_LOAD_ERROR,
} FileLoadState;

typedef struct FileLoadJob {
  struct FileLoadJob *next;
  uintptr_t id;
  char *path;
  SDL_Thread *thread;
  size_t file_size;
  size_t bytes_read;
  size_t lines_read;
  size_t delivered_lines;
  bool discard_requested;
  bool crlf;
  FileLoadState state;
  char *error_message;
  FileLoadChunk *queue_head;
  FileLoadChunk *queue_tail;
} FileLoadJob;

typedef struct {
  uintptr_t job_id;
  size_t bytes_read;
  size_t total_bytes;
  size_t lines_read;
} FileLoadProgressPayload;

static SDL_Mutex *file_load_jobs_mutex = NULL;
static FileLoadJob *file_load_jobs = NULL;
static uintptr_t next_file_load_job_id = 1;
static volatile size_t file_load_breakpoint_probe = 0;

typedef struct {
  Uint64 offset;
  Uint64 raw_len;
} FileIndexLine;

typedef struct FileIndex {
  struct FileIndex *next;
  uintptr_t id;
  char *path;
  size_t file_size;
  bool crlf;
  FileIndexLine *lines;
  size_t line_count;
  size_t line_capacity;
} FileIndex;

typedef struct FileIndexJob {
  struct FileIndexJob *next;
  uintptr_t id;
  char *path;
  SDL_Thread *thread;
  size_t file_size;
  size_t bytes_read;
  size_t lines_read;
  FileLoadState state;
  char *error_message;
  FileIndex *index;
} FileIndexJob;

typedef struct {
  uintptr_t job_id;
  size_t bytes_read;
  size_t total_bytes;
  size_t lines_read;
} FileIndexProgressPayload;

static SDL_Mutex *file_index_mutex = NULL;
static FileIndexJob *file_index_jobs = NULL;
static FileIndex *file_indexes = NULL;
static uintptr_t next_file_index_job_id = 1;
static uintptr_t next_file_index_id = 1;

static void free_file_load_chunk(FileLoadChunk *chunk) {
  if (chunk == NULL) return;
  for (size_t i = 0; i < chunk->line_count; i++) {
    SDL_free(chunk->lines[i].data);
  }
  SDL_free(chunk->lines);
  SDL_free(chunk);
}

static LITE_XL_NOINLINE void debug_bp_async_open_file_job_created(FileLoadJob *job) {
  file_load_breakpoint_probe ^= job ? (size_t) job->id : 0;
}

static LITE_XL_NOINLINE void debug_bp_async_chunk_enqueued(FileLoadJob *job, size_t chunk_lines, size_t total_lines) {
  file_load_breakpoint_probe ^= (job ? (size_t) job->id : 0) ^ chunk_lines ^ total_lines;
}

static LITE_XL_NOINLINE void debug_bp_async_chunk_dequeued(uintptr_t job_id, size_t chunk_lines, size_t delivered_lines, bool running, bool done) {
  file_load_breakpoint_probe ^= (size_t) job_id ^ chunk_lines ^ delivered_lines ^ (running ? 1u : 0u) ^ (done ? 2u : 0u);
}

static void free_file_load_queue(FileLoadJob *job) {
  FileLoadChunk *chunk = job->queue_head;
  while (chunk != NULL) {
    FileLoadChunk *next = chunk->next;
    free_file_load_chunk(chunk);
    chunk = next;
  }
  job->queue_head = NULL;
  job->queue_tail = NULL;
}

static void free_file_load_job(FileLoadJob *job) {
  if (job == NULL) return;
  if (job->thread) {
    SDL_WaitThread(job->thread, NULL);
  }
  SDL_free(job->path);
  SDL_free(job->error_message);
  free_file_load_queue(job);
  SDL_free(job);
}

static FileLoadJob *find_file_load_job_locked(uintptr_t job_id) {
  for (FileLoadJob *job = file_load_jobs; job != NULL; job = job->next) {
    if (job->id == job_id) return job;
  }
  return NULL;
}

static FileLoadJob *remove_file_load_job_locked(uintptr_t job_id) {
  FileLoadJob **link = &file_load_jobs;
  while (*link != NULL) {
    if ((*link)->id == job_id) {
      FileLoadJob *job = *link;
      *link = job->next;
      job->next = NULL;
      return job;
    }
    link = &(*link)->next;
  }
  return NULL;
}

static bool ensure_file_load_line_capacity(FileLoadChunk *chunk) {
  if (chunk->line_count < chunk->line_capacity) return true;
  size_t next_capacity = chunk->line_capacity == 0 ? FILE_LOAD_QUEUE_CHUNK_LINES : chunk->line_capacity * 2;
  FileLoadLine *next_lines = SDL_realloc(chunk->lines, next_capacity * sizeof(FileLoadLine));
  if (next_lines == NULL) return false;
  chunk->lines = next_lines;
  chunk->line_capacity = next_capacity;
  return true;
}

static bool append_pending_bytes(char **pending, size_t *pending_len, size_t *pending_cap, const char *data, size_t data_len) {
  if (data_len == 0) return true;
  if (*pending_len + data_len > *pending_cap) {
    size_t next_cap = *pending_cap == 0 ? 1024 : *pending_cap;
    while (*pending_len + data_len > next_cap) next_cap *= 2;
    char *next_pending = SDL_realloc(*pending, next_cap);
    if (next_pending == NULL) return false;
    *pending = next_pending;
    *pending_cap = next_cap;
  }
  SDL_memcpy(*pending + *pending_len, data, data_len);
  *pending_len += data_len;
  return true;
}

static bool append_loaded_line(FileLoadChunk *out, const char *pending, size_t pending_len, const char *chunk, size_t chunk_len, bool strip_cr) {
  if (!ensure_file_load_line_capacity(out)) return false;
  if (strip_cr) {
    if (chunk_len > 0) {
      chunk_len--;
    } else if (pending_len > 0) {
      pending_len--;
    }
  }

  size_t total_len = pending_len + chunk_len + 1;
  char *line = SDL_malloc(total_len);
  if (line == NULL) return false;

  size_t offset = 0;
  if (pending_len > 0) {
    SDL_memcpy(line + offset, pending, pending_len);
    offset += pending_len;
  }
  if (chunk_len > 0) {
    SDL_memcpy(line + offset, chunk, chunk_len);
    offset += chunk_len;
  }
  line[offset] = '\n';

  out->lines[out->line_count].data = line;
  out->lines[out->line_count].len = total_len;
  out->line_count++;
  return true;
}

static void queue_file_load_chunk_locked(FileLoadJob *job, FileLoadChunk *chunk, bool saw_crlf) {
  if (chunk == NULL || chunk->line_count == 0) return;
  size_t chunk_lines = chunk->line_count;
  chunk->next = NULL;
  if (job->queue_tail != NULL) {
    job->queue_tail->next = chunk;
  } else {
    job->queue_head = chunk;
  }
  job->queue_tail = chunk;
  job->lines_read += chunk->line_count;
  job->crlf = job->crlf || saw_crlf;
  debug_bp_async_chunk_enqueued(job, chunk_lines, job->lines_read);
}

static bool set_file_load_error(FileLoadJob *job, const char *message) {
  SDL_free(job->error_message);
  job->error_message = SDL_strdup(message ? message : "Unknown file load error");
  job->state = FILE_LOAD_ERROR;
  return job->error_message != NULL;
}

static bool get_utf8_file_size(const char *path, size_t *size_out, char **error_out) {
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) {
    if (error_out) *error_out = SDL_strdup(UTFCONV_ERROR_INVALID_CONVERSION);
    return false;
  }
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!GetFileAttributesExW(wpath, GetFileExInfoStandard, &data)) {
    if (error_out) {
      char *message = win32_error(GetLastError());
      *error_out = SDL_strdup(message ? message : "GetFileAttributesExW failed");
      if (message) LocalFree(message);
    }
    SDL_free(wpath);
    return false;
  }
  SDL_free(wpath);
  ULARGE_INTEGER large_int = {0};
  large_int.HighPart = data.nFileSizeHigh;
  large_int.LowPart = data.nFileSizeLow;
  *size_out = (size_t) large_int.QuadPart;
  return true;
#else
  struct stat s;
  if (stat(path, &s) < 0) {
    if (error_out) *error_out = SDL_strdup(strerror(errno));
    return false;
  }
  *size_out = (size_t) s.st_size;
  return true;
#endif
}

static FILE *open_utf8_file(const char *path, const char *mode, char **error_out) {
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  LPWSTR wmode = utfconv_utf8towc(mode);
  if (wpath == NULL || wmode == NULL) {
    if (error_out) *error_out = SDL_strdup(UTFCONV_ERROR_INVALID_CONVERSION);
    SDL_free(wpath);
    SDL_free(wmode);
    return NULL;
  }
  FILE *fp = _wfopen(wpath, wmode);
  if (fp == NULL && error_out) {
    *error_out = SDL_strdup(strerror(errno));
  }
  SDL_free(wpath);
  SDL_free(wmode);
  return fp;
#else
  FILE *fp = fopen(path, mode);
  if (fp == NULL && error_out) {
    *error_out = SDL_strdup(strerror(errno));
  }
  return fp;
#endif
}

static int f_set_file_readonly(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int readonly = lua_toboolean(L, 2);
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, UTFCONV_ERROR_INVALID_CONVERSION);
    return 2;
  }
  DWORD attrs = GetFileAttributesW(wpath);
  if (attrs == INVALID_FILE_ATTRIBUTES) {
    SDL_free(wpath);
    lua_pushboolean(L, 0);
    push_win32_error(L, GetLastError());
    return 2;
  }
  attrs = readonly ? (attrs | FILE_ATTRIBUTE_READONLY) : (attrs & ~FILE_ATTRIBUTE_READONLY);
  if (!SetFileAttributesW(wpath, attrs)) {
    SDL_free(wpath);
    lua_pushboolean(L, 0);
    push_win32_error(L, GetLastError());
    return 2;
  }
  SDL_free(wpath);
  lua_pushboolean(L, 1);
  return 1;
#else
  struct stat s;
  if (stat(path, &s) < 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  mode_t mode = s.st_mode;
  mode = readonly ? (mode & ~(S_IWUSR | S_IWGRP | S_IWOTH)) : (mode | S_IWUSR);
  if (chmod(path, mode) < 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
#endif
}

static void push_fileload_progress_event(FileLoadJob *job) {
  FileLoadProgressPayload *payload = SDL_malloc(sizeof(FileLoadProgressPayload));
  if (payload == NULL) return;
  SDL_LockMutex(file_load_jobs_mutex);
  payload->job_id = job->id;
  payload->bytes_read = job->bytes_read;
  payload->total_bytes = job->file_size;
  payload->lines_read = job->lines_read;
  SDL_UnlockMutex(file_load_jobs_mutex);
  CustomEvent event;
  SDL_zero(event);
  event.data1 = payload;
  if (!push_custom_event(fileloadprogress_event_name, &event)) {
    SDL_free(payload);
  }
}

static void push_fileload_complete_event(uintptr_t job_id) {
  CustomEvent event;
  SDL_zero(event);
  event.data1 = (void *) job_id;
  push_custom_event(fileloadcomplete_event_name, &event);
}

static void push_fileload_error_event(uintptr_t job_id, const char *message) {
  CustomEvent event;
  SDL_zero(event);
  event.data1 = (void *) job_id;
  event.data2 = SDL_strdup(message ? message : "Unknown file load error");
  if (!push_custom_event(fileloaderror_event_name, &event)) {
    SDL_free(event.data2);
  }
}

static int seek_u64(FILE *fp, Uint64 offset) {
#ifdef _WIN32
  return _fseeki64(fp, (__int64) offset, SEEK_SET);
#else
  return fseeko(fp, (off_t) offset, SEEK_SET);
#endif
}

static FileIndexJob *find_file_index_job_locked(uintptr_t job_id) {
  for (FileIndexJob *job = file_index_jobs; job != NULL; job = job->next) {
    if (job->id == job_id) return job;
  }
  return NULL;
}

static FileIndexJob *remove_file_index_job_locked(uintptr_t job_id) {
  FileIndexJob **link = &file_index_jobs;
  while (*link != NULL) {
    if ((*link)->id == job_id) {
      FileIndexJob *job = *link;
      *link = job->next;
      job->next = NULL;
      return job;
    }
    link = &(*link)->next;
  }
  return NULL;
}

static FileIndex *find_file_index_locked(uintptr_t index_id) {
  for (FileIndex *index = file_indexes; index != NULL; index = index->next) {
    if (index->id == index_id) return index;
  }
  return NULL;
}

static FileIndex *remove_file_index_locked(uintptr_t index_id) {
  FileIndex **link = &file_indexes;
  while (*link != NULL) {
    if ((*link)->id == index_id) {
      FileIndex *index = *link;
      *link = index->next;
      index->next = NULL;
      return index;
    }
    link = &(*link)->next;
  }
  return NULL;
}

static void free_file_index(FileIndex *index) {
  if (index == NULL) return;
  SDL_free(index->path);
  SDL_free(index->lines);
  SDL_free(index);
}

static void free_file_index_job(FileIndexJob *job) {
  if (job == NULL) return;
  if (job->thread) {
    SDL_WaitThread(job->thread, NULL);
  }
  SDL_free(job->path);
  SDL_free(job->error_message);
  free_file_index(job->index);
  SDL_free(job);
}

static bool ensure_file_index_line_capacity(FileIndex *index) {
  if (index->line_count < index->line_capacity) return true;
  size_t next_capacity = index->line_capacity == 0 ? 4096 : index->line_capacity * 2;
  FileIndexLine *next_lines = SDL_realloc(index->lines, next_capacity * sizeof(FileIndexLine));
  if (next_lines == NULL) return false;
  index->lines = next_lines;
  index->line_capacity = next_capacity;
  return true;
}

static bool append_file_index_line(FileIndexJob *job, Uint64 offset, Uint64 raw_len, bool crlf) {
  FileIndex *index = job->index;
  if (!ensure_file_index_line_capacity(index)) return false;
  index->lines[index->line_count].offset = offset;
  index->lines[index->line_count].raw_len = raw_len;
  index->line_count++;
  index->crlf = index->crlf || crlf;
  job->lines_read = index->line_count;
  return true;
}

static bool set_file_index_error(FileIndexJob *job, const char *message) {
  SDL_free(job->error_message);
  job->error_message = SDL_strdup(message ? message : "Unknown file index error");
  job->state = FILE_LOAD_ERROR;
  return job->error_message != NULL;
}

static void push_fileindex_progress_event(FileIndexJob *job) {
  FileIndexProgressPayload *payload = SDL_malloc(sizeof(FileIndexProgressPayload));
  if (payload == NULL) return;
  payload->job_id = job->id;
  payload->bytes_read = job->bytes_read;
  payload->total_bytes = job->file_size;
  payload->lines_read = job->lines_read;
  CustomEvent event;
  SDL_zero(event);
  event.data1 = payload;
  if (!push_custom_event(fileindexprogress_event_name, &event)) {
    SDL_free(payload);
  }
}

static void push_fileindex_complete_event(uintptr_t job_id) {
  CustomEvent event;
  SDL_zero(event);
  event.data1 = (void *) job_id;
  push_custom_event(fileindexcomplete_event_name, &event);
}

static void push_fileindex_error_event(uintptr_t job_id, const char *message) {
  CustomEvent event;
  SDL_zero(event);
  event.data1 = (void *) job_id;
  event.data2 = SDL_strdup(message ? message : "Unknown file index error");
  if (!push_custom_event(fileindexerror_event_name, &event)) {
    SDL_free(event.data2);
  }
}

static int file_index_thread(void *userdata) {
  FileIndexJob *job = userdata;
  char *error_message = NULL;
  FILE *fp = open_utf8_file(job->path, "rb", &error_message);
  if (fp == NULL) {
    SDL_LockMutex(file_index_mutex);
    set_file_index_error(job, error_message ? error_message : "Unable to open file");
    SDL_UnlockMutex(file_index_mutex);
    push_fileindex_error_event(job->id, error_message ? error_message : job->error_message);
    SDL_free(error_message);
    return 0;
  }

  char chunk[FILE_LOAD_CHUNK_SIZE];
  Uint64 absolute_offset = 0;
  Uint64 line_offset = 0;
  size_t emitted_bytes = 0;
  unsigned char previous_byte = 0;
  bool have_previous = false;

  while (true) {
    size_t read_len = fread(chunk, 1, sizeof(chunk), fp);
    if (read_len == 0) {
      if (ferror(fp)) {
        SDL_LockMutex(file_index_mutex);
        set_file_index_error(job, strerror(errno));
        SDL_UnlockMutex(file_index_mutex);
        push_fileindex_error_event(job->id, job->error_message);
      }
      break;
    }

    for (size_t i = 0; i < read_len; i++) {
      unsigned char ch = (unsigned char) chunk[i];
      if (ch == '\n') {
        Uint64 nl_offset = absolute_offset + i;
        bool crlf = have_previous && previous_byte == '\r';
        if (!append_file_index_line(job, line_offset, nl_offset - line_offset + 1, crlf)) {
          SDL_LockMutex(file_index_mutex);
          set_file_index_error(job, "Out of memory while indexing file");
          SDL_UnlockMutex(file_index_mutex);
          push_fileindex_error_event(job->id, job->error_message);
          break;
        }
        line_offset = nl_offset + 1;
      }
      previous_byte = ch;
      have_previous = true;
    }

    SDL_LockMutex(file_index_mutex);
    job->bytes_read += read_len;
    SDL_UnlockMutex(file_index_mutex);
    emitted_bytes += read_len;
    absolute_offset += read_len;

    if (job->state == FILE_LOAD_ERROR) {
      break;
    }

    if (emitted_bytes >= FILE_LOAD_PROGRESS_STEP) {
      push_fileindex_progress_event(job);
      emitted_bytes = 0;
    }
  }

  fclose(fp);

  if (job->state != FILE_LOAD_ERROR) {
    if (line_offset < absolute_offset || job->index->line_count == 0) {
      if (!append_file_index_line(job, line_offset, absolute_offset - line_offset, false)) {
        SDL_LockMutex(file_index_mutex);
        set_file_index_error(job, "Out of memory while finalizing file index");
        SDL_UnlockMutex(file_index_mutex);
        push_fileindex_error_event(job->id, job->error_message);
      }
    }
  }

  if (job->state != FILE_LOAD_ERROR) {
    SDL_LockMutex(file_index_mutex);
    job->state = FILE_LOAD_COMPLETE;
    SDL_UnlockMutex(file_index_mutex);
    push_fileindex_complete_event(job->id);
  }

  return 0;
}

static int file_load_thread(void *userdata) {
  FileLoadJob *job = userdata;
  char *error_message = NULL;
  FILE *fp = open_utf8_file(job->path, "rb", &error_message);
  if (fp == NULL) {
    SDL_LockMutex(file_load_jobs_mutex);
    set_file_load_error(job, error_message ? error_message : "Unable to open file");
    SDL_UnlockMutex(file_load_jobs_mutex);
    push_fileload_error_event(job->id, error_message ? error_message : job->error_message);
    SDL_free(error_message);
    return 0;
  }

  char chunk[FILE_LOAD_CHUNK_SIZE];
  char *pending = NULL;
  size_t pending_len = 0;
  size_t pending_cap = 0;
  size_t emitted_bytes = 0;
  FileLoadChunk *queued_chunk = SDL_calloc(1, sizeof(FileLoadChunk));
  bool queued_chunk_has_crlf = false;

  if (queued_chunk == NULL) {
    fclose(fp);
    SDL_LockMutex(file_load_jobs_mutex);
    set_file_load_error(job, "Out of memory while allocating async file queue");
    SDL_UnlockMutex(file_load_jobs_mutex);
    push_fileload_error_event(job->id, job->error_message);
    SDL_free(error_message);
    return 0;
  }

  while (true) {
    size_t read_len = fread(chunk, 1, sizeof(chunk), fp);
    if (read_len == 0) {
      if (ferror(fp)) {
        SDL_LockMutex(file_load_jobs_mutex);
        set_file_load_error(job, strerror(errno));
        SDL_UnlockMutex(file_load_jobs_mutex);
        push_fileload_error_event(job->id, job->error_message);
      }
      break;
    }

    SDL_LockMutex(file_load_jobs_mutex);
    job->bytes_read += read_len;
    bool discard_requested = job->discard_requested;
    SDL_UnlockMutex(file_load_jobs_mutex);
    emitted_bytes += read_len;
    if (discard_requested) {
      break;
    }

    size_t start = 0;
    while (start < read_len) {
      char *nl = (char *) memchr(chunk + start, '\n', read_len - start);
      if (nl == NULL) {
        if (!append_pending_bytes(&pending, &pending_len, &pending_cap, chunk + start, read_len - start)) {
          SDL_LockMutex(file_load_jobs_mutex);
          set_file_load_error(job, "Out of memory while buffering file");
          SDL_UnlockMutex(file_load_jobs_mutex);
          push_fileload_error_event(job->id, job->error_message);
          read_len = 0;
          break;
        }
        break;
      }

      size_t segment_len = (size_t) (nl - (chunk + start));
      bool strip_cr = (segment_len > 0 && chunk[start + segment_len - 1] == '\r')
        || (segment_len == 0 && pending_len > 0 && pending[pending_len - 1] == '\r');
      bool append_ok = append_loaded_line(queued_chunk, pending, pending_len, chunk + start, segment_len, strip_cr);
      if (!append_ok) {
        SDL_LockMutex(file_load_jobs_mutex);
        set_file_load_error(job, "Out of memory while storing file lines");
        SDL_UnlockMutex(file_load_jobs_mutex);
        push_fileload_error_event(job->id, job->error_message);
        read_len = 0;
        break;
      }
      queued_chunk_has_crlf = queued_chunk_has_crlf || strip_cr;
      pending_len = 0;
      start = (size_t) ((nl - chunk) + 1);

      if (queued_chunk->line_count >= FILE_LOAD_QUEUE_CHUNK_LINES) {
        SDL_LockMutex(file_load_jobs_mutex);
        queue_file_load_chunk_locked(job, queued_chunk, queued_chunk_has_crlf);
        SDL_UnlockMutex(file_load_jobs_mutex);
        queued_chunk = SDL_calloc(1, sizeof(FileLoadChunk));
        queued_chunk_has_crlf = false;
        if (queued_chunk == NULL) {
          SDL_LockMutex(file_load_jobs_mutex);
          set_file_load_error(job, "Out of memory while rotating async file queue");
          SDL_UnlockMutex(file_load_jobs_mutex);
          push_fileload_error_event(job->id, job->error_message);
          read_len = 0;
          break;
        }
      }
    }

    SDL_LockMutex(file_load_jobs_mutex);
    bool load_failed = job->state == FILE_LOAD_ERROR;
    discard_requested = job->discard_requested;
    SDL_UnlockMutex(file_load_jobs_mutex);
    if (load_failed || discard_requested) {
      break;
    }

    if (emitted_bytes >= FILE_LOAD_PROGRESS_STEP) {
      push_fileload_progress_event(job);
      emitted_bytes = 0;
    }
  }

  if (job->state != FILE_LOAD_ERROR) {
    if (pending_len > 0) {
      bool strip_cr = pending[pending_len - 1] == '\r';
      bool append_ok = append_loaded_line(queued_chunk, pending, pending_len, NULL, 0, strip_cr);
      if (!append_ok) {
        SDL_LockMutex(file_load_jobs_mutex);
        set_file_load_error(job, "Out of memory while finalizing file");
        SDL_UnlockMutex(file_load_jobs_mutex);
        push_fileload_error_event(job->id, job->error_message);
      } else {
        queued_chunk_has_crlf = queued_chunk_has_crlf || strip_cr;
      }
    } else if (queued_chunk->line_count == 0 && job->lines_read == 0) {
      bool append_ok = append_loaded_line(queued_chunk, NULL, 0, NULL, 0, false);
      if (!append_ok) {
        SDL_LockMutex(file_load_jobs_mutex);
        set_file_load_error(job, "Out of memory while creating empty document");
        SDL_UnlockMutex(file_load_jobs_mutex);
        push_fileload_error_event(job->id, job->error_message);
      }
    }
  }

  fclose(fp);
  SDL_free(pending);

  SDL_LockMutex(file_load_jobs_mutex);
  bool discard_requested = job->discard_requested;
  bool load_failed = job->state == FILE_LOAD_ERROR;
  SDL_UnlockMutex(file_load_jobs_mutex);

  if (!load_failed) {
    bool queued_chunk_emitted = !discard_requested && queued_chunk != NULL && queued_chunk->line_count > 0;
    SDL_LockMutex(file_load_jobs_mutex);
    if (!discard_requested) {
      queue_file_load_chunk_locked(job, queued_chunk, queued_chunk_has_crlf);
    }
    job->state = FILE_LOAD_COMPLETE;
    SDL_UnlockMutex(file_load_jobs_mutex);
    push_fileload_complete_event(job->id);
    if (queued_chunk_emitted) {
      queued_chunk = NULL;
    }
  }

  free_file_load_chunk(queued_chunk);

  return 0;
}

static const char* button_name(int button) {
  switch (button) {
    case SDL_BUTTON_LEFT   : return "left";
    case SDL_BUTTON_MIDDLE : return "middle";
    case SDL_BUTTON_RIGHT  : return "right";
    case SDL_BUTTON_X1     : return "x";
    case SDL_BUTTON_X2     : return "y";
    default : return "?";
  }
}


static void str_tolower(char *p) {
  while (*p) {
    *p = tolower(*p);
    p++;
  }
}

struct HitTestInfo {
  int title_height;
  int controls_width;
  int resize_border;
};
typedef struct HitTestInfo HitTestInfo;

static HitTestInfo window_hit_info[1] = {{0, 0, 0}};

#define RESIZE_FROM_TOP 0
#define RESIZE_FROM_RIGHT 0

static SDL_HitTestResult SDLCALL hit_test(SDL_Window *window, const SDL_Point *pt, void *data) {
  const HitTestInfo *hit_info = (HitTestInfo *) data;
  const int resize_border = hit_info->resize_border;
  const int controls_width = hit_info->controls_width;
  int w, h;

  SDL_GetWindowSize(window, &w, &h);

  if (pt->y < hit_info->title_height &&
    #if RESIZE_FROM_TOP
    pt->y > hit_info->resize_border &&
    #endif
    pt->x > resize_border && pt->x < w - controls_width) {
    return SDL_HITTEST_DRAGGABLE;
  }

  #define REPORT_RESIZE_HIT(name) { \
    return SDL_HITTEST_RESIZE_##name; \
  }

  if (pt->x < resize_border && pt->y < resize_border) {
    REPORT_RESIZE_HIT(TOPLEFT);
  #if RESIZE_FROM_TOP
  } else if (pt->x > resize_border && pt->x < w - controls_width && pt->y < resize_border) {
    REPORT_RESIZE_HIT(TOP);
  #endif
  } else if (pt->x > w - resize_border && pt->y < resize_border) {
    REPORT_RESIZE_HIT(TOPRIGHT);
  #if RESIZE_FROM_RIGHT
  } else if (pt->x > w - resize_border && pt->y > resize_border && pt->y < h - resize_border) {
    REPORT_RESIZE_HIT(RIGHT);
  #endif
  } else if (pt->x > w - resize_border && pt->y > h - resize_border) {
    REPORT_RESIZE_HIT(BOTTOMRIGHT);
  } else if (pt->x < w - resize_border && pt->x > resize_border && pt->y > h - resize_border) {
    REPORT_RESIZE_HIT(BOTTOM);
  } else if (pt->x < resize_border && pt->y > h - resize_border) {
    REPORT_RESIZE_HIT(BOTTOMLEFT);
  } else if (pt->x < resize_border && pt->y < h - resize_border && pt->y > resize_border) {
    REPORT_RESIZE_HIT(LEFT);
  }

  return SDL_HITTEST_NORMAL;
}

static const char *numpad[] = { "end", "down", "pagedown", "left", "", "right", "home", "up", "pageup", "ins", "delete" };

static const char *get_key_name(const SDL_Event *e, char *buf) {
  SDL_Scancode scancode = e->key.scancode;
  /* Is the scancode from the keypad and the number-lock off?
  ** We assume that SDL_SCANCODE_KP_1 up to SDL_SCANCODE_KP_9 and SDL_SCANCODE_KP_0
  ** and SDL_SCANCODE_KP_PERIOD are declared in SDL2 in that order. */
  if (scancode >= SDL_SCANCODE_KP_1 && scancode <= SDL_SCANCODE_KP_1 + 10 &&
    !(e->key.mod & SDL_KMOD_NUM)) {
    return numpad[scancode - SDL_SCANCODE_KP_1];
  } else {
    /* We need to correctly handle non-standard layouts such as dvorak.
       Therefore, if a Latin letter(code<128) is pressed in the current layout,
       then we transmit it as it is. But we also need to support shortcuts in
       other languages, so for non-Latin characters(code>128) we pass the
       scancode based name that matches the letter in the QWERTY layout.

       In SDL, the codes of all special buttons such as control, shift, arrows
       and others, are masked with SDLK_SCANCODE_MASK, which moves them outside
       the unicode range (>0x10FFFF). Users can remap these buttons, so we need
       to return the correct name, not scancode based. */
    if ((e->key.key < 128) || (e->key.key & SDLK_SCANCODE_MASK))
      strcpy(buf, SDL_GetKeyName(e->key.key));
    else
      strcpy(buf, SDL_GetScancodeName(scancode));
    str_tolower(buf);
    return buf;
  }
}

#ifdef _WIN32
static char *win32_error(DWORD rc) {
  LPSTR message;
  FormatMessage(
    FORMAT_MESSAGE_ALLOCATE_BUFFER |
    FORMAT_MESSAGE_FROM_SYSTEM |
    FORMAT_MESSAGE_IGNORE_INSERTS,
    NULL,
    rc,
    MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
    (LPTSTR) &message,
    0,
    NULL
  );

  return message;
}

static void push_win32_error(lua_State *L, DWORD rc) {
  LPSTR message = win32_error(rc);
  lua_pushstring(L, message);
  LocalFree(message);
}
#endif

static int f_poll_event(lua_State *L) {
  char buf[16];
  float mx, my;
  int w, h;
  SDL_Event e;
  SDL_Event event_plus;

top:
  if ( !SDL_PollEvent(&e) ) {
    return 0;
  }

  switch (e.type) {
    case SDL_EVENT_QUIT:
      lua_pushstring(L, "quit");
      return 1;

    case SDL_EVENT_WINDOW_RESIZED:
      {
        RenWindow* window_renderer = ren_find_window_from_id(e.window.windowID);
        ren_resize_window(window_renderer);
        lua_pushstring(L, "resized");
        /* The size below will be in points. */
        lua_pushinteger(L, e.window.data1);
        lua_pushinteger(L, e.window.data2);
        return 3;
      }

    case SDL_EVENT_WINDOW_EXPOSED:
      rencache_invalidate();
      lua_pushstring(L, "exposed");
      return 1;

    case SDL_EVENT_WINDOW_MINIMIZED:
      lua_pushstring(L, "minimized");
      return 1;

    case SDL_EVENT_WINDOW_MAXIMIZED:
      lua_pushstring(L, "maximized");
      return 1;

    case SDL_EVENT_WINDOW_RESTORED:
      lua_pushstring(L, "restored");
      return 1;

    case SDL_EVENT_WINDOW_MOUSE_LEAVE:
      lua_pushstring(L, "mouseleft");
      return 1;

    case SDL_EVENT_WINDOW_FOCUS_LOST:
      lua_pushstring(L, "focuslost");
      return 1;

    case SDL_EVENT_WINDOW_FOCUS_GAINED:
      /* on some systems, when alt-tabbing to the window SDL will queue up
      ** several KEYDOWN events for the `tab` key; we flush all keydown
      ** events on focus so these are discarded */
      SDL_FlushEvent(SDL_EVENT_KEY_DOWN);
      goto top;


    case SDL_EVENT_DROP_FILE:
      {
        RenWindow* window_renderer = ren_find_window_from_id(e.drop.windowID);
        SDL_GetMouseState(&mx, &my);
        lua_pushstring(L, "filedropped");
        lua_pushstring(L, e.drop.data);
        // a DND into dock event fired before a window is created
        lua_pushinteger(L, mx * (window_renderer ? window_renderer->scale_x : 0));
        lua_pushinteger(L, my * (window_renderer ? window_renderer->scale_y : 0));
        return 4;
      }

    case SDL_EVENT_KEY_DOWN:
#ifdef __APPLE__
      /* on macos 11.2.3 with sdl 2.0.14 the keyup handler for cmd+w below
      ** was not enough. Maybe the quit event started to be triggered from the
      ** keydown handler? In any case, flushing the quit event here too helped. */
      if ((e.key.key == SDLK_W) && (e.key.mod & SDL_KMOD_GUI)) {
        SDL_FlushEvent(SDL_EVENT_QUIT);
      }
#endif
      lua_pushstring(L, "keypressed");
      lua_pushstring(L, get_key_name(&e, buf));
      return 2;

    case SDL_EVENT_KEY_UP:
#ifdef __APPLE__
      /* on macos command+w will close the current window
      ** we want to flush this event and let the keymapper
      ** handle this key combination.
      ** Thanks to mathewmariani, taken from his lite-macos github repository. */
      if ((e.key.key == SDLK_W) && (e.key.mod & SDL_KMOD_GUI)) {
        SDL_FlushEvent(SDL_EVENT_QUIT);
      }
#endif
      lua_pushstring(L, "keyreleased");
      lua_pushstring(L, get_key_name(&e, buf));
      return 2;

    case SDL_EVENT_TEXT_INPUT:
      SDL_Log("SDL_EVENT_TEXT_INPUT: text=%s", e.text.text);
      lua_pushstring(L, "textinput");
      lua_pushstring(L, e.text.text);
      return 2;

    case SDL_EVENT_TEXT_EDITING:
      SDL_Log("SDL_EVENT_TEXT_EDITING: text=%s start=%d length=%d", e.edit.text, e.edit.start, e.edit.length);
      lua_pushstring(L, "textediting");
      lua_pushstring(L, e.edit.text);
      lua_pushinteger(L, e.edit.start);
      lua_pushinteger(L, e.edit.length);
      return 4;

    case SDL_EVENT_MOUSE_BUTTON_DOWN:
      {
        if (e.button.button == 1) { SDL_CaptureMouse(1); }
        RenWindow* window_renderer = ren_find_window_from_id(e.button.windowID);
        lua_pushstring(L, "mousepressed");
        lua_pushstring(L, button_name(e.button.button));
        lua_pushinteger(L, e.button.x * window_renderer->scale_x);
        lua_pushinteger(L, e.button.y * window_renderer->scale_y);
        lua_pushinteger(L, e.button.clicks);
        return 5;
      }

    case SDL_EVENT_MOUSE_BUTTON_UP:
      {
        if (e.button.button == 1) { SDL_CaptureMouse(0); }
        RenWindow* window_renderer = ren_find_window_from_id(e.button.windowID);
        lua_pushstring(L, "mousereleased");
        lua_pushstring(L, button_name(e.button.button));
        lua_pushinteger(L, e.button.x * window_renderer->scale_x);
        lua_pushinteger(L, e.button.y * window_renderer->scale_y);
        return 4;
      }

    case SDL_EVENT_MOUSE_MOTION:
      {
        SDL_PumpEvents();
        while (SDL_PeepEvents(&event_plus, 1, SDL_GETEVENT, SDL_EVENT_MOUSE_MOTION, SDL_EVENT_MOUSE_MOTION) > 0) {
          e.motion.x = event_plus.motion.x;
          e.motion.y = event_plus.motion.y;
          e.motion.xrel += event_plus.motion.xrel;
          e.motion.yrel += event_plus.motion.yrel;
        }
        RenWindow* window_renderer = ren_find_window_from_id(e.motion.windowID);
        lua_pushstring(L, "mousemoved");
        lua_pushinteger(L, e.motion.x * window_renderer->scale_x);
        lua_pushinteger(L, e.motion.y * window_renderer->scale_y);
        lua_pushinteger(L, e.motion.xrel * window_renderer->scale_x);
        lua_pushinteger(L, e.motion.yrel * window_renderer->scale_y);
        return 5;
      }

    case SDL_EVENT_MOUSE_WHEEL:
      lua_pushstring(L, "mousewheel");
      lua_pushnumber(L, e.wheel.y);
      // Use -x to keep consistency with vertical scrolling values (e.g. shift+scroll)
      lua_pushnumber(L, -e.wheel.x);
      return 3;

    case SDL_EVENT_FINGER_DOWN:
      {
        RenWindow* window_renderer = ren_find_window_from_id(e.tfinger.windowID);
        SDL_GetWindowSize(window_renderer->window, &w, &h);

        lua_pushstring(L, "touchpressed");
        lua_pushinteger(L, (lua_Integer)(e.tfinger.x * w));
        lua_pushinteger(L, (lua_Integer)(e.tfinger.y * h));
        lua_pushinteger(L, e.tfinger.fingerID);
        return 4;
      }

    case SDL_EVENT_FINGER_UP:
      {
        RenWindow* window_renderer = ren_find_window_from_id(e.tfinger.windowID);
        SDL_GetWindowSize(window_renderer->window, &w, &h);

        lua_pushstring(L, "touchreleased");
        lua_pushinteger(L, (lua_Integer)(e.tfinger.x * w));
        lua_pushinteger(L, (lua_Integer)(e.tfinger.y * h));
        lua_pushinteger(L, e.tfinger.fingerID);
        return 4;
      }

    case SDL_EVENT_FINGER_MOTION:
      {
        SDL_PumpEvents();
        while (SDL_PeepEvents(&event_plus, 1, SDL_GETEVENT, SDL_EVENT_FINGER_MOTION, SDL_EVENT_FINGER_MOTION) > 0) {
          e.tfinger.x = event_plus.tfinger.x;
          e.tfinger.y = event_plus.tfinger.y;
          e.tfinger.dx += event_plus.tfinger.dx;
          e.tfinger.dy += event_plus.tfinger.dy;
        }
        RenWindow* window_renderer = ren_find_window_from_id(e.tfinger.windowID);
        SDL_GetWindowSize(window_renderer->window, &w, &h);

        lua_pushstring(L, "touchmoved");
        lua_pushinteger(L, (lua_Integer)(e.tfinger.x * w));
        lua_pushinteger(L, (lua_Integer)(e.tfinger.y * h));
        lua_pushinteger(L, (lua_Integer)(e.tfinger.dx * w));
        lua_pushinteger(L, (lua_Integer)(e.tfinger.dy * h));
        lua_pushinteger(L, e.tfinger.fingerID);
        return 6;
      }

    case SDL_EVENT_WILL_ENTER_FOREGROUND:
    case SDL_EVENT_DID_ENTER_FOREGROUND:
      {
        #ifdef LITE_USE_SDL_RENDERER
          rencache_invalidate();
        #else
          RenWindow** window_list;
          size_t window_count = ren_get_window_list(&window_list);
          while (window_count) {
            SDL_UpdateWindowSurface(window_list[--window_count]->window);
          }
        #endif
        lua_pushstring(L, e.type == SDL_EVENT_WILL_ENTER_FOREGROUND ? "enteringforeground" : "enteredforeground");
        return 1;
      }

    case SDL_EVENT_WILL_ENTER_BACKGROUND:
      lua_pushstring(L, "enteringbackground");
      return 1;

    case SDL_EVENT_DID_ENTER_BACKGROUND:
      lua_pushstring(L, "enteredbackground");
      return 1;

    case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
      {
        RenWindow* window_renderer = ren_find_window_from_id(e.window.windowID);
        ren_resize_window(window_renderer);
      }

    default:
      // Custom event types are higher than SDL_EVENT_USER
      if (e.type >= SDL_EVENT_USER) {
        CustomEventCallback cec = get_custom_event_callback_by_type(e.type);
        if (cec != NULL) {
          int result = cec(L, &e);
          // If the callback didn't return anything, skip to the next event
          if (result != 0) {
            return result;
          }
        }
      }
      goto top;
  }

  return 0;
}


static int f_wait_event(lua_State *L) {
  int nargs = lua_gettop(L);
  if (nargs >= 1) {
    double n = luaL_checknumber(L, 1);
    if (n < 0) n = 0;
    lua_pushboolean(L, SDL_WaitEventTimeout(NULL, n * 1000));
  } else {
    lua_pushboolean(L, SDL_WaitEvent(NULL));
  }
  return 1;
}


static SDL_Cursor* cursor_cache[SDL_SYSTEM_CURSOR_POINTER + 1];

static const char *cursor_opts[] = {
  "arrow",
  "ibeam",
  "sizeh",
  "sizev",
  "hand",
  NULL
};

static const int cursor_enums[] = {
  SDL_SYSTEM_CURSOR_DEFAULT,
  SDL_SYSTEM_CURSOR_TEXT,
  SDL_SYSTEM_CURSOR_EW_RESIZE,
  SDL_SYSTEM_CURSOR_NS_RESIZE,
  SDL_SYSTEM_CURSOR_POINTER
};

static int f_set_cursor(lua_State *L) {
  int opt = luaL_checkoption(L, 1, "arrow", cursor_opts);
  int n = cursor_enums[opt];
  SDL_Cursor *cursor = cursor_cache[n];
  if (!cursor) {
    cursor = SDL_CreateSystemCursor(n);
    cursor_cache[n] = cursor;
  }
  SDL_SetCursor(cursor);
  return 0;
}


static int f_set_window_title(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  const char *title = luaL_checkstring(L, 2);
  SDL_SetWindowTitle(window_renderer->window, title);
  return 0;
}


static const char *window_opts[] = { "normal", "minimized", "maximized", "fullscreen", 0 };
enum { WIN_NORMAL, WIN_MINIMIZED, WIN_MAXIMIZED, WIN_FULLSCREEN };

static int f_set_window_mode(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  int n = luaL_checkoption(L, 2, "normal", window_opts);
  SDL_SetWindowFullscreen(window_renderer->window, n == WIN_FULLSCREEN);
  if (n == WIN_NORMAL) { SDL_RestoreWindow(window_renderer->window); }
  if (n == WIN_MAXIMIZED) { SDL_MaximizeWindow(window_renderer->window); }
  if (n == WIN_MINIMIZED) { SDL_MinimizeWindow(window_renderer->window); }
  return 0;
}


static int f_set_window_bordered(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**) luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  SDL_SetWindowBordered(window_renderer->window, lua_toboolean(L, 2));
  return 0;
}


static int f_set_window_hit_test(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**) luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  if (lua_gettop(L) == 1) {
    SDL_SetWindowHitTest(window_renderer->window, NULL, NULL);
    return 0;
  }
  window_hit_info->title_height = luaL_checknumber(L, 2);
  window_hit_info->controls_width = luaL_checknumber(L, 3);
  window_hit_info->resize_border = luaL_checknumber(L, 4);
  SDL_SetWindowHitTest(window_renderer->window, &hit_test, window_hit_info);
  return 0;
}


static int f_get_window_size(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  int x, y, w, h;
  SDL_GetWindowSize(window_renderer->window, &w, &h);
  SDL_GetWindowPosition(window_renderer->window, &x, &y);
  lua_pushinteger(L, w);
  lua_pushinteger(L, h);
  lua_pushinteger(L, x);
  lua_pushinteger(L, y);
  return 4;
}

static int f_get_display_bounds(lua_State *L) {
  int count = 0;
  SDL_DisplayID *displays = SDL_GetDisplays(&count);
  lua_createtable(L, count, 0);
  if (displays == NULL || count <= 0) {
    return 1;
  }
  for (int i = 0; i < count; i++) {
    SDL_Rect rect;
    if (!SDL_GetDisplayUsableBounds(displays[i], &rect)) {
      continue;
    }
    lua_createtable(L, 0, 5);
    lua_pushinteger(L, rect.x);
    lua_setfield(L, -2, "x");
    lua_pushinteger(L, rect.y);
    lua_setfield(L, -2, "y");
    lua_pushinteger(L, rect.w);
    lua_setfield(L, -2, "w");
    lua_pushinteger(L, rect.h);
    lua_setfield(L, -2, "h");
    lua_pushinteger(L, (lua_Integer) displays[i]);
    lua_setfield(L, -2, "id");
    lua_rawseti(L, -2, i + 1);
  }
  SDL_free(displays);
  return 1;
}


static int f_set_window_size(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  double w = luaL_checknumber(L, 2);
  double h = luaL_checknumber(L, 3);
  double x = luaL_checknumber(L, 4);
  double y = luaL_checknumber(L, 5);
  SDL_SetWindowSize(window_renderer->window, w, h);
  SDL_SetWindowPosition(window_renderer->window, x, y);
  ren_resize_window(window_renderer);
  return 0;
}


static int f_window_has_focus(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  unsigned flags = SDL_GetWindowFlags(window_renderer->window);
  lua_pushboolean(L, flags & SDL_WINDOW_INPUT_FOCUS);
  return 1;
}


static int f_get_window_mode(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  unsigned flags = SDL_GetWindowFlags(window_renderer->window);
  if (flags & SDL_WINDOW_FULLSCREEN) {
    lua_pushstring(L, "fullscreen");
  } else if (flags & SDL_WINDOW_MINIMIZED) {
    lua_pushstring(L, "minimized");
  } else if (flags & SDL_WINDOW_MAXIMIZED) {
    lua_pushstring(L, "maximized");
  } else {
    lua_pushstring(L, "normal");
  }
  return 1;
}

static int f_set_text_input_rect(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  SDL_Rect rect;
  rect.x = luaL_checknumber(L, 2);
  rect.y = luaL_checknumber(L, 3);
  rect.w = luaL_checknumber(L, 4);
  rect.h = luaL_checknumber(L, 5);
  SDL_SetTextInputArea(window_renderer->window, &rect, 0);
  return 0;
}

static int f_clear_ime(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  SDL_ClearComposition(window_renderer->window);
  return 0;
}


static int f_raise_window(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  SDL_RaiseWindow(window_renderer->window);
  return 0;
}


static int f_show_fatal_error(lua_State *L) {
  const char *title = luaL_checkstring(L, 1);
  const char *msg = luaL_checkstring(L, 2);

#ifdef _WIN32
  MessageBox(0, msg, title, MB_OK | MB_ICONERROR);
#else
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, title, msg, NULL);
#endif
  return 0;
}


// removes an empty directory
static int f_rmdir(lua_State *L) {
  lua_pushboolean(L, SDL_RemovePath(luaL_checkstring(L, 1)));
  if (!lua_toboolean(L, -1)) {
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  return 1;
}


static int f_chdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) { return luaL_error(L, UTFCONV_ERROR_INVALID_CONVERSION ); }
  int err = _wchdir(wpath);
  SDL_free(wpath);
#else
  int err = chdir(path);
#endif
  if (err) { luaL_error(L, "chdir() failed: %s", strerror(errno)); }
  return 0;
}

static SDL_EnumerationResult list_dir_enumeration_callback(void *userdata, const char *dirname, const char *fname) {
  (void) dirname;
  lua_State *L = userdata;
  int len = lua_rawlen(L, -1);
  lua_pushstring(L, fname);
  lua_rawseti(L, -2, len + 1);
  return SDL_ENUM_CONTINUE;
}

static int f_list_dir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  lua_newtable(L);
  bool res = SDL_EnumerateDirectory(path, list_dir_enumeration_callback, L);
  if (!res) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  return 1;
}


#ifdef _WIN32
  #define realpath(x, y) _wfullpath(y, x, MAX_PATH)
#endif

static int f_absolute_path(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (!wpath) { return 0; }

  LPWSTR wfullpath = realpath(wpath, NULL);
  SDL_free(wpath);
  if (!wfullpath) { return 0; }

  char *res = utfconv_wctoutf8(wfullpath);
  SDL_free(wfullpath);
#else
  char *res = realpath(path, NULL);
#endif
  if (!res) { return 0; }
  lua_pushstring(L, res);
  SDL_free(res);
  return 1;
}


static int f_get_file_info(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

  lua_newtable(L);
#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) {
    lua_pushnil(L); lua_pushstring(L, UTFCONV_ERROR_INVALID_CONVERSION);
    return 2;
  }
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!GetFileAttributesExW(wpath, GetFileExInfoStandard, &data)) {
    SDL_free(wpath);
    lua_pushnil(L); push_win32_error(L, GetLastError());
    return 2;
  }
  SDL_free(wpath);
  ULARGE_INTEGER large_int = {0};
  #define TICKS_PER_MILISECOND 10000
  #define EPOCH_DIFFERENCE 11644473600000LL
  // https://stackoverflow.com/questions/6161776/convert-windows-filetime-to-second-in-unix-linux
  large_int.HighPart = data.ftLastWriteTime.dwHighDateTime; large_int.LowPart = data.ftLastWriteTime.dwLowDateTime;
  lua_pushnumber(L, (double)((large_int.QuadPart / TICKS_PER_MILISECOND - EPOCH_DIFFERENCE)/1000.0));
  lua_setfield(L, -2, "modified");

  large_int.HighPart = data.nFileSizeHigh; large_int.LowPart = data.nFileSizeLow;
  lua_pushinteger(L, large_int.QuadPart);
  lua_setfield(L, -2, "size");

  lua_pushstring(L, data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ? "dir" : "file");
  lua_setfield(L, -2, "type");

  lua_pushboolean(L, data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY && data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
  lua_setfield(L, -2, "symlink");

  lua_pushboolean(L, (data.dwFileAttributes & FILE_ATTRIBUTE_READONLY) != 0);
  lua_setfield(L, -2, "readonly");
#else
  struct stat s;
  int err = stat(path, &s);
  if (err < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

  lua_pushinteger(L, s.st_size);
  lua_setfield(L, -2, "size");

  if (S_ISREG(s.st_mode)) {
    lua_pushstring(L, "file");
  } else if (S_ISDIR(s.st_mode)) {
    lua_pushstring(L, "dir");
  } else {
    lua_pushnil(L);
  }
  lua_setfield(L, -2, "type");

  lua_pushboolean(L, access(path, W_OK) != 0);
  lua_setfield(L, -2, "readonly");

  double mtime;
  #if _BSD_SOURCE || _SVID_SOURCE || _XOPEN_SOURCE > 700 || _POSIX_C_SOURCE >= 200809L
    mtime = (double)s.st_mtim.tv_sec + (s.st_mtim.tv_nsec / 1000000000.0);
  #elif __APPLE__
    #if !defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)
      mtime = (double)s.st_mtimespec.tv_sec + (s.st_mtimespec.tv_nsec / 1000000000.0);
    #else
      mtime = (double)s.st_mtime + (s.st_atimensec / 1000000000.0);
    #endif
  #else
    mtime = s.st_mtime;
  #endif
  lua_pushnumber(L, mtime);
  lua_setfield(L, -2, "modified");

  if (S_ISDIR(s.st_mode)) {
    if (lstat(path, &s) == 0) {
      lua_pushboolean(L, S_ISLNK(s.st_mode));
      lua_setfield(L, -2, "symlink");
    }
  }
#endif
  return 1;
}

#if __linux__
// https://man7.org/linux/man-pages/man2/statfs.2.html

struct f_type_names {
  uint32_t magic;
  const char *name;
};

static struct f_type_names fs_names[] = {
  { 0xef53,     "ext2/ext3" },
  { 0x6969,     "nfs"       },
  { 0x65735546, "fuse"      },
  { 0x517b,     "smb"       },
  { 0xfe534d42, "smb2"      },
  { 0x52654973, "reiserfs"  },
  { 0x01021994, "tmpfs"     },
  { 0x858458f6, "ramfs"     },
  { 0x5346544e, "ntfs"      },
  { 0x0,        NULL        },
};

#endif

static int f_get_fs_type(lua_State *L) {
  #if __linux__
    const char *path = luaL_checkstring(L, 1);
    struct statfs buf;
    int status = statfs(path, &buf);
    if (status != 0) {
      return luaL_error(L, "error calling statfs on %s", path);
    }
    for (int i = 0; fs_names[i].magic; i++) {
      if (fs_names[i].magic == buf.f_type) {
        lua_pushstring(L, fs_names[i].name);
        return 1;
      }
    }
  #endif
  lua_pushstring(L, "unknown");
  return 1;
}


static int f_ftruncate(lua_State *L) {
#if LUA_VERSION_NUM < 503
  // note: it is possible to support pre 5.3 and JIT
  //       since file handles are just FILE*  wrapped in a userdata;
  //       but it is not standardized. YMMV.
  #error luaL_Stream is not supported in this version of Lua.
#endif
  luaL_Stream *stream = luaL_checkudata(L, 1, LUA_FILEHANDLE);
  lua_Integer len = luaL_optinteger(L, 2, 0);
  if (ftruncate(fileno(stream->f), len) != 0) {
    lua_pushboolean(L, 0);
    lua_pushfstring(L, "ftruncate(): %s", strerror(errno));
    return 2;
  }

  lua_pushboolean(L, 1);
  return 1;
}


static int f_mkdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#ifdef _WIN32
  LPWSTR wpath = utfconv_utf8towc(path);
  if (wpath == NULL) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, UTFCONV_ERROR_INVALID_CONVERSION);
    return 2;
  }

  int err = _wmkdir(wpath);
  SDL_free(wpath);
#else
  int err = mkdir(path, S_IRUSR|S_IWUSR|S_IXUSR|S_IRGRP|S_IXGRP|S_IROTH|S_IXOTH);
#endif
  if (err < 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

  lua_pushboolean(L, 1);
  return 1;
}


static int f_get_clipboard(lua_State *L) {
  char *text = SDL_GetClipboardText();
  if (!text) { return 0; }
#ifdef _WIN32
  // on windows, text-based clipboard formats must terminate with \r\n
  // we need to convert it to \n for Lite XL to read them properly
  // https://learn.microsoft.com/en-us/windows/win32/dataxchg/standard-clipboard-formats
  luaL_gsub(L, text, "\r\n", "\n");
#else
  lua_pushstring(L, text);
#endif
  SDL_free(text);
  return 1;
}


static int f_set_clipboard(lua_State *L) {
  const char *text = luaL_checkstring(L, 1);
  SDL_SetClipboardText(text);
  return 0;
}


static int f_get_primary_selection(lua_State *L) {
  char *text = SDL_GetPrimarySelectionText();
  if (!text) { return 0; }
  lua_pushstring(L, text);
  SDL_free(text);
  return 1;
}


static int f_set_primary_selection(lua_State *L) {
  const char *text = luaL_checkstring(L, 1);
  SDL_SetPrimarySelectionText(text);
  return 0;
}


static int f_get_process_id(lua_State *L) {
#ifdef _WIN32
  lua_pushinteger(L, GetCurrentProcessId());
#else
  lua_pushinteger(L, getpid());
#endif
  return 1;
}


static int f_get_time(lua_State *L) {
  double n = SDL_GetPerformanceCounter() / (double) SDL_GetPerformanceFrequency();
  lua_pushnumber(L, n);
  return 1;
}


static int f_sleep(lua_State *L) {
  double n = luaL_checknumber(L, 1);
  if (n < 0) n = 0;
  SDL_Delay(n * 1000);
  return 0;
}


static int f_exec(lua_State *L) {
  size_t len;
  const char *cmd = luaL_checklstring(L, 1, &len);
  char *buf = SDL_malloc(len + 32);
  if (!buf) { luaL_error(L, "buffer allocation failed"); }
#if _WIN32
  sprintf(buf, "cmd /c \"%s\"", cmd);
  WinExec(buf, SW_HIDE);
#else
  sprintf(buf, "%s &", cmd);
  int res = system(buf);
  (void) res;
#endif
  SDL_free(buf);
  return 0;
}

static int f_fuzzy_match(lua_State *L) {
  size_t strLen, ptnLen;
  const char *str = luaL_checklstring(L, 1, &strLen);
  const char *ptn = luaL_checklstring(L, 2, &ptnLen);
  // If true match things *backwards*. This allows for better matching on filenames than the above
  // function. For example, in the lite project, opening "renderer" has lib/font_render/build.sh
  // as the first result, rather than src/renderer.c. Clearly that's wrong.
  bool files = lua_gettop(L) > 2 && lua_isboolean(L,3) && lua_toboolean(L, 3);
  int score = 0, run = 0, increment = files ? -1 : 1;
  const char* strTarget = files ? str + strLen - 1 : str;
  const char* ptnTarget = files ? ptn + ptnLen - 1 : ptn;
  while (strTarget >= str && ptnTarget >= ptn && *strTarget && *ptnTarget) {
    while (strTarget >= str && *strTarget == ' ') { strTarget += increment; }
    while (ptnTarget >= ptn && *ptnTarget == ' ') { ptnTarget += increment; }
    if (tolower(*strTarget) == tolower(*ptnTarget)) {
      score += run * 10 - (*strTarget != *ptnTarget);
      run++;
      ptnTarget += increment;
    } else {
      score -= 10;
      run = 0;
    }
    strTarget += increment;
  }
  if (ptnTarget >= ptn && *ptnTarget) { return 0; }
  lua_pushinteger(L, score - (int)strLen * 10);
  return 1;
}

static int f_set_window_opacity(lua_State *L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  double n = luaL_checknumber(L, 2);
  int r = SDL_SetWindowOpacity(window_renderer->window, n);
  lua_pushboolean(L, r > -1);
  return 1;
}

typedef void (*fptr)(void);

typedef struct lua_function_node {
  const char *symbol;
  fptr address;
} lua_function_node;

#define P(FUNC) { "lua_" #FUNC, (fptr)(lua_##FUNC) }
#define U(FUNC) { "luaL_" #FUNC, (fptr)(luaL_##FUNC) }
#define S(FUNC) { #FUNC, (fptr)(FUNC) }
static void* api_require(const char* symbol) {
  static const lua_function_node nodes[] = {
    #if LUA_VERSION_NUM == 501 || LUA_VERSION_NUM == 502 || LUA_VERSION_NUM == 503 || LUA_VERSION_NUM == 504
    U(addlstring), U(addstring), U(addvalue), U(argerror), U(buffinit),
    U(callmeta), U(checkany), U(checkinteger), U(checklstring),
    U(checknumber), U(checkoption), U(checkstack), U(checktype),
    U(checkudata), U(error), U(getmetafield), U(gsub), U(loadstring),
    U(newmetatable), U(newstate), U(openlibs), U(optinteger), U(optlstring),
    U(optnumber), U(pushresult), U(ref), U(unref), U(where), P(atpanic),
    P(checkstack), P(close), P(concat), P(createtable), P(dump), P(error),
    P(gc), P(getallocf), P(getfield), P(gethook), P(gethookcount),
    P(gethookmask), P(getinfo), P(getlocal), P(getmetatable), P(getstack),
    P(gettable), P(gettop), P(getupvalue), P(iscfunction), P(isnumber),
    P(isstring), P(isuserdata), P(load), P(newstate), P(newthread), P(next),
    P(pushboolean), P(pushcclosure), P(pushfstring), P(pushinteger),
    P(pushlightuserdata), P(pushlstring), P(pushnil), P(pushnumber),
    P(pushstring), P(pushthread), P(pushvalue), P(pushvfstring), P(rawequal),
    P(rawget), P(rawgeti), P(rawset), P(rawseti), P(resume), P(setallocf),
    P(setfield), P(sethook), P(setlocal), P(setmetatable), P(settable),
    P(settop), P(setupvalue), P(status), P(toboolean), P(tocfunction),
    P(tolstring), P(topointer), P(tothread), P(touserdata), P(type),
    P(typename), P(xmove), S(luaopen_base), S(luaopen_debug), S(luaopen_io),
    S(luaopen_math), S(luaopen_os), S(luaopen_package), S(luaopen_string),
    S(luaopen_table), S(api_load_libs),
    #endif
    #if LUA_VERSION_NUM == 502 || LUA_VERSION_NUM == 503 || LUA_VERSION_NUM == 504
    U(buffinitsize), U(checkversion_), U(execresult), U(fileresult),
    U(getsubtable), U(len), U(loadbufferx), U(loadfilex), U(prepbuffsize),
    U(pushresultsize), U(requiref), U(setfuncs), U(setmetatable),
    U(testudata), U(tolstring), U(traceback), P(absindex), P(arith),
    P(callk), P(compare), P(copy), P(getglobal), P(len), P(pcallk),
    P(rawgetp), P(rawlen), P(rawsetp), P(setglobal), P(tointegerx),
    P(tonumberx), P(upvalueid), P(upvaluejoin), P(version), P(yieldk),
    S(luaopen_coroutine),
    #endif
    #if LUA_VERSION_NUM == 501 || LUA_VERSION_NUM == 502 || LUA_VERSION_NUM == 503
    P(newuserdata),
    #endif
    #if LUA_VERSION_NUM == 503 || LUA_VERSION_NUM == 504
    P(geti), P(isinteger), P(isyieldable), P(rotate), P(seti),
    P(stringtonumber), S(luaopen_utf8),
    #endif
    #if LUA_VERSION_NUM == 502 || LUA_VERSION_NUM == 503
    P(getuservalue), P(setuservalue), S(luaopen_bit32),
    #endif
    #if LUA_VERSION_NUM == 501 || LUA_VERSION_NUM == 502
    P(insert), P(remove), P(replace),
    #endif
    #if LUA_VERSION_NUM == 504
    U(addgsub), U(typeerror), P(closeslot), P(getiuservalue),
    P(newuserdatauv), P(resetthread), P(setcstacklimit), P(setiuservalue),
    P(setwarnf), P(toclose), P(warning),
    #endif
    #if LUA_VERSION_NUM == 502
    U(checkunsigned), U(optunsigned), P(getctx), P(pushunsigned),
    P(tounsignedx),
    #endif
    #if LUA_VERSION_NUM == 501
    U(findtable), U(loadbuffer), U(loadfile), U(openlib), U(prepbuffer),
    U(register), U(typerror), P(call), P(cpcall), P(equal), P(getfenv),
    P(lessthan), P(objlen), P(pcall), P(setfenv), P(setlevel), P(tointeger),
    P(tonumber), P(yield),
    #endif
  };
  for (size_t i = 0; i < sizeof(nodes) / sizeof(lua_function_node); ++i) {
    if (strcmp(nodes[i].symbol, symbol) == 0)
      return *(void**)(&nodes[i].address);
  }
  return NULL;
}

static int f_library_gc(lua_State *L) {
  lua_getfield(L, 1, "handle");
  void* handle = lua_touserdata(L, -1);
  SDL_UnloadObject(handle);

  return 0;
}

static int f_load_native_plugin(lua_State *L) {
  char entrypoint_name[512]; entrypoint_name[sizeof(entrypoint_name) - 1] = '\0';
  int result;

  const char *name = luaL_checkstring(L, 1);
  const char *path = luaL_checkstring(L, 2);
  void *library = SDL_LoadObject(path);
  if (!library)
    return (lua_pushstring(L, SDL_GetError()), lua_error(L));

  lua_getglobal(L, "package");
  lua_getfield(L, -1, "native_plugins");
  lua_newtable(L);
  lua_pushlightuserdata(L, library);
  lua_setfield(L, -2, "handle");
  luaL_setmetatable(L, API_TYPE_NATIVE_PLUGIN);
  lua_setfield(L, -2, name);
  lua_pop(L, 2);

  const char *basename = strrchr(name, '.');
  basename = !basename ? name : basename + 1;
  snprintf(entrypoint_name, sizeof(entrypoint_name), "luaopen_lite_xl_%s", basename);
  int (*ext_entrypoint) (lua_State *L, void* (*)(const char*));
  *(void**)(&ext_entrypoint) = SDL_LoadFunction(library, entrypoint_name);
  if (!ext_entrypoint) {
    snprintf(entrypoint_name, sizeof(entrypoint_name), "luaopen_%s", basename);
    int (*entrypoint)(lua_State *L);
    *(void**)(&entrypoint) = SDL_LoadFunction(library, entrypoint_name);
    if (!entrypoint)
      return luaL_error(L, "Unable to load %s: Can't find %s(lua_State *L, void *XL)", name, entrypoint_name);
    result = entrypoint(L);
  } else {
    result = ext_entrypoint(L, api_require);
  }

  if (!result)
    return luaL_error(L, "Unable to load %s: entrypoint must return a value", name);

  return result;
}

#ifdef _WIN32
#define PATHSEP '\\'
#else
#define PATHSEP '/'
#endif

/* Special purpose filepath compare function. Corresponds to the
   order used in the TreeView view of the project's files. Returns true if
   path1 < path2 in the TreeView order. */
static int f_path_compare(lua_State *L) {
  size_t len1, len2;
  const char *path1 = luaL_checklstring(L, 1, &len1);
  const char *type1_s = luaL_checkstring(L, 2);
  const char *path2 = luaL_checklstring(L, 3, &len2);
  const char *type2_s = luaL_checkstring(L, 4);
  int type1 = strcmp(type1_s, "dir") != 0;
  int type2 = strcmp(type2_s, "dir") != 0;
  /* Find the index of the common part of the path. */
  size_t offset = 0, i, j;
  for (i = 0; i < len1 && i < len2; i++) {
    if (path1[i] != path2[i]) break;
    if (path1[i] == PATHSEP) {
      offset = i + 1;
    }
  }
  /* If a path separator is present in the name after the common part we consider
     the entry like a directory. */
  if (strchr(path1 + offset, PATHSEP)) {
    type1 = 0;
  }
  if (strchr(path2 + offset, PATHSEP)) {
    type2 = 0;
  }
  /* If types are different "dir" types comes before "file" types. */
  if (type1 != type2) {
    lua_pushboolean(L, type1 < type2);
    return 1;
  }
  /* If types are the same compare the files' path alphabetically. */
  int cfr = -1;
  bool same_len = len1 == len2;
  for (i = offset, j = offset; i <= len1 && j <= len2; i++, j++) {
    if (path1[i] == 0 || path2[j] == 0) {
      if (cfr < 0) cfr = 0; // The strings are equal
      if (!same_len) {
        cfr = (path1[i] == 0);
      }
    } else if (isdigit(path1[i]) && isdigit(path2[j])) {
      size_t ii = 0, ij = 0;
      while (isdigit(path1[i+ii])) { ii++; }
      while (isdigit(path2[j+ij])) { ij++; }

      size_t di = 0, dj = 0;
      for (size_t ai = 0; ai < ii; ++ai) {
        di = di * 10 + (path1[i+ai] - '0');
      }
      for (size_t aj = 0; aj < ij; ++aj) {
        dj = dj * 10 + (path2[j+aj] - '0');
      }

      if (di == dj) {
        continue;
      }
      cfr = (di < dj);
    } else if (path1[i] == path2[j]) {
      continue;
    } else if (path1[i] == PATHSEP || path2[j] == PATHSEP) {
      /* For comparison we treat PATHSEP as if it was the string terminator. */
      cfr = (path1[i] == PATHSEP);
    } else {
      char a = path1[i], b = path2[j];
      if (a >= 'A' && a <= 'Z') a += 32;
      if (b >= 'A' && b <= 'Z') b += 32;
      if (a == b) {
        /* If the strings have the same length, we need
           to keep the first case sensitive difference. */
        if (same_len && cfr < 0) {
          /* Give priority to lower-case characters */
          cfr = (path1[i] > path2[j]);
        }
        continue;
      }
      cfr = (a < b);
    }
    break;
  }
  lua_pushboolean(L, cfr);
  return 1;
}


static int f_text_input(lua_State* L) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  if (!window_renderer) return 0;
  if (lua_toboolean(L, 2)) {
    SDL_StartTextInput(window_renderer->window);
  } else {
    SDL_StopTextInput(window_renderer->window);
  }
  return 0;
}

static int f_setenv(lua_State* L) {
  const char *key = luaL_checkstring(L, 1);
  const char *val = luaL_checkstring(L, 2);
  // right now we overwrite unconditionally
  lua_pushboolean(L, SDL_setenv_unsafe(key, val, 1) == 0);
  return 1;
}

typedef struct {
  uintptr_t id;
  SDL_DialogFileFilter *filters;
  size_t n_filters;
} DialogData;

static void free_dialog_filters(SDL_DialogFileFilter *filters, size_t n_filters) {
  for (size_t i = 0; i < n_filters; i++) {
    SDL_free((char *)filters[i].name);
    SDL_free((char *)filters[i].pattern);
  }
}

static void dialog_callback(void *userdata, const char * const *filelist, int filter) {
  // TODO: support getting the selected filter?
  //       as of SDL 3.2.10 only the windows backend supports that,
  //       the others just return -1
  CustomEvent event;
  SDL_zero(event);
  DialogData *dd = userdata;

  event.data1 = (void *)dd->id;

  // Filters had to be available until this callback was called,
  // so we can free them now
  free_dialog_filters(dd->filters, dd->n_filters);
  SDL_free(dd->filters);
  SDL_free(dd);

  if (filelist == NULL) {
    event.code = DIALOG_ERROR;
    event.data2 = SDL_strdup(SDL_GetError());
  } else if (*filelist == NULL) {
    event.code = DIALOG_CANCEL;
  } else {
    event.code = DIALOG_OK;

    // Calculate total size needed for every entry
    size_t bytes = 0;
    for (size_t i = 0; filelist[i] != NULL; i++) {
      bytes += SDL_strlen(filelist[i]) + 1;
    }
    
    char *dataptr = event.data2 = SDL_malloc(bytes + 1); // +1 for NULL last entry
    if (event.data2 == NULL) {
      event.code = DIALOG_ERROR;
    } else {
      for (size_t i = 0; filelist[i] != NULL; i++) {
        size_t len = SDL_strlen(filelist[i]) + 1;
        SDL_memcpy(dataptr, filelist[i], len);
        dataptr += len;
      }
      *dataptr = '\0'; // NULL last entry
    }
  }
  if (!push_custom_event(dialogfinished_event_name, &event)) {
    // TODO: panic?
    SDL_free(event.data2);
  }
}

static SDL_DialogFileFilter *get_dialog_filters(lua_State* L, int index, lxl_arena *A, size_t *n_filters) {
  if (index < 0) {
    index += lua_gettop(L) + 1;
  }

  *n_filters = 0;
  if (lua_isnoneornil(L, index)) {
    return NULL;
  }

  size_t n = luaL_len(L, index);
  if (n == 0) {
    return NULL;
  }

  SDL_DialogFileFilter *filters = lxl_arena_malloc(A, n * sizeof(SDL_DialogFileFilter));

  for (size_t i = 0; i < n; i++) {
    size_t str_size = 0;
    const char *tmp;

    lua_geti(L, index, i + 1);

    lua_getfield(L, -1, "name");
    tmp = luaL_checklstring(L, -1, &str_size);
    filters[i].name = lxl_arena_copy(A, tmp, str_size + 1);

    lua_getfield(L, -2, "pattern");
    tmp = luaL_checklstring(L, -1, &str_size);
    filters[i].pattern = lxl_arena_copy(A, tmp, str_size + 1);

    lua_pop(L, 3);
  }

  *n_filters = n;
  return filters;
}

typedef struct {
  bool allow_many;
  char *default_location;
  char *title;
  char *accept_label;
  char *cancel_label;
} DialogOptions;

static void get_dialog_options(lua_State* L, int index, SDL_FileDialogType type, lxl_arena *A, DialogOptions *options, SDL_DialogFileFilter **filters, size_t *n_filters) {
  if (index < 0) {
    index += lua_gettop(L) + 1;
  }
  options->allow_many = false;
  options->default_location = NULL;
  options->title = NULL;
  options->accept_label = NULL;
  options->cancel_label = NULL;
  *filters = NULL;
  *n_filters = 0;

  if (lua_isnoneornil(L, index)) {
    // No options specified
    return;
  }
  luaL_checktype(L, index, LUA_TTABLE);

  size_t str_size = 0;
  const char* tmp;

  lua_getfield(L, index, "default_location");
  tmp = luaL_optlstring(L, -1, NULL, &str_size);
  options->default_location = lxl_arena_copy(A, tmp, str_size + 1);

  lua_getfield(L, index, "title");
  tmp = luaL_optlstring(L, -1, NULL, &str_size);
  options->title = lxl_arena_copy(A, tmp, str_size + 1);

  lua_getfield(L, index, "accept_label");
  tmp = luaL_optlstring(L, -1, NULL, &str_size);
  options->accept_label = lxl_arena_copy(A, tmp, str_size + 1);

  lua_getfield(L, index, "cancel_label");
  tmp = luaL_optlstring(L, -1, NULL, &str_size);
  options->cancel_label = lxl_arena_copy(A, tmp, str_size + 1);

  lua_pop(L, 4);

  if (type == SDL_FILEDIALOG_OPENFILE || type == SDL_FILEDIALOG_OPENFOLDER) {
    lua_getfield(L, index, "allow_many");
    options->allow_many = luaL_opt(L, lua_toboolean, -1, false);
    lua_pop(L, 1);
  }

  if (type == SDL_FILEDIALOG_OPENFILE || type == SDL_FILEDIALOG_SAVEFILE) {
    lua_getfield(L, index, "filters");
    *filters = get_dialog_filters(L, -1, A, n_filters);
    lua_pop(L, 1);
  }
}

static int open_dialog(lua_State* L, SDL_FileDialogType type) {
  RenWindow *window_renderer = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  uintptr_t id = luaL_checkinteger(L, 2);
  DialogOptions options;
  SDL_zero(options);
  SDL_DialogFileFilter *arena_filters = NULL;
  size_t n_filters = 0;

  if (!lua_isnoneornil(L, 3)) {
    get_dialog_options(
      L, 3, type,
      lxl_arena_init(L),
      &options, &arena_filters, &n_filters
    );
  }

  SDL_PropertiesID props = SDL_CreateProperties();
  if (props == 0) {
    return luaL_error(L, "Error while creating SDL Property: %s", SDL_GetError());
  }

  DialogData *dd = SDL_calloc(1, sizeof(DialogData));
  if (dd == NULL) {
    return luaL_error(L, "Unable to allocate DialogData memory");
  }
  dd->id = id;
  dd->n_filters = n_filters;
  dd->filters = SDL_malloc(n_filters * sizeof(SDL_DialogFileFilter));

  if (dd->filters == NULL) {
    SDL_free(dd);
    return luaL_error(L, "Unable to allocate SDL_DialogFileFilter memory");
  }

  // SDL needs the filters to be available at least until the callback is called.
  // arena_filters memory is handled by Lua so we can't use it as-is
  for (size_t i = 0; i < n_filters; i++) {
    dd->filters[i].name = SDL_strdup(arena_filters[i].name);
    dd->filters[i].pattern = SDL_strdup(arena_filters[i].pattern);
    if (dd->filters[i].name == NULL || dd->filters[i].pattern == NULL) {
      free_dialog_filters(dd->filters, i);
      SDL_free(dd->filters);
      SDL_free(dd);
      return luaL_error(L, "Unable to allocate memory for SDL_DialogFileFilter values");
    }
  }

  SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_FILTERS_POINTER, dd->filters);
  SDL_SetNumberProperty(props, SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, n_filters);
  SDL_SetPointerProperty(props, SDL_PROP_FILE_DIALOG_WINDOW_POINTER, window_renderer->window);
  SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_LOCATION_STRING, options.default_location);
  SDL_SetBooleanProperty(props, SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, options.allow_many);
  SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_TITLE_STRING, options.title);
  SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_ACCEPT_STRING, options.accept_label);
  SDL_SetStringProperty(props, SDL_PROP_FILE_DIALOG_CANCEL_STRING, options.cancel_label);

  SDL_ShowFileDialogWithProperties(type, dialog_callback, dd, props);

  SDL_DestroyProperties(props);
  return 0;
}

static int dialogfinished_callback(lua_State *L, SDL_Event *e) {
  lua_pushstring(L, "dialogfinished");
  lua_pushinteger(L, (uintptr_t)e->user.data1); // ID

  switch ((DialogState)e->user.code) {
    case DIALOG_OK:
      lua_pushstring(L, "accept");
      char *dataptr = e->user.data2;
      lua_newtable(L);
      for (size_t i = 1; *dataptr != '\0'; i++) {
        lua_pushstring(L, dataptr);
        size_t len = lua_rawlen(L, -1) + 1;
        lua_rawseti(L, -2, i);
        dataptr += len;
      }
      SDL_free(e->user.data2);
      return 4;
    case DIALOG_CANCEL:
      lua_pushstring(L, "cancel");
      return 3;
    case DIALOG_ERROR:
      lua_pushstring(L, "error");
      lua_pushstring(L, e->user.data2);
      SDL_free(e->user.data2);
      return 4;
    default:
      lua_pushstring(L, "unknown");
      return 3;
  }
}

static int fileloadprogress_callback(lua_State *L, SDL_Event *e) {
  FileLoadProgressPayload *payload = e->user.data1;
  lua_pushstring(L, fileloadprogress_event_name);
  lua_pushnumber(L, (lua_Number) payload->job_id);
  lua_pushnumber(L, (lua_Number) payload->bytes_read);
  lua_pushnumber(L, (lua_Number) payload->total_bytes);
  lua_pushnumber(L, (lua_Number) payload->lines_read);
  SDL_free(payload);
  return 5;
}

static int fileloadcomplete_callback(lua_State *L, SDL_Event *e) {
  lua_pushstring(L, fileloadcomplete_event_name);
  lua_pushnumber(L, (lua_Number) (uintptr_t) e->user.data1);
  return 2;
}

static int fileloaderror_callback(lua_State *L, SDL_Event *e) {
  lua_pushstring(L, fileloaderror_event_name);
  lua_pushnumber(L, (lua_Number) (uintptr_t) e->user.data1);
  lua_pushstring(L, e->user.data2 ? (const char *) e->user.data2 : "Unknown file load error");
  SDL_free(e->user.data2);
  return 3;
}

static int fileindexprogress_callback(lua_State *L, SDL_Event *e) {
  FileIndexProgressPayload *payload = e->user.data1;
  lua_pushstring(L, fileindexprogress_event_name);
  lua_pushnumber(L, (lua_Number) payload->job_id);
  lua_pushnumber(L, (lua_Number) payload->bytes_read);
  lua_pushnumber(L, (lua_Number) payload->total_bytes);
  lua_pushnumber(L, (lua_Number) payload->lines_read);
  SDL_free(payload);
  return 5;
}

static int fileindexcomplete_callback(lua_State *L, SDL_Event *e) {
  lua_pushstring(L, fileindexcomplete_event_name);
  lua_pushnumber(L, (lua_Number) (uintptr_t) e->user.data1);
  return 2;
}

static int fileindexerror_callback(lua_State *L, SDL_Event *e) {
  lua_pushstring(L, fileindexerror_event_name);
  lua_pushnumber(L, (lua_Number) (uintptr_t) e->user.data1);
  lua_pushstring(L, e->user.data2 ? (const char *) e->user.data2 : "Unknown file index error");
  SDL_free(e->user.data2);
  return 3;
}

static int f_open_file_dialog(lua_State* L) {
  return open_dialog(L, SDL_FILEDIALOG_OPENFILE);
}

static int f_save_file_dialog(lua_State* L) {
  return open_dialog(L, SDL_FILEDIALOG_SAVEFILE);
}

static int f_open_directory_dialog(lua_State* L) {
  return open_dialog(L, SDL_FILEDIALOG_OPENFOLDER);
}

static int f_open_file_async(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  char *error_message = NULL;
  size_t file_size = 0;
  if (!get_utf8_file_size(path, &file_size, &error_message)) {
    int result = luaL_error(L, "Unable to stat file %s: %s", path, error_message ? error_message : "unknown error");
    SDL_free(error_message);
    return result;
  }
  SDL_free(error_message);

  if (file_load_jobs_mutex == NULL) {
    file_load_jobs_mutex = SDL_CreateMutex();
    if (file_load_jobs_mutex == NULL) {
      return luaL_error(L, "Unable to create async file load mutex: %s", SDL_GetError());
    }
  }

  FileLoadJob *job = SDL_calloc(1, sizeof(FileLoadJob));
  if (job == NULL) {
    return luaL_error(L, "Unable to allocate async file load job");
  }

  job->path = SDL_strdup(path);
  if (job->path == NULL) {
    SDL_free(job);
    return luaL_error(L, "Unable to allocate async file load path");
  }

  SDL_LockMutex(file_load_jobs_mutex);
  job->id = next_file_load_job_id++;
  job->file_size = file_size;
  job->state = FILE_LOAD_RUNNING;
  job->next = file_load_jobs;
  file_load_jobs = job;
  SDL_UnlockMutex(file_load_jobs_mutex);
  debug_bp_async_open_file_job_created(job);

  job->thread = SDL_CreateThread(file_load_thread, "file_load_thread", job);
  if (job->thread == NULL) {
    SDL_LockMutex(file_load_jobs_mutex);
    remove_file_load_job_locked(job->id);
    SDL_UnlockMutex(file_load_jobs_mutex);
    free_file_load_job(job);
    return luaL_error(L, "Unable to create async file load thread: %s", SDL_GetError());
  }

  lua_pushnumber(L, (lua_Number) job->id);
  lua_pushnumber(L, (lua_Number) file_size);
  return 2;
}

static int f_take_async_file_result_chunk(lua_State *L) {
  uintptr_t job_id = (uintptr_t) luaL_checknumber(L, 1);
  lua_Integer max_lines = luaL_optinteger(L, 2, 512);
  if (max_lines < 1) max_lines = 1;
  if (file_load_jobs_mutex == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "Async file loading is not initialized");
    return 2;
  }

  SDL_LockMutex(file_load_jobs_mutex);
  FileLoadJob *job = find_file_load_job_locked(job_id);
  if (job == NULL) {
    SDL_UnlockMutex(file_load_jobs_mutex);
    lua_pushnil(L);
    lua_pushstring(L, "Unknown async file load job");
    return 2;
  }
  if (job->state == FILE_LOAD_ERROR) {
    job = remove_file_load_job_locked(job_id);
    SDL_UnlockMutex(file_load_jobs_mutex);
    lua_pushnil(L);
    lua_pushstring(L, job->error_message ? job->error_message : "Unknown file load error");
    free_file_load_job(job);
    return 2;
  }

  FileLoadChunk *out_head = NULL;
  FileLoadChunk *out_tail = NULL;
  size_t out_count = 0;
  if (job->queue_head != NULL && job->queue_head->line_count > (size_t) max_lines) {
    max_lines = (lua_Integer) job->queue_head->line_count;
  }
  while (job->queue_head != NULL && out_count < (size_t) max_lines) {
    FileLoadChunk *chunk = job->queue_head;
    job->queue_head = chunk->next;
    if (job->queue_head == NULL) {
      job->queue_tail = NULL;
    }
    chunk->next = NULL;
    if (out_tail != NULL) {
      out_tail->next = chunk;
    } else {
      out_head = chunk;
    }
    out_tail = chunk;
    out_count += chunk->line_count;
  }
  job->delivered_lines += out_count;
  size_t total_line_count = job->lines_read;
  size_t delivered_line_count = job->delivered_lines;
  size_t bytes_read = job->bytes_read;
  bool crlf = job->crlf;
  bool running = job->state == FILE_LOAD_RUNNING;
  bool done = !running && job->queue_head == NULL;
  if (done) {
    job = remove_file_load_job_locked(job_id);
  }
  SDL_UnlockMutex(file_load_jobs_mutex);

  lua_newtable(L);
  lua_createtable(L, out_count > (size_t) INT_MAX ? INT_MAX : (int) out_count, 0);
  lua_Integer out_index = 1;
  for (FileLoadChunk *chunk = out_head; chunk != NULL; ) {
    for (size_t i = 0; i < chunk->line_count; i++) {
      lua_pushlstring(L, chunk->lines[i].data, chunk->lines[i].len);
      lua_rawseti(L, -2, out_index++);
      SDL_free(chunk->lines[i].data);
      chunk->lines[i].data = NULL;
      chunk->lines[i].len = 0;
    }
    FileLoadChunk *next = chunk->next;
    free_file_load_chunk(chunk);
    chunk = next;
  }
  lua_setfield(L, -2, "lines");
  lua_pushboolean(L, done);
  lua_setfield(L, -2, "done");
  lua_pushboolean(L, running);
  lua_setfield(L, -2, "running");
  lua_pushboolean(L, crlf);
  lua_setfield(L, -2, "crlf");
  lua_pushnumber(L, (lua_Number) job->file_size);
  lua_setfield(L, -2, "size");
  lua_pushnumber(L, (lua_Number) total_line_count);
  lua_setfield(L, -2, "line_count");
  lua_pushnumber(L, (lua_Number) delivered_line_count);
  lua_setfield(L, -2, "loaded_line_count");
  lua_pushnumber(L, (lua_Number) bytes_read);
  lua_setfield(L, -2, "bytes_read");
  debug_bp_async_chunk_dequeued(job_id, out_count, delivered_line_count, running, done);

  if (done) {
    free_file_load_job(job);
  }
  return 1;
}

static int f_discard_async_file_result(lua_State *L) {
  uintptr_t job_id = (uintptr_t) luaL_checknumber(L, 1);
  if (file_load_jobs_mutex == NULL) {
    lua_pushboolean(L, 0);
    return 1;
  }

  SDL_LockMutex(file_load_jobs_mutex);
  FileLoadJob *job = find_file_load_job_locked(job_id);
  if (job == NULL) {
    SDL_UnlockMutex(file_load_jobs_mutex);
    lua_pushboolean(L, 0);
    return 1;
  }

  if (job->state == FILE_LOAD_RUNNING) {
    job->discard_requested = true;
    SDL_UnlockMutex(file_load_jobs_mutex);
    lua_pushboolean(L, 1);
    return 1;
  }

  job = remove_file_load_job_locked(job_id);
  SDL_UnlockMutex(file_load_jobs_mutex);
  free_file_load_job(job);
  lua_pushboolean(L, 1);
  return 1;
}

static int f_open_file_index_async(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  char *error_message = NULL;
  size_t file_size = 0;
  if (!get_utf8_file_size(path, &file_size, &error_message)) {
    int result = luaL_error(L, "Unable to stat file %s: %s", path, error_message ? error_message : "unknown error");
    SDL_free(error_message);
    return result;
  }
  SDL_free(error_message);

  if (file_index_mutex == NULL) {
    file_index_mutex = SDL_CreateMutex();
    if (file_index_mutex == NULL) {
      return luaL_error(L, "Unable to create file index mutex: %s", SDL_GetError());
    }
  }

  FileIndexJob *job = SDL_calloc(1, sizeof(FileIndexJob));
  FileIndex *index = SDL_calloc(1, sizeof(FileIndex));
  if (job == NULL || index == NULL) {
    SDL_free(job);
    SDL_free(index);
    return luaL_error(L, "Unable to allocate file index job");
  }

  job->path = SDL_strdup(path);
  index->path = SDL_strdup(path);
  if (job->path == NULL || index->path == NULL) {
    job->index = index;
    free_file_index_job(job);
    return luaL_error(L, "Unable to allocate file index path");
  }

  job->file_size = file_size;
  job->index = index;
  index->file_size = file_size;

  SDL_LockMutex(file_index_mutex);
  job->id = next_file_index_job_id++;
  job->state = FILE_LOAD_RUNNING;
  job->next = file_index_jobs;
  file_index_jobs = job;
  SDL_UnlockMutex(file_index_mutex);

  job->thread = SDL_CreateThread(file_index_thread, "file_index_thread", job);
  if (job->thread == NULL) {
    SDL_LockMutex(file_index_mutex);
    remove_file_index_job_locked(job->id);
    SDL_UnlockMutex(file_index_mutex);
    free_file_index_job(job);
    return luaL_error(L, "Unable to create file index thread: %s", SDL_GetError());
  }

  lua_pushnumber(L, (lua_Number) job->id);
  lua_pushnumber(L, (lua_Number) file_size);
  return 2;
}

static int f_take_file_index_result(lua_State *L) {
  uintptr_t job_id = (uintptr_t) luaL_checknumber(L, 1);
  if (file_index_mutex == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "File indexing is not initialized");
    return 2;
  }

  SDL_LockMutex(file_index_mutex);
  FileIndexJob *job = find_file_index_job_locked(job_id);
  if (job == NULL) {
    SDL_UnlockMutex(file_index_mutex);
    lua_pushnil(L);
    lua_pushstring(L, "Unknown file index job");
    return 2;
  }
  if (job->state == FILE_LOAD_RUNNING) {
    SDL_UnlockMutex(file_index_mutex);
    lua_pushnil(L);
    lua_pushstring(L, "File index is still running");
    return 2;
  }
  job = remove_file_index_job_locked(job_id);
  SDL_UnlockMutex(file_index_mutex);

  if (job->state == FILE_LOAD_ERROR) {
    lua_pushnil(L);
    lua_pushstring(L, job->error_message ? job->error_message : "Unknown file index error");
    free_file_index_job(job);
    return 2;
  }

  FileIndex *index = job->index;
  job->index = NULL;
  if (job->thread) {
    SDL_WaitThread(job->thread, NULL);
    job->thread = NULL;
  }

  SDL_LockMutex(file_index_mutex);
  index->id = next_file_index_id++;
  index->next = file_indexes;
  file_indexes = index;
  SDL_UnlockMutex(file_index_mutex);

  lua_newtable(L);
  lua_pushnumber(L, (lua_Number) index->id);
  lua_setfield(L, -2, "index_id");
  lua_pushnumber(L, (lua_Number) index->file_size);
  lua_setfield(L, -2, "size");
  lua_pushnumber(L, (lua_Number) index->line_count);
  lua_setfield(L, -2, "line_count");
  lua_pushboolean(L, index->crlf);
  lua_setfield(L, -2, "crlf");
  free_file_index_job(job);
  return 1;
}

static int f_discard_file_index_result(lua_State *L) {
  uintptr_t job_id = (uintptr_t) luaL_checknumber(L, 1);
  if (file_index_mutex == NULL) {
    lua_pushboolean(L, 0);
    return 1;
  }
  SDL_LockMutex(file_index_mutex);
  FileIndexJob *job = find_file_index_job_locked(job_id);
  if (job != NULL && job->state == FILE_LOAD_RUNNING) {
    SDL_UnlockMutex(file_index_mutex);
    lua_pushboolean(L, 1);
    return 1;
  }
  if (job != NULL) {
    job = remove_file_index_job_locked(job_id);
  }
  SDL_UnlockMutex(file_index_mutex);
  if (job) free_file_index_job(job);
  lua_pushboolean(L, job != NULL);
  return 1;
}

static int f_close_file_index(lua_State *L) {
  uintptr_t index_id = (uintptr_t) luaL_checknumber(L, 1);
  if (file_index_mutex == NULL) {
    lua_pushboolean(L, 0);
    return 1;
  }
  SDL_LockMutex(file_index_mutex);
  FileIndex *index = remove_file_index_locked(index_id);
  SDL_UnlockMutex(file_index_mutex);
  if (index) free_file_index(index);
  lua_pushboolean(L, index != NULL);
  return 1;
}

static int f_set_file_index_path(lua_State *L) {
  uintptr_t index_id = (uintptr_t) luaL_checknumber(L, 1);
  const char *path = luaL_checkstring(L, 2);
  SDL_LockMutex(file_index_mutex);
  FileIndex *index = find_file_index_locked(index_id);
  if (index == NULL) {
    SDL_UnlockMutex(file_index_mutex);
    lua_pushboolean(L, 0);
    return 1;
  }
  char *next_path = SDL_strdup(path);
  if (next_path == NULL) {
    SDL_UnlockMutex(file_index_mutex);
    return luaL_error(L, "Unable to allocate file index path");
  }
  SDL_free(index->path);
  index->path = next_path;
  SDL_UnlockMutex(file_index_mutex);
  lua_pushboolean(L, 1);
  return 1;
}

static int f_read_indexed_lines(lua_State *L) {
  uintptr_t index_id = (uintptr_t) luaL_checknumber(L, 1);
  lua_Integer start_line = luaL_checkinteger(L, 2);
  lua_Integer count = luaL_optinteger(L, 3, 1);
  if (start_line < 1) start_line = 1;
  if (count < 0) count = 0;

  SDL_LockMutex(file_index_mutex);
  FileIndex *index = find_file_index_locked(index_id);
  SDL_UnlockMutex(file_index_mutex);
  if (index == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "Unknown file index");
    return 2;
  }

  size_t start = (size_t) start_line - 1;
  size_t end = start + (size_t) count;
  if (start > index->line_count) start = index->line_count;
  if (end > index->line_count) end = index->line_count;

  char *error_message = NULL;
  FILE *fp = open_utf8_file(index->path, "rb", &error_message);
  if (fp == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, error_message ? error_message : "Unable to open indexed file");
    SDL_free(error_message);
    return 2;
  }

  lua_createtable(L, (int) (end - start), 0);
  lua_Integer out_index = 1;
  for (size_t i = start; i < end; i++) {
    FileIndexLine *line = &index->lines[i];
    if (seek_u64(fp, line->offset) != 0) {
      fclose(fp);
      lua_pushnil(L);
      lua_pushstring(L, strerror(errno));
      return 2;
    }
    char *buf = SDL_malloc((size_t) line->raw_len + 1);
    if (buf == NULL) {
      fclose(fp);
      return luaL_error(L, "Out of memory while reading indexed line");
    }
    size_t got = fread(buf, 1, (size_t) line->raw_len, fp);
    size_t len = got;
    if (len > 0 && buf[len - 1] == '\n') len--;
    if (len > 0 && buf[len - 1] == '\r') len--;
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    luaL_addlstring(&b, buf, len);
    luaL_addchar(&b, '\n');
    luaL_pushresult(&b);
    lua_rawseti(L, -2, out_index++);
    SDL_free(buf);
  }
  fclose(fp);
  return 1;
}

static bool write_bytes_from_index(FILE *out, FILE *in, FileIndex *index, size_t first_line, size_t count) {
  char buffer[FILE_LOAD_CHUNK_SIZE];
  size_t start = first_line > 0 ? first_line - 1 : 0;
  size_t end = start + count;
  if (end > index->line_count) end = index->line_count;
  for (size_t i = start; i < end; i++) {
    FileIndexLine *line = &index->lines[i];
    if (seek_u64(in, line->offset) != 0) return false;
    Uint64 remaining = line->raw_len;
    while (remaining > 0) {
      size_t want = remaining > sizeof(buffer) ? sizeof(buffer) : (size_t) remaining;
      size_t got = fread(buffer, 1, want, in);
      if (got == 0) return false;
      if (fwrite(buffer, 1, got, out) != got) return false;
      remaining -= got;
    }
  }
  return true;
}

static bool write_lua_string_line(FILE *out, const char *text, size_t len, bool crlf) {
  if (!crlf) return fwrite(text, 1, len, out) == len;
  for (size_t i = 0; i < len; i++) {
    if (text[i] == '\n') {
      if (i == 0 || text[i - 1] != '\r') {
        if (fputc('\r', out) == EOF) return false;
      }
    }
    if (fputc((unsigned char) text[i], out) == EOF) return false;
  }
  return true;
}

static int f_write_indexed_file(lua_State *L) {
  uintptr_t index_id = (uintptr_t) luaL_checknumber(L, 1);
  const char *out_path = luaL_checkstring(L, 2);
  luaL_checktype(L, 3, LUA_TTABLE);
  bool crlf = lua_toboolean(L, 4);

  SDL_LockMutex(file_index_mutex);
  FileIndex *index = find_file_index_locked(index_id);
  SDL_UnlockMutex(file_index_mutex);
  if (index == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "Unknown file index");
    return 2;
  }

  char *error_message = NULL;
  FILE *in = open_utf8_file(index->path, "rb", &error_message);
  if (in == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, error_message ? error_message : "Unable to open source file");
    SDL_free(error_message);
    return 2;
  }
  FILE *out = open_utf8_file(out_path, "wb", &error_message);
  if (out == NULL) {
    fclose(in);
    lua_pushnil(L);
    lua_pushstring(L, error_message ? error_message : "Unable to open output file");
    SDL_free(error_message);
    return 2;
  }

  size_t piece_count = lua_rawlen(L, 3);
  for (size_t p = 1; p <= piece_count; p++) {
    lua_rawgeti(L, 3, (lua_Integer) p);
    lua_getfield(L, -1, "kind");
    const char *kind = lua_tostring(L, -1);
    lua_pop(L, 1);
    if (kind && strcmp(kind, "orig") == 0) {
      lua_getfield(L, -1, "first");
      size_t first = (size_t) lua_tointeger(L, -1);
      lua_pop(L, 1);
      lua_getfield(L, -1, "count");
      size_t count = (size_t) lua_tointeger(L, -1);
      lua_pop(L, 1);
      if (!write_bytes_from_index(out, in, index, first, count)) {
        fclose(in);
        fclose(out);
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
      }
    } else if (kind && strcmp(kind, "edit") == 0) {
      lua_getfield(L, -1, "lines");
      size_t line_count = lua_rawlen(L, -1);
      for (size_t i = 1; i <= line_count; i++) {
        size_t len = 0;
        lua_rawgeti(L, -1, (lua_Integer) i);
        const char *text = lua_tolstring(L, -1, &len);
        if (text && !write_lua_string_line(out, text, len, crlf)) {
          fclose(in);
          fclose(out);
          lua_pushnil(L);
          lua_pushstring(L, strerror(errno));
          return 2;
        }
        lua_pop(L, 1);
      }
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }

  fclose(in);
  if (fclose(out) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int f_get_sandbox(lua_State* L) {
  char *sandbox_name = "unknown";
  switch (SDL_GetSandbox()) {
    case SDL_SANDBOX_NONE:
      sandbox_name = "none";
      break;
    case SDL_SANDBOX_UNKNOWN_CONTAINER:
      sandbox_name = "unknown";
      break;
    case SDL_SANDBOX_FLATPAK:
      sandbox_name = "flatpak";
      break;
    case SDL_SANDBOX_SNAP:
      sandbox_name = "snap";
      break;
    case SDL_SANDBOX_MACOS:
      sandbox_name = "macos";
      break;
  }
  lua_pushstring(L, sandbox_name);
  return 1;
}

static const luaL_Reg lib[] = {
  { "poll_event",            f_poll_event            },
  { "wait_event",            f_wait_event            },
  { "set_cursor",            f_set_cursor            },
  { "set_window_title",      f_set_window_title      },
  { "set_window_mode",       f_set_window_mode       },
  { "get_window_mode",       f_get_window_mode       },
  { "set_window_bordered",   f_set_window_bordered   },
  { "set_window_hit_test",   f_set_window_hit_test   },
  { "get_window_size",       f_get_window_size       },
  { "get_display_bounds",    f_get_display_bounds    },
  { "set_window_size",       f_set_window_size       },
  { "set_text_input_rect",   f_set_text_input_rect   },
  { "clear_ime",             f_clear_ime             },
  { "window_has_focus",      f_window_has_focus      },
  { "raise_window",          f_raise_window          },
  { "show_fatal_error",      f_show_fatal_error      },
  { "rmdir",                 f_rmdir                 },
  { "chdir",                 f_chdir                 },
  { "mkdir",                 f_mkdir                 },
  { "list_dir",              f_list_dir              },
  { "absolute_path",         f_absolute_path         },
  { "get_file_info",         f_get_file_info         },
  { "set_file_readonly",     f_set_file_readonly     },
  { "get_clipboard",         f_get_clipboard         },
  { "set_clipboard",         f_set_clipboard         },
  { "get_primary_selection", f_get_primary_selection },
  { "set_primary_selection", f_set_primary_selection },
  { "get_process_id",        f_get_process_id        },
  { "get_time",              f_get_time              },
  { "sleep",                 f_sleep                 },
  { "exec",                  f_exec                  },
  { "fuzzy_match",           f_fuzzy_match           },
  { "set_window_opacity",    f_set_window_opacity    },
  { "load_native_plugin",    f_load_native_plugin    },
  { "path_compare",          f_path_compare          },
  { "get_fs_type",           f_get_fs_type           },
  { "text_input",            f_text_input            },
  { "setenv",                f_setenv                },
  { "ftruncate",             f_ftruncate             },
  { "open_file_dialog",      f_open_file_dialog      },
  { "save_file_dialog",      f_save_file_dialog      },
  { "open_directory_dialog", f_open_directory_dialog },
  { "open_file_async",       f_open_file_async       },
  { "take_async_file_result_chunk", f_take_async_file_result_chunk },
  { "discard_async_file_result", f_discard_async_file_result },
  { "open_file_index_async", f_open_file_index_async },
  { "take_file_index_result", f_take_file_index_result },
  { "discard_file_index_result", f_discard_file_index_result },
  { "close_file_index",      f_close_file_index      },
  { "set_file_index_path",   f_set_file_index_path   },
  { "read_indexed_lines",    f_read_indexed_lines    },
  { "write_indexed_file",    f_write_indexed_file    },
  { "get_sandbox",           f_get_sandbox           },
  { NULL, NULL }
};


int luaopen_system(lua_State *L) {
  if (!register_custom_event(dialogfinished_event_name, dialogfinished_callback)) {
    return luaL_error(L, "Unable to register custom dialogfinished event: %s", SDL_GetError());
  }
  if (!register_custom_event(fileloadprogress_event_name, fileloadprogress_callback)) {
    return luaL_error(L, "Unable to register custom fileloadprogress event: %s", SDL_GetError());
  }
  if (!register_custom_event(fileloadcomplete_event_name, fileloadcomplete_callback)) {
    return luaL_error(L, "Unable to register custom fileloadcomplete event: %s", SDL_GetError());
  }
  if (!register_custom_event(fileloaderror_event_name, fileloaderror_callback)) {
    return luaL_error(L, "Unable to register custom fileloaderror event: %s", SDL_GetError());
  }
  if (!register_custom_event(fileindexprogress_event_name, fileindexprogress_callback)) {
    return luaL_error(L, "Unable to register custom fileindexprogress event: %s", SDL_GetError());
  }
  if (!register_custom_event(fileindexcomplete_event_name, fileindexcomplete_callback)) {
    return luaL_error(L, "Unable to register custom fileindexcomplete event: %s", SDL_GetError());
  }
  if (!register_custom_event(fileindexerror_event_name, fileindexerror_callback)) {
    return luaL_error(L, "Unable to register custom fileindexerror event: %s", SDL_GetError());
  }
  if (file_load_jobs_mutex == NULL) {
    file_load_jobs_mutex = SDL_CreateMutex();
    if (file_load_jobs_mutex == NULL) {
      return luaL_error(L, "Unable to create async file load mutex: %s", SDL_GetError());
    }
  }
  if (file_index_mutex == NULL) {
    file_index_mutex = SDL_CreateMutex();
    if (file_index_mutex == NULL) {
      return luaL_error(L, "Unable to create file index mutex: %s", SDL_GetError());
    }
  }
  luaL_newmetatable(L, API_TYPE_NATIVE_PLUGIN);
  lua_pushcfunction(L, f_library_gc);
  lua_setfield(L, -2, "__gc");
  luaL_newlib(L, lib);
  return 1;
}
