#ifndef LARGEFILE_BACKEND_H
#define LARGEFILE_BACKEND_H

#include <lua.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "largefile_index.h"
#include "largefile_window.h"
#include "largefile_jobs.h"

typedef struct LargeFileBackend {
  char *path;
  uint64_t file_size;
  size_t chunk_line_count;
  size_t requested_start_line;
  size_t requested_end_line;
  size_t requested_margin;
  size_t requested_epoch;
  bool request_dirty;
  bool snapshot_ready;
  size_t delivered_epoch;
  LargeFileIndex index;
  LargeFileWindowSnapshot snapshot;
  LargeFileJobState job;
  struct {
    bool active;
    bool running;
    bool complete;
    bool failed;
    bool cancel_requested;
    uint64_t written_bytes;
    uint64_t total_bytes;
    char error_message[256];
    char *snapshot_path;
    char *add_buffer_path;
    char *source_path;
    char *target_path;
  } save_job;
  void *mutex;
  void *worker_thread;
  void *save_thread;
} LargeFileBackend;

bool largefile_backend_module_available(void);
const char *largefile_backend_module_kind(void);
const char *largefile_backend_module_version(void);

LargeFileBackend *largefile_backend_new(const char *path, size_t chunk_line_count);
void largefile_backend_free(LargeFileBackend *backend);

const char *largefile_backend_kind(const LargeFileBackend *backend);
size_t largefile_backend_line_count(const LargeFileBackend *backend);
void largefile_backend_request_window(LargeFileBackend *backend, size_t start_line, size_t end_line, size_t margin);
bool largefile_backend_poll_window(LargeFileBackend *backend, lua_State *L);
bool largefile_backend_push_range_text(lua_State *L, LargeFileBackend *backend, size_t start_line, size_t start_col, size_t end_line, size_t end_col, bool inclusive);
void largefile_backend_cancel_noncritical_work(LargeFileBackend *backend);
void largefile_backend_push_loading_state(lua_State *L, const LargeFileBackend *backend);
bool largefile_backend_begin_save(LargeFileBackend *backend, const char *snapshot_path, const char *add_buffer_path, const char *source_path, const char *target_path, const char **error_out);
bool largefile_backend_poll_save(LargeFileBackend *backend, lua_State *L);
void largefile_backend_cancel_save(LargeFileBackend *backend);

#endif
