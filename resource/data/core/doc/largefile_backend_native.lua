local largefile = require "largefile"
local config = require "core.config"

local Backend = {}
Backend.__index = Backend

local function largefile_trace(fmt, ...)
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then text = tostring(fmt) end
  local fp = io.open(USERDIR .. PATHSEP .. "largefile-debug.log", "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " ", text, "\n")
    fp:close()
  end
end

function Backend.available()
  return largefile and largefile.available and largefile.available()
end

function Backend.new(doc)
  return setmetatable({
    doc = doc,
    native = largefile,
    handle = nil,
    chunk_line_count = math.max(1, config.large_file_window_chunk_lines or 256),
    backend_kind = largefile.backend_kind and largefile.backend_kind() or "unknown",
    visible_window = nil,
    visible_window_epoch = 0,
    pending_visible_window = nil,
  }, Backend)
end

function Backend:ensure_handle()
  if self.handle or not self.doc.abs_filename then
    return self.handle
  end
  self.handle = assert(self.native.create_backend(self.doc.abs_filename, self.chunk_line_count))
  largefile_trace("backend.create file=%s kind=%s", tostring(self.doc.abs_filename), tostring(self.backend_kind))
  return self.handle
end

function Backend:get_loading_state()
  local state = {
    visible_window = self.visible_window,
    visible_window_epoch = self.visible_window_epoch,
    backend_kind = self.backend_kind,
  }
  local handle = self:ensure_handle()
  if handle and handle.get_loading_state then
    local native_state = handle:get_loading_state()
    for k, v in pairs(native_state or {}) do
      state[k] = v
    end
    self.chunk_line_count = native_state and native_state.chunk_line_count or self.chunk_line_count
  end
  return state
end

function Backend:is_view_ready(start_line, end_line)
  if not self.visible_window then
    return false
  end
  return start_line >= self.visible_window.start_line
    and end_line <= self.visible_window.end_line
end

function Backend:request_visible_window(start_line, end_line, margin)
  margin = margin or 0
  local handle = self:ensure_handle()
  local chunk_line_count = self.chunk_line_count or 256
  local aligned_start = math.floor((math.max(1, start_line - margin) - 1) / chunk_line_count) * chunk_line_count + 1
  local aligned_end = math.ceil((math.max(start_line, end_line) + margin) / chunk_line_count) * chunk_line_count
  self.pending_visible_window = {
    start_line = aligned_start,
    end_line = math.min(self.doc:line_count(), aligned_end),
    requested_start_line = start_line,
    requested_end_line = end_line,
    margin = margin,
    epoch = self.visible_window_epoch + 1,
    backend_kind = self.backend_kind,
  }
  if handle and handle.request_window then
    handle:request_window(start_line, end_line, margin)
  end
end

function Backend:poll_ready_window(budget_hint)
  local handle = self:ensure_handle()
  if handle and handle.poll_window then
    local ready = handle:poll_window()
    if ready then
      self.chunk_line_count = ready.chunk_line_count or self.chunk_line_count
      self.visible_window_epoch = ready.epoch or (self.visible_window_epoch + 1)
      self.visible_window = ready
      self.pending_visible_window = nil
      return self.visible_window
    end
    return nil
  end
  if not self.pending_visible_window then
    return nil
  end
  self.visible_window_epoch = self.pending_visible_window.epoch
  self.visible_window = self.pending_visible_window
  self.pending_visible_window = nil
  return self.visible_window
end

function Backend:cancel_noncritical_work()
  local handle = self:ensure_handle()
  largefile_trace(
    "backend.cancel_noncritical.begin file=%s has_handle=%s pending=%s-%s",
    tostring(self.doc.abs_filename or self.doc.filename),
    tostring(handle ~= nil),
    tostring(self.pending_visible_window and self.pending_visible_window.start_line),
    tostring(self.pending_visible_window and self.pending_visible_window.end_line)
  )
  if handle and handle.cancel_noncritical_work then
    handle:cancel_noncritical_work()
  end
  self.pending_visible_window = nil
  largefile_trace("backend.cancel_noncritical.done file=%s", tostring(self.doc.abs_filename or self.doc.filename))
  return true
end

function Backend:read_range(start_line, start_col, end_line, end_col, inclusive)
  local handle = self:ensure_handle()
  if handle and handle.read_range then
    return handle:read_range(start_line, start_col, end_line, end_col, inclusive)
  end
  return nil
end

function Backend:begin_save(task)
  local handle = self:ensure_handle()
  if not handle or not handle.begin_save then
    return false, "native backend save api unavailable"
  end
  return handle:begin_save(
    task.snapshot_path,
    task.add_buffer_path,
    task.source_abs_filename,
    task.target_abs_filename
  )
end

function Backend:poll_save()
  local handle = self:ensure_handle()
  if handle and handle.poll_save then
    return handle:poll_save()
  end
  return nil
end

function Backend:cancel_save()
  local handle = self:ensure_handle()
  if handle and handle.cancel_save then
    handle:cancel_save()
  end
  return true
end

function Backend:shutdown()
  local handle = self.handle
  largefile_trace(
    "backend.shutdown.begin file=%s has_handle=%s visible=%s-%s pending=%s-%s",
    tostring(self.doc.abs_filename or self.doc.filename),
    tostring(handle ~= nil),
    tostring(self.visible_window and self.visible_window.start_line),
    tostring(self.visible_window and self.visible_window.end_line),
    tostring(self.pending_visible_window and self.pending_visible_window.start_line),
    tostring(self.pending_visible_window and self.pending_visible_window.end_line)
  )
  self.handle = nil
  self.pending_visible_window = nil
  self.visible_window = nil
  if handle and handle.close then
    largefile_trace("backend.shutdown.close.begin file=%s", tostring(self.doc.abs_filename or self.doc.filename))
    handle:close()
    largefile_trace("backend.shutdown.close.done file=%s", tostring(self.doc.abs_filename or self.doc.filename))
  end
  largefile_trace("backend.shutdown.done file=%s", tostring(self.doc.abs_filename or self.doc.filename))
  return true
end

return Backend
