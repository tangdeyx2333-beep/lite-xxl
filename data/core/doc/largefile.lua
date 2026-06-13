local Doc = require "core.doc"
local core = require "core"
local config = require "core.config"
local StubBackend = require "core.doc.largefile_backend"
local ChunkHighlighter = require "core.doc.chunk_highlighter"
local system = require "system"

local ok_native, NativeBackend = pcall(require, "core.doc.largefile_backend_native")
local LargeFileBackend = ok_native and NativeBackend.available() and NativeBackend or StubBackend

---@class core.largefiledoc : core.doc
local LargeFileDoc = Doc:extend()

function LargeFileDoc:__tostring() return "LargeFileDoc" end

local function largefile_trace(fmt, ...)
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then text = tostring(fmt) end
  local fp = io.open(USERDIR .. PATHSEP .. "largefile-debug.log", "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " ", text, "\n")
    fp:close()
  end
end

local function wlpt_window_trace(fmt, ...)
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then text = tostring(fmt) end
  local fp = io.open(USERDIR .. PATHSEP .. "wlpt-debug.log", "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " [DEBUG-wlpt-window] ", text, "\n")
    fp:close()
  end
end

local function summarize_line_preview(text)
  if type(text) ~= "string" then
    return tostring(text)
  end
  text = text:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
  if #text > 80 then
    text = text:sub(1, 80) .. "..."
  end
  return text
end

local function copy_array(values)
  local result = {}
  for i = 1, #(values or {}) do
    result[i] = values[i]
  end
  return result
end

local function get_backend_state(self)
  if not self.backend then
    return nil
  end
  return self.backend:get_loading_state()
end

function LargeFileDoc:new(filename, abs_filename, new_file, skip_load)
  self.chunk_line_count = math.max(1, config.large_file_window_chunk_lines or 256)
  self.chunk_buffer_count = math.max(0, config.large_file_window_buffer_chunks or 1)
  self.max_cached_chunks = math.max(2, config.large_file_window_max_cached_chunks or 8)
  self.chunk_cache = {}
  self.chunk_access_clock = 0
  self.last_requested_window = nil
  self._closed = false
  self._load_thread_key = {}
  self._edit_thread_key = {}
  LargeFileDoc.super.new(self, filename, abs_filename, new_file, true)
  self.is_large_file = true
  self.disable_undo = config.large_file_disable_undo
  self.chunk_highlighter = ChunkHighlighter(self)
  self.backend = LargeFileBackend.new(self)
  if filename and not new_file and not skip_load then
    self:start_loading(abs_filename or filename, system.get_file_info(abs_filename or filename))
  end
end

local function chunk_key(chunk_start)
  return tostring(chunk_start)
end

local function find_covering_chunk(self, line)
  for _, chunk in pairs(self.chunk_cache or {}) do
    if chunk and line >= (chunk.start_line or 1) and line <= (chunk.end_line or 0) then
      return chunk
    end
  end
  return nil
end

local function copy_chunk_highlight_fields(dst, src)
  if not dst or not src then
    return
  end
  dst.highlight_tokens = src.highlight_tokens
  dst.highlight_init_state = src.highlight_init_state
  dst.highlight_end_state = src.highlight_end_state
  dst.highlight_ready = src.highlight_ready
  dst.highlight_dirty = src.highlight_dirty
  dst.highlight_revision = src.highlight_revision
  dst.highlight_anchored = src.highlight_anchored
  dst.highlight_error = src.highlight_error
  dst.highlight_last_access = src.highlight_last_access
end

local function ranges_overlap(a_start, a_end, b_start, b_end)
  return not (a_end < b_start or b_end < a_start)
end

local function cached_chunk_count(self)
  local count = 0
  for _ in pairs(self.chunk_cache or {}) do
    count = count + 1
  end
  return count
end

local function snapshot_selections(self)
  local selections = {}
  for i = 1, #(self.selections or {}) do
    selections[i] = self.selections[i]
  end
  return selections, self.last_selection
end

local function restore_selections(self, selections, last_selection)
  if type(selections) ~= "table" or #selections == 0 then
    return
  end
  self.selections = selections
  self.last_selection = last_selection or 1
end

local function restore_docview_positions(self, label)
  local views = core.get_views_referencing_doc and core.get_views_referencing_doc(self) or {}
  local line1 = self.selections and self.selections[1] or 1
  for i, view in ipairs(views) do
    if view and view.scroll_to_line then
      view:scroll_to_line(line1, false, true)
      largefile_trace(
        "doc.%s.restore_view[%s] file=%s target_line=%s scroll=%s,%s",
        tostring(label),
        tostring(i),
        tostring(self.abs_filename or self.filename),
        tostring(line1),
        tostring(view.scroll and view.scroll.x),
        tostring(view.scroll and view.scroll.y)
      )
    end
  end
end

local function clear_largefile_runtime_state(self)
  self.backend = nil
  self.chunk_cache = nil
  self.chunk_highlighter = nil
  self.chunk_access_clock = nil
  self.last_requested_window = nil
  self._last_backend_request = nil
  self.chunk_line_count = nil
  self.chunk_buffer_count = nil
  self.max_cached_chunks = nil
  self.disable_symbols = nil
  self.disable_trim_whitespace = nil
  self.disable_detect_indent = nil
  self.disable_line_wrapping = nil
  self.disable_draw_whitespace = nil
  self.loading_cancelled = false
  self.is_large_file = false
  self.disable_undo = false
  self._edit_confirmation_open = nil
end

function LargeFileDoc:shutdown_largefile_runtime()
  largefile_trace(
    "doc.shutdown.begin file=%s closed=%s loading=%s load_thread=%s edit_thread=%s backend=%s cached_chunks=%d",
    tostring(self.abs_filename or self.filename),
    tostring(self._closed),
    tostring(self.loading),
    tostring(self._load_thread_key ~= nil),
    tostring(self._edit_thread_key ~= nil),
    tostring(self.backend and (self.backend.backend_kind or self.backend.__name or "table") or nil),
    cached_chunk_count(self)
  )
  self.loading_cancelled = true
  self.loading = false
  if self._load_thread_key then
    largefile_trace("doc.shutdown.cancel_load_thread file=%s", tostring(self.abs_filename or self.filename))
    core.cancel_thread(self._load_thread_key, "large-file-doc-closed")
  end
  if self._edit_thread_key then
    largefile_trace("doc.shutdown.cancel_edit_thread file=%s", tostring(self.abs_filename or self.filename))
    core.cancel_thread(self._edit_thread_key, "large-file-doc-closed")
  end
  if self.backend and self.backend.shutdown then
    largefile_trace("doc.shutdown.backend.begin file=%s", tostring(self.abs_filename or self.filename))
    self.backend:shutdown()
    largefile_trace("doc.shutdown.backend.done file=%s", tostring(self.abs_filename or self.filename))
  elseif self.backend and self.backend.cancel_noncritical_work then
    largefile_trace("doc.shutdown.cancel_noncritical.begin file=%s", tostring(self.abs_filename or self.filename))
    self.backend:cancel_noncritical_work()
    largefile_trace("doc.shutdown.cancel_noncritical.done file=%s", tostring(self.abs_filename or self.filename))
  end
  clear_largefile_runtime_state(self)
  largefile_trace("doc.shutdown.done file=%s", tostring(self.abs_filename or self.filename))
end

function LargeFileDoc:reopen_largefile_backend()
  local filename = self.filename
  local abs_filename = self.abs_filename
  local selections, last_selection = snapshot_selections(self)
  largefile_trace(
    "doc.reopen_backend.begin file=%s sel=%s,%s,%s,%s last=%s",
    tostring(abs_filename or filename),
    tostring(selections and selections[1]),
    tostring(selections and selections[2]),
    tostring(selections and selections[3]),
    tostring(selections and selections[4]),
    tostring(last_selection)
  )
  if self.backend and self.backend.shutdown then
    self.backend:shutdown()
  elseif self.backend and self.backend.cancel_noncritical_work then
    self.backend:cancel_noncritical_work()
  end
  self.chunk_line_count = math.max(1, config.large_file_window_chunk_lines or 256)
  self.chunk_buffer_count = math.max(0, config.large_file_window_buffer_chunks or 1)
  self.max_cached_chunks = math.max(2, config.large_file_window_max_cached_chunks or 8)
  self.chunk_cache = {}
  self.chunk_access_clock = 0
  self.last_requested_window = nil
  self._last_backend_request = nil
  self.loading_cancelled = false
  self.loading_error = nil
  self.loading = true
  self.loading_progress = 0
  self.loading_progress_lines = 0
  self.loading_progress_bytes = 0
  self._restore_view_after_load = true
  self.backend = LargeFileBackend.new(self)
  self._load_thread_key = {}
  restore_selections(self, selections, last_selection)
  local path = abs_filename or filename
  if path then
    self:start_loading(path, system.get_file_info(path))
  end
  largefile_trace(
    "doc.reopen_backend.end file=%s sel=%s,%s,%s,%s",
    tostring(abs_filename or filename),
    tostring(self.selections and self.selections[1]),
    tostring(self.selections and self.selections[2]),
    tostring(self.selections and self.selections[3]),
    tostring(self.selections and self.selections[4])
  )
end

function LargeFileDoc:get_chunk_start_for_line(line)
  local chunk = self.chunk_line_count or 1
  return math.floor((math.max(1, line) - 1) / chunk) * chunk + 1
end

function LargeFileDoc:get_chunk_end_for_start(chunk_start)
  return math.max(chunk_start, chunk_start + (self.chunk_line_count or 1) - 1)
end

function LargeFileDoc:get_chunk_for_line(line)
  local start_line = self:get_chunk_start_for_line(line)
  local aligned = self.chunk_cache[chunk_key(start_line)]
  if aligned then
    return aligned
  end
  local covering = find_covering_chunk(self, line)
  if covering then
    wlpt_window_trace(
      "cache.misaligned_lookup file=%s line=%s aligned=%s covering=%s-%s chunk_lines=%s",
      tostring(self.abs_filename or self.filename),
      tostring(line),
      tostring(start_line),
      tostring(covering.start_line),
      tostring(covering.end_line),
      tostring(self.chunk_line_count)
    )
  end
  return aligned
end

function LargeFileDoc:touch_chunk(chunk)
  if not chunk then return end
  self.chunk_access_clock = (self.chunk_access_clock or 0) + 1
  chunk.last_access = self.chunk_access_clock
end

function LargeFileDoc:trim_chunk_cache()
  local entries = {}
  for key, chunk in pairs(self.chunk_cache or {}) do
    entries[#entries + 1] = { key = key, chunk = chunk }
  end
  if #entries <= self.max_cached_chunks then
    return
  end
  table.sort(entries, function(a, b)
    return (a.chunk.last_access or 0) < (b.chunk.last_access or 0)
  end)
  for i = 1, #entries - self.max_cached_chunks do
    self.chunk_cache[entries[i].key] = nil
  end
end

function LargeFileDoc:purge_unaligned_chunks_in_range(start_line, end_line, keep_keys)
  for key, chunk in pairs(self.chunk_cache or {}) do
    if chunk
      and not (keep_keys and keep_keys[key])
      and chunk.start_line ~= self:get_chunk_start_for_line(chunk.start_line)
      and ranges_overlap(start_line, end_line, chunk.start_line, chunk.end_line)
    then
      wlpt_window_trace(
        "cache.purge_unaligned file=%s range=%s-%s drop=%s-%s",
        tostring(self.abs_filename or self.filename),
        tostring(start_line),
        tostring(end_line),
        tostring(chunk.start_line),
        tostring(chunk.end_line)
      )
      self.chunk_cache[key] = nil
    end
  end
end

function LargeFileDoc:store_snapshot_chunks(ready)
  local lines = ready.lines or {}
  local start_line = ready.start_line or 1
  local end_line = ready.end_line or start_line + #lines - 1
  local chunk_line_count = math.max(1, ready.chunk_line_count or self.chunk_line_count or 256)
  self.chunk_line_count = chunk_line_count
  local staged = {}
  local touched_keys = {}
  local line = start_line
  local cursor = 1
  while cursor <= #lines and line <= end_line do
    local aligned_start = self:get_chunk_start_for_line(line)
    local aligned_end = self:get_chunk_end_for_start(aligned_start)
    local cache_key = chunk_key(aligned_start)
    local staged_chunk = staged[cache_key]
    if not staged_chunk then
      local previous = self.chunk_cache[cache_key]
      staged_chunk = {
        start_line = aligned_start,
        end_line = aligned_end,
        lines = previous and copy_array(previous.lines) or {},
        epoch = ready.epoch,
        _previous = previous,
        _updated_start = nil,
        _updated_end = nil,
      }
      if previous then
        copy_chunk_highlight_fields(staged_chunk, previous)
      end
      staged[cache_key] = staged_chunk
      touched_keys[cache_key] = true
    end
    local idx = line - aligned_start + 1
    staged_chunk.lines[idx] = lines[cursor] or "\n"
    staged_chunk._updated_start = staged_chunk._updated_start and math.min(staged_chunk._updated_start, line) or line
    staged_chunk._updated_end = staged_chunk._updated_end and math.max(staged_chunk._updated_end, line) or line
    cursor = cursor + 1
    line = line + 1
  end

  self:purge_unaligned_chunks_in_range(start_line, end_line, touched_keys)

  local ordered_keys = {}
  for key in pairs(staged) do
    ordered_keys[#ordered_keys + 1] = key
  end
  table.sort(ordered_keys, function(a, b)
    return tonumber(a) < tonumber(b)
  end)

  for _, key in ipairs(ordered_keys) do
    local chunk = staged[key]
    local previous = chunk._previous
    chunk._previous = nil
    local updated_start = chunk._updated_start
    local updated_end = chunk._updated_end
    chunk._updated_start = nil
    chunk._updated_end = nil
    self.chunk_cache[key] = chunk
    if self.chunk_highlighter then
      self.chunk_highlighter:on_chunk_text_updated(chunk, previous)
    end
    wlpt_window_trace(
      "store.chunk file=%s request=%s-%s ready=%s-%s chunk=%s-%s updated=%s-%s prev=%s first=\"%s\" last=\"%s\"",
      tostring(self.abs_filename or self.filename),
      tostring(ready.requested_start_line),
      tostring(ready.requested_end_line),
      tostring(start_line),
      tostring(end_line),
      tostring(chunk.start_line),
      tostring(chunk.end_line),
      tostring(updated_start),
      tostring(updated_end),
      tostring(previous and (tostring(previous.start_line) .. "-" .. tostring(previous.end_line)) or "nil"),
      summarize_line_preview(chunk.lines[1]),
      summarize_line_preview(chunk.lines[#chunk.lines])
    )
    self:touch_chunk(chunk)
  end
  self:trim_chunk_cache()
end

function LargeFileDoc:reset_syntax()
  LargeFileDoc.super.reset_syntax(self)
  if self.chunk_highlighter then
    self.chunk_highlighter:reset_all_highlight_cache("syntax-reset")
  end
end

function LargeFileDoc:get_loading_state()
  local state = LargeFileDoc.super.get_loading_state(self)
  local backend_state = get_backend_state(self)
  if backend_state then
    for k, v in pairs(backend_state) do
      state[k] = v
    end
  end
  return state
end

function LargeFileDoc:is_view_ready(start_line, end_line)
  if self.loading_error then
    return false
  end
  for line = math.max(1, start_line), math.max(start_line, end_line) do
    if not self:has_cached_line(line) then
      return false
    end
  end
  return true
end

function LargeFileDoc:line_count()
  local state = get_backend_state(self) or {}
  return math.max(state.line_count or 1, 1)
end

function LargeFileDoc:get_line(line)
  local chunk = self:get_chunk_for_line(line)
  if not chunk then
    return "\n"
  end
  self:touch_chunk(chunk)
  local idx = line - chunk.start_line + 1
  return (chunk.lines and chunk.lines[idx]) or "\n"
end

function LargeFileDoc:has_cached_line(line)
  local chunk = self:get_chunk_for_line(line)
  if not chunk then
    return false
  end
  local idx = line - chunk.start_line + 1
  return idx >= 1 and idx <= #(chunk.lines or {}) and chunk.lines[idx] ~= nil
end

function LargeFileDoc:has_any_cached_lines(start_line, end_line)
  for line = math.max(1, start_line), math.max(start_line, end_line) do
    if self:has_cached_line(line) then
      return true
    end
  end
  return false
end

function LargeFileDoc:get_cached_window_range()
  local min_line, max_line
  for _, chunk in pairs(self.chunk_cache or {}) do
    min_line = min_line and math.min(min_line, chunk.start_line) or chunk.start_line
    max_line = max_line and math.max(max_line, chunk.end_line) or chunk.end_line
  end
  return min_line or 1, max_line or 1
end

function LargeFileDoc:get_line_length(line)
  return #self:get_line(line)
end

function LargeFileDoc:get_text(line1, col1, line2, col2, inclusive)
  line1, col1 = self:sanitize_position(line1, col1)
  line2, col2 = self:sanitize_position(line2, col2)
  if line1 > line2 or (line1 == line2 and col1 > col2) then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  if self.backend and self.backend.read_range then
    local text = self.backend:read_range(line1, col1, line2, col2, inclusive)
    if type(text) == "string" then
      return text
    end
  end
  return Doc.get_text(self, line1, col1, line2, col2, inclusive)
end

function LargeFileDoc:get_all_text()
  local last_line = self:line_count()
  if self.backend and self.backend.read_range and last_line > 0 then
    local text = self.backend:read_range(1, 1, last_line, math.maxinteger or 2147483647, true)
    if type(text) == "string" then
      return text
    end
  end
  return Doc.get_all_text(self)
end

function LargeFileDoc:request_visible_window(start_line, end_line, margin)
  if not self.backend then
    return
  end
  local chunk_margin = (self.chunk_line_count or 1) * (self.chunk_buffer_count or 0)
  margin = math.max(margin or 0, chunk_margin)
  self.last_requested_window = {
    start_line = start_line,
    end_line = end_line,
    margin = margin,
  }
  if self._last_backend_request
    and self._last_backend_request.start_line == start_line
    and self._last_backend_request.end_line == end_line
    and self._last_backend_request.margin == margin
  then
    return
  end
  self._last_backend_request = self.last_requested_window
  self.backend:request_visible_window(start_line, end_line, margin)
end

function LargeFileDoc:poll_ready_window(budget_hint)
  if self.loading_error then
    return nil
  end
  if not self.backend then
    return nil
  end
  local ready = self.backend:poll_ready_window(budget_hint)
  if ready and ready.lines then
    self:store_snapshot_chunks(ready)
    core.redraw = true
  end
  return ready
end

function LargeFileDoc:cancel_noncritical_work()
  if not self.backend then
    return false
  end
  self._last_backend_request = nil
  if self.chunk_highlighter and self.chunk_highlighter.running_key then
    core.cancel_thread(self.chunk_highlighter.running_key, "large-file-cancel-noncritical")
    self.chunk_highlighter.running_key = nil
  end
  return self.backend:cancel_noncritical_work()
end

function LargeFileDoc:supports_full_line_array()
  return false
end

function LargeFileDoc:is_large_file_mode()
  return true
end

function LargeFileDoc:start_loading(filename, file_info)
  self.new_file = false
  self.is_large_file = true
  self.loading = true
  self.disable_undo = config.large_file_disable_undo
  self.disable_symbols = true
  self.disable_trim_whitespace = true
  self.disable_detect_indent = true
  self.disable_line_wrapping = true
  self.disable_draw_whitespace = true
  self.loading_total_bytes = file_info and file_info.size or 0
  if self._load_thread_key and core.threads[self._load_thread_key] then
    return
  end
  core.add_thread(function()
    local ok, err = pcall(self.load, self, filename)
    if not ok and not self.loading_cancelled and not self._closed then
      self.loading = false
      self.loading_error = err or "Unable to load file"
      core.redraw = true
    end
  end, self._load_thread_key, core.thread_options {
    label = "large-file-load",
    kind = "doc-load",
    priority = "U2",
    owner_doc = self,
  })
end

function LargeFileDoc:begin_editable_materialization()
  if self._materialize_edit_thread then
    if not self._large_file_readonly_notified or (system.get_time() - self._large_file_readonly_notified) > 1.5 then
      self._large_file_readonly_notified = system.get_time()
      core.log("Preparing editable copy for large file: %s", tostring(self:get_name()))
    end
    return false
  end

  local filename = self.abs_filename
  if not filename then
    return false
  end

  self._materialize_edit_thread = true
  self.loading = true
  self.loading_error = nil
  self.loading_progress = 0
  self.loading_progress_lines = 0
  self.loading_progress_bytes = 0
  self.loading_total_bytes = self.loading_total_bytes or 0
  core.log("Switching large file to editable mode: %s", tostring(self:get_name()))
  if self._edit_thread_key and core.threads[self._edit_thread_key] then
    return false
  end
  core.add_thread(function()
    local ok, err = pcall(function()
      local selections, last_selection = snapshot_selections(self)
      if self.backend then
        self.backend:cancel_noncritical_work()
      end
      self.is_large_file = false
      self.disable_undo = false
      Doc.load(self, filename)
      clear_largefile_runtime_state(self)
      restore_selections(self, selections, last_selection)
      setmetatable(self, Doc)
      Doc.reset_syntax(self)
      self:clean()
      self._large_file_readonly_notified = nil
      self.loading = false
      self._materialize_edit_thread = nil
      core.log("Large file is now editable: %s", tostring(self:get_name()))
      core.redraw = true
    end)

    if not ok then
      self.loading = false
      self.loading_error = err or "Unable to prepare editable large file"
      self._materialize_edit_thread = nil
      core.error("Editable large-file preparation failed: %s", tostring(err))
      core.redraw = true
    end
  end, self._edit_thread_key, core.thread_options {
    label = "large-file-edit-materialize",
    kind = "doc-load",
    priority = "U2",
    owner_doc = self,
  })
  return false
end

function LargeFileDoc:request_editable_materialization_confirmation()
  if self._materialize_edit_thread then
    return false
  end

  if self._edit_confirmation_open then
    if not self._large_file_readonly_notified or (system.get_time() - self._large_file_readonly_notified) > 1.5 then
      self._large_file_readonly_notified = system.get_time()
      core.log("Large file edit confirmation already open: %s", tostring(self:get_name()))
    end
    return false
  end

  self._edit_confirmation_open = true
  local size_mb = (self.loading_total_bytes or 0) / (1024 * 1024)
  local confirm_label = string.format(
    "大文件编辑确认（文件较大，加载编辑资源会很慢，约 %.1f MB；输入 yes 确认继续）",
    size_mb
  )
  core.command_view:enter(confirm_label, {
    text = "",
    select_text = false,
    show_suggestions = false,
    submit = function(text)
      self._edit_confirmation_open = nil
      if text == "yes" then
        core.log("Large file edit confirmed, preparing editable copy: %s", tostring(self:get_name()))
        self:begin_editable_materialization()
      else
        core.log("Large file edit cancelled, expected 'yes': %s", tostring(self:get_name()))
        core.error("已取消大文件编辑加载。请输入 yes 才会开始加载编辑资源。")
      end
    end,
    cancel = function()
      self._edit_confirmation_open = nil
      core.log("Large file edit confirmation dismissed: %s", tostring(self:get_name()))
    end
  })
  core.status_view:show_message(
    "info",
    string.format(
      "正在尝试编辑大文件《%s》。由于文件较大，加载完整编辑资源会比较慢；请在下方输入 yes 确认继续。",
      tostring(self:get_name() or "")
    )
  )
  return false
end

local function ensure_large_file_editable(self)
  if not self:is_large_file_mode() then
    return true
  end
  return self:request_editable_materialization_confirmation()
end

function LargeFileDoc:insert(...)
  if ensure_large_file_editable(self) then
    return Doc.insert(self, ...)
  end
  return false
end

function LargeFileDoc:remove(...)
  if ensure_large_file_editable(self) then
    return Doc.remove(self, ...)
  end
  return false
end

function LargeFileDoc:undo(...)
  if ensure_large_file_editable(self) then
    return Doc.undo(self, ...)
  end
  return false
end

function LargeFileDoc:redo(...)
  if ensure_large_file_editable(self) then
    return Doc.redo(self, ...)
  end
  return false
end

function LargeFileDoc:text_input(...)
  if ensure_large_file_editable(self) then
    return Doc.text_input(self, ...)
  end
  return false
end

function LargeFileDoc:ime_text_editing(...)
  if ensure_large_file_editable(self) then
    return Doc.ime_text_editing(self, ...)
  end
  return false
end

function LargeFileDoc:load(filename, abs_filename)
  local ok, err = pcall(function()
    local handle = self.backend:ensure_handle()
    if self.loading_cancelled or self._closed or not self.backend or self.backend.handle ~= handle then
      self.loading = false
      return
    end
    local state = handle and handle:get_loading_state() or {}
    largefile_trace(
      "doc.load_begin file=%s loading=%s progress_lines=%s progress_bytes=%s total=%s",
      tostring(filename),
      tostring(state.loading),
      tostring(state.progress_lines),
      tostring(state.progress_bytes),
      tostring(state.total_bytes)
    )
    self.loading = state.loading ~= false
    self.loading_error = state.error
    self.loading_progress = state.progress_lines or 0
    self.loading_progress_lines = state.progress_lines or 0
    self.loading_progress_bytes = state.progress_bytes or 0
    self.loading_total_bytes = state.total_bytes or self.loading_total_bytes or 0

    while self.loading and not self.loading_error do
      if self.loading_cancelled or self._closed or not self.backend or self.backend.handle ~= handle then
        self.loading = false
        return
      end
      state = handle:get_loading_state()
      self.loading = state.loading ~= false
      self.loading_error = state.error
      self.loading_progress = state.progress_lines or self.loading_progress
      self.loading_progress_lines = state.progress_lines or self.loading_progress_lines
      self.loading_progress_bytes = state.progress_bytes or self.loading_progress_bytes
      self.loading_total_bytes = state.total_bytes or self.loading_total_bytes
      self:poll_ready_window(0)
      core.redraw = true
      if self.loading then
        coroutine.yield(config.file_size_poll_interval)
      end
    end

    if self.loading_cancelled or self._closed or not self.backend or self.backend.handle ~= handle then
      self.loading = false
      return
    end

    self.loading = false
    self.loading_progress = self.backend:get_loading_state().line_count or self.loading_progress
    self.loading_progress_lines = self.loading_progress
    self.loading_progress_bytes = self.loading_total_bytes
    self.loading_cancelled = false
    self:reset_syntax()
    self:request_visible_window(1, 1, 32)
    self:poll_ready_window(0)
    if self._restore_view_after_load then
      restore_docview_positions(self, "load_done")
      self._restore_view_after_load = nil
    end
    largefile_trace(
      "doc.load_done file=%s final_lines=%s cached_chunks=%d first_chunk=%d-%d sel=%s,%s,%s,%s",
      tostring(filename),
      tostring(self.loading_progress_lines),
      cached_chunk_count(self),
      self:get_cached_window_range(),
      tostring(self.selections and self.selections[1]),
      tostring(self.selections and self.selections[2]),
      tostring(self.selections and self.selections[3]),
      tostring(self.selections and self.selections[4])
    )
    core.redraw = true
  end)

  if not ok then
    if not self.loading_cancelled and not self._closed then
      self.loading = false
      self.loading_error = err
      largefile_trace("doc.load_error file=%s err=%s", tostring(filename), tostring(err))
      core.redraw = true
    end
  end
end

function LargeFileDoc:on_close()
  largefile_trace(
    "doc.on_close.begin file=%s loading=%s materializing=%s confirmation_open=%s",
    tostring(self.abs_filename or self.filename),
    tostring(self.loading),
    tostring(self._materialize_edit_thread),
    tostring(self._edit_confirmation_open)
  )
  self._closed = true
  self:shutdown_largefile_runtime()
  LargeFileDoc.super.on_close(self)
  largefile_trace("doc.on_close.done file=%s", tostring(self.abs_filename or self.filename))
end

return LargeFileDoc
