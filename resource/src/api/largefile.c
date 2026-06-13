#include "api.h"

#include "../largefile_backend.h"

typedef struct LargeFileBackend **LargeFileBackendHandle;

static LargeFileBackend *check_backend(lua_State *L, int idx) {
  LargeFileBackendHandle handle = luaL_checkudata(L, idx, API_TYPE_LARGEFILE_BACKEND);
  luaL_argcheck(L, handle != NULL && *handle != NULL, idx, "largefile backend expected");
  return *handle;
}

static size_t check_nonnegative_size_arg(lua_State *L, int idx, const char *name) {
  lua_Integer value = luaL_checkinteger(L, idx);
  luaL_argcheck(L, value >= 0, idx, name);
  return (size_t) value;
}

static size_t opt_nonnegative_size_arg(lua_State *L, int idx, lua_Integer def, const char *name) {
  lua_Integer value = luaL_optinteger(L, idx, def);
  luaL_argcheck(L, value >= 0, idx, name);
  return (size_t) value;
}

static int f_largefile_backend_gc(lua_State *L) {
  LargeFileBackendHandle handle = luaL_checkudata(L, 1, API_TYPE_LARGEFILE_BACKEND);
  if (handle && *handle) {
    largefile_backend_free(*handle);
    *handle = NULL;
  }
  return 0;
}

static int f_largefile_backend_close(lua_State *L) {
  return f_largefile_backend_gc(L);
}

static int f_largefile_backend_kind(lua_State *L) {
  if (lua_gettop(L) >= 1 && luaL_testudata(L, 1, API_TYPE_LARGEFILE_BACKEND)) {
    lua_pushstring(L, largefile_backend_kind(check_backend(L, 1)));
  } else {
    lua_pushstring(L, largefile_backend_module_kind());
  }
  return 1;
}

static int f_largefile_backend_available(lua_State *L) {
  lua_pushboolean(L, largefile_backend_module_available());
  return 1;
}

static int f_largefile_backend_version(lua_State *L) {
  lua_pushstring(L, largefile_backend_module_version());
  return 1;
}

static int f_largefile_backend_create(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  size_t chunk_line_count = opt_nonnegative_size_arg(L, 2, 256, "chunk_line_count must be non-negative");
  LargeFileBackend *backend = largefile_backend_new(path, chunk_line_count);
  if (!backend) {
    return luaL_error(L, "failed to create largefile backend for %s", path);
  }
  LargeFileBackendHandle handle = lua_newuserdata(L, sizeof(LargeFileBackend *));
  *handle = backend;
  luaL_setmetatable(L, API_TYPE_LARGEFILE_BACKEND);
  return 1;
}

static int f_largefile_backend_request_window(lua_State *L) {
  LargeFileBackend *backend = check_backend(L, 1);
  size_t start_line = check_nonnegative_size_arg(L, 2, "start_line must be non-negative");
  size_t end_line = check_nonnegative_size_arg(L, 3, "end_line must be non-negative");
  size_t margin = opt_nonnegative_size_arg(L, 4, 0, "margin must be non-negative");
  largefile_backend_request_window(backend, start_line, end_line, margin);
  return 0;
}

static int f_largefile_backend_poll_window(lua_State *L) {
  LargeFileBackend *backend = check_backend(L, 1);
  if (!largefile_backend_poll_window(backend, L)) {
    lua_pushnil(L);
  }
  return 1;
}

static int f_largefile_backend_read_range(lua_State *L) {
  LargeFileBackend *backend = check_backend(L, 1);
  size_t start_line = check_nonnegative_size_arg(L, 2, "start_line must be non-negative");
  size_t start_col = check_nonnegative_size_arg(L, 3, "start_col must be non-negative");
  size_t end_line = check_nonnegative_size_arg(L, 4, "end_line must be non-negative");
  size_t end_col = check_nonnegative_size_arg(L, 5, "end_col must be non-negative");
  bool inclusive = lua_toboolean(L, 6);
  if (!largefile_backend_push_range_text(L, backend, start_line, start_col, end_line, end_col, inclusive)) {
    lua_pushnil(L);
  }
  return 1;
}

static int f_largefile_backend_cancel_noncritical_work(lua_State *L) {
  LargeFileBackend *backend = check_backend(L, 1);
  largefile_backend_cancel_noncritical_work(backend);
  return 0;
}

static int f_largefile_backend_get_loading_state(lua_State *L) {
  LargeFileBackend *backend = check_backend(L, 1);
  largefile_backend_push_loading_state(L, backend);
  return 1;
}

static int f_largefile_backend_line_count(lua_State *L) {
  LargeFileBackend *backend = check_backend(L, 1);
  lua_pushinteger(L, (lua_Integer) largefile_backend_line_count(backend));
  return 1;
}

static int f_largefile_backend_begin_save(lua_State *L) {
  LargeFileBackend *backend = check_backend(L, 1);
  const char *snapshot_path = luaL_checkstring(L, 2);
  const char *add_buffer_path = luaL_checkstring(L, 3);
  const char *source_path = luaL_checkstring(L, 4);
  const char *target_path = luaL_checkstring(L, 5);
  const char *error = NULL;
  bool ok = largefile_backend_begin_save(backend, snapshot_path, add_buffer_path, source_path, target_path, &error);
  lua_pushboolean(L, ok);
  if (!ok) {
    lua_pushstring(L, error ? error : "begin_save failed");
    return 2;
  }
  return 1;
}

static int f_largefile_backend_poll_save(lua_State *L) {
  LargeFileBackend *backend = check_backend(L, 1);
  if (!largefile_backend_poll_save(backend, L)) {
    lua_pushnil(L);
  }
  return 1;
}

static int f_largefile_backend_cancel_save(lua_State *L) {
  LargeFileBackend *backend = check_backend(L, 1);
  largefile_backend_cancel_save(backend);
  return 0;
}

static const luaL_Reg backend_m[] = {
  { "__gc", f_largefile_backend_gc },
  { "close", f_largefile_backend_close },
  { "backend_kind", f_largefile_backend_kind },
  { "request_window", f_largefile_backend_request_window },
  { "poll_window", f_largefile_backend_poll_window },
  { "read_range", f_largefile_backend_read_range },
  { "cancel_noncritical_work", f_largefile_backend_cancel_noncritical_work },
  { "get_loading_state", f_largefile_backend_get_loading_state },
  { "line_count", f_largefile_backend_line_count },
  { "begin_save", f_largefile_backend_begin_save },
  { "poll_save", f_largefile_backend_poll_save },
  { "cancel_save", f_largefile_backend_cancel_save },
  { NULL, NULL }
};

static const luaL_Reg lib[] = {
  { "backend_kind", f_largefile_backend_kind },
  { "available", f_largefile_backend_available },
  { "backend_version", f_largefile_backend_version },
  { "create_backend", f_largefile_backend_create },
  { NULL, NULL }
};

int luaopen_largefile(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_LARGEFILE_BACKEND);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, backend_m, 0);
  lua_pop(L, 1);

  luaL_newlib(L, lib);
  return 1;
}
