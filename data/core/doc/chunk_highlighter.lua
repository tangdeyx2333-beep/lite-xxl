local Object = require "core.object"
local core = require "core"
local config = require "core.config"
local tokenizer = require "core.tokenizer"
local system = require "system"

local ChunkHighlighter = Object:extend()

local DEFAULT_STATE = string.char(0)
local SCROLL_IDLE_DELAY = 0.18
local DEBUG_LOG_PATH = USERDIR and (USERDIR .. PATHSEP .. "wlpt-debug.log") or nil

local function chunk_highlight_trace(fmt, ...)
  if not DEBUG_LOG_PATH then
    return
  end
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then
    text = tostring(fmt)
  end
  local fp = io.open(DEBUG_LOG_PATH, "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " [DEBUG-wlpt-highlight] ", text, "\n")
    fp:close()
  end
end

local function summarize_state(state)
  if type(state) ~= "string" then
    return tostring(state)
  end
  local bytes = {}
  for i = 1, math.min(#state, 8) do
    bytes[#bytes + 1] = string.format("%02X", state:byte(i))
  end
  return string.format("len=%d hex=%s", #state, table.concat(bytes, ""))
end

local function clamp_line(doc, line)
  return math.max(1, math.min(line or 1, doc:line_count()))
end

local function chunk_key(chunk_start)
  return tostring(chunk_start)
end

local function copy_lines(lines)
  local result = {}
  for i = 1, #(lines or {}) do
    result[i] = lines[i]
  end
  return result
end

local function lines_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

function ChunkHighlighter:__tostring()
  return "ChunkHighlighter"
end

function ChunkHighlighter:new(doc)
  self.doc = doc
  self.pending_visible = nil
  self.scroll_idle_delay = math.max(0, config.large_file_highlight_scroll_idle_delay or SCROLL_IDLE_DELAY)
  self.last_scroll_x = nil
  self.last_scroll_y = nil
  self.last_scroll_change_time = 0
  self.is_scrolling_hot = false
  self.access_clock = 0
  self.running_key = nil
end

function ChunkHighlighter:is_chunk_mode()
  return true
end

function ChunkHighlighter:_next_access_tick()
  self.access_clock = (self.access_clock or 0) + 1
  return self.access_clock
end

function ChunkHighlighter:_touch_chunk(chunk)
  if not chunk then
    return
  end
  chunk.highlight_last_access = self:_next_access_tick()
end

function ChunkHighlighter:_get_chunk_for_line(line)
  if not self.doc.get_chunk_for_line then
    return nil
  end
  return self.doc:get_chunk_for_line(line)
end

function ChunkHighlighter:_iter_window_chunks()
  local window = self.pending_visible
  if not window then
    return function() return nil end
  end
  local chunk_size = math.max(1, self.doc.chunk_line_count or 1)
  local start_chunk = self.doc:get_chunk_start_for_line(window.start_line)
  local end_chunk = self.doc:get_chunk_start_for_line(window.end_line)
  local current = start_chunk - chunk_size
  return function()
    current = current + chunk_size
    if current > end_chunk then
      return nil
    end
    return current, self.doc.chunk_cache and self.doc.chunk_cache[chunk_key(current)] or nil
  end
end

function ChunkHighlighter:_build_plain_line(line)
  return {
    tokens = { "normal", self.doc:get_line(line) or "\n" },
    init_state = DEFAULT_STATE,
    state = DEFAULT_STATE,
  }
end

function ChunkHighlighter:get_line(line)
  if config.large_file_disable_highlight then
    return self:_build_plain_line(line)
  end
  local chunk = self:_get_chunk_for_line(line)
  if not chunk then
    return self:_build_plain_line(line)
  end
  self:_touch_chunk(chunk)
  local idx = line - chunk.start_line + 1
  local tokens = chunk.highlight_tokens and chunk.highlight_tokens[idx]
  if tokens then
    return {
      tokens = tokens,
      init_state = chunk.highlight_init_state,
      state = chunk.highlight_end_state,
    }
  end
  return self:_build_plain_line(line)
end

function ChunkHighlighter:each_token(line)
  return tokenizer.each_token(self:get_line(line).tokens)
end

function ChunkHighlighter:reset()
  self:reset_all_highlight_cache("reset")
end

function ChunkHighlighter:soft_reset()
  self:reset_all_highlight_cache("soft-reset")
end

function ChunkHighlighter:_clear_chunk_highlight(chunk)
  if not chunk then
    return
  end
  chunk.highlight_tokens = nil
  chunk.highlight_init_state = nil
  chunk.highlight_end_state = nil
  chunk.highlight_ready = false
  chunk.highlight_dirty = true
  chunk.highlight_anchored = false
  chunk.highlight_error = nil
end

function ChunkHighlighter:reset_all_highlight_cache(_reason)
  if self.running_key then
    core.cancel_thread(self.running_key, "chunk-highlight-reset")
    self.running_key = nil
  end
  for _, chunk in pairs(self.doc.chunk_cache or {}) do
    chunk.highlight_revision = (chunk.highlight_revision or 0) + 1
    self:_clear_chunk_highlight(chunk)
  end
end

function ChunkHighlighter:_mark_chunk_dirty(chunk, drop_ready)
  if not chunk then
    return
  end
  chunk.highlight_revision = (chunk.highlight_revision or 0) + 1
  chunk.highlight_dirty = true
  chunk.highlight_error = nil
  chunk.highlight_anchored = false
  if drop_ready then
    chunk.highlight_ready = false
  end
  chunk_highlight_trace(
    "chunk.invalidate file=%s chunk=%s-%s revision=%s drop_ready=%s ready=%s dirty=%s",
    tostring(self.doc.abs_filename or self.doc.filename),
    tostring(chunk.start_line),
    tostring(chunk.end_line),
    tostring(chunk.highlight_revision),
    tostring(drop_ready == true),
    tostring(chunk.highlight_ready),
    tostring(chunk.highlight_dirty)
  )
end

function ChunkHighlighter:on_chunk_text_updated(chunk, previous)
  if not chunk then
    return
  end
  local text_changed = not previous
    or previous.start_line ~= chunk.start_line
    or previous.end_line ~= chunk.end_line
    or not lines_equal(previous.lines, chunk.lines)
  if not previous then
    chunk.highlight_revision = chunk.highlight_revision or 0
    chunk.highlight_dirty = true
    chunk.highlight_ready = false
    chunk.highlight_anchored = false
    return
  end
  if text_changed then
    self:_mark_chunk_dirty(chunk, true)
  end
end

function ChunkHighlighter:invalidate_from_line(line)
  line = clamp_line(self.doc, line)
  local chunk = self:_get_chunk_for_line(line)
  if not chunk then
    return
  end
  self:_mark_chunk_dirty(chunk, true)
  core.redraw = true
end

function ChunkHighlighter:rebuild_local_chain(start_chunk, end_chunk, _reason)
  local chunk_size = math.max(1, self.doc.chunk_line_count or 1)
  for chunk_start = start_chunk, end_chunk, chunk_size do
    local chunk = self.doc.chunk_cache and self.doc.chunk_cache[chunk_key(chunk_start)] or nil
    if chunk then
      self:_mark_chunk_dirty(chunk, true)
    end
  end
end

function ChunkHighlighter:_update_scroll_state(scroll_x, scroll_y, now)
  local changed = self.last_scroll_x == nil
    or self.last_scroll_y == nil
    or math.abs((scroll_x or 0) - (self.last_scroll_x or 0)) > 0.5
    or math.abs((scroll_y or 0) - (self.last_scroll_y or 0)) > 0.5
  self.last_scroll_x = scroll_x or 0
  self.last_scroll_y = scroll_y or 0
  if changed then
    self.last_scroll_change_time = now
    self.is_scrolling_hot = true
    if self.running_key then
      core.cancel_thread(self.running_key, "chunk-highlight-scroll-hot")
      self.running_key = nil
    end
  elseif self.is_scrolling_hot and (now - (self.last_scroll_change_time or 0)) >= self.scroll_idle_delay then
    self.is_scrolling_hot = false
  end
end

function ChunkHighlighter:ensure_visible_chunks(start_line, end_line, margin, scroll_x, scroll_y)
  if config.large_file_disable_highlight then
    if self.running_key then
      core.cancel_thread(self.running_key, "chunk-highlight-disabled")
      self.running_key = nil
    end
    self.pending_visible = nil
    self.is_scrolling_hot = false
    return
  end
  local now = system.get_time()
  local buffered_start = clamp_line(self.doc, start_line - (margin or 0))
  local buffered_end = clamp_line(self.doc, end_line + (margin or 0))
  self.pending_visible = {
    start_line = buffered_start,
    end_line = buffered_end,
    margin = margin or 0,
  }
  self:_update_scroll_state(scroll_x, scroll_y, now)
  self:evict_far_chunks()
  self:_maybe_start_next_task()
end

function ChunkHighlighter:_pick_next_chunk()
  if not self.pending_visible then
    return nil
  end
  for _, chunk in self:_iter_window_chunks() do
    if chunk then
      self:_touch_chunk(chunk)
      if chunk.highlight_dirty or not chunk.highlight_ready then
        return chunk
      end
    end
  end
  return nil
end

function ChunkHighlighter:_resolve_init_state(chunk)
  local prev_start = chunk.start_line - math.max(1, self.doc.chunk_line_count or 1)
  if prev_start < 1 then
    chunk_highlight_trace(
      "chunk.init_state file=%s chunk=%s-%s anchored=false reason=head default_state=%s",
      tostring(self.doc.abs_filename or self.doc.filename),
      tostring(chunk.start_line),
      tostring(chunk.end_line),
      summarize_state(DEFAULT_STATE)
    )
    return DEFAULT_STATE, false
  end
  local prev_chunk = self.doc.chunk_cache and self.doc.chunk_cache[chunk_key(prev_start)] or nil
  if prev_chunk and prev_chunk.highlight_ready and prev_chunk.highlight_end_state then
    chunk_highlight_trace(
      "chunk.init_state file=%s chunk=%s-%s anchored=true prev=%s-%s prev_ready=%s prev_state=%s",
      tostring(self.doc.abs_filename or self.doc.filename),
      tostring(chunk.start_line),
      tostring(chunk.end_line),
      tostring(prev_chunk.start_line),
      tostring(prev_chunk.end_line),
      tostring(prev_chunk.highlight_ready),
      summarize_state(prev_chunk.highlight_end_state)
    )
    return prev_chunk.highlight_end_state, true
  end
  chunk_highlight_trace(
    "chunk.init_state file=%s chunk=%s-%s anchored=false reason=missing-prev prev=%s default_state=%s",
    tostring(self.doc.abs_filename or self.doc.filename),
    tostring(chunk.start_line),
    tostring(chunk.end_line),
    tostring(prev_chunk and (tostring(prev_chunk.start_line) .. "-" .. tostring(prev_chunk.end_line) .. "/ready=" .. tostring(prev_chunk.highlight_ready)) or "nil"),
    summarize_state(DEFAULT_STATE)
  )
  return DEFAULT_STATE, false
end

function ChunkHighlighter:_run_chunk_task(chunk)
  local init_state, anchored = self:_resolve_init_state(chunk)
  local lines = copy_lines(chunk.lines or {})
  local revision = chunk.highlight_revision or 0
  local result_tokens = {}
  local state = init_state
  local slice_start = system.get_time()
  chunk_highlight_trace(
    "chunk.start file=%s chunk=%s-%s revision=%s anchored=%s lines=%s init_state=%s scrolling_hot=%s",
    tostring(self.doc.abs_filename or self.doc.filename),
    tostring(chunk.start_line),
    tostring(chunk.end_line),
    tostring(revision),
    tostring(anchored),
    tostring(#lines),
    summarize_state(init_state),
    tostring(self.is_scrolling_hot)
  )
  for i = 1, #lines do
    local text = lines[i] or "\n"
    local tokens, next_state, resume = tokenizer.tokenize(self.doc.syntax, text, state)
    while resume do
      tokens, next_state, resume = tokenizer.tokenize(self.doc.syntax, text, state, resume)
    end
    result_tokens[i] = tokens
    state = next_state or DEFAULT_STATE
    if system.get_time() - slice_start > (0.5 / math.max(1, config.fps or 60)) then
      slice_start = system.get_time()
      coroutine.yield(0)
    end
  end
  self:commit_chunk_result({
    chunk_start = chunk.start_line,
    revision = revision,
    tokens = result_tokens,
    init_state = init_state,
    end_state = state,
    anchored = anchored,
  })
end

function ChunkHighlighter:_maybe_start_next_task()
  if self.running_key or self.is_scrolling_hot or not self.pending_visible then
    return
  end
  local chunk = self:_pick_next_chunk()
  if not chunk then
    return
  end
  local thread_key = {}
  self.running_key = thread_key
  core.add_thread(function()
    self:_run_chunk_task(chunk)
    if self.running_key == thread_key then
      self.running_key = nil
    end
    self:_maybe_start_next_task()
  end, thread_key, core.thread_options {
    label = "chunk-highlighter",
    kind = "highlight",
    priority = "U2",
    owner_doc = self.doc,
  })
end

function ChunkHighlighter:commit_chunk_result(result)
  local chunk = self.doc.chunk_cache and self.doc.chunk_cache[chunk_key(result.chunk_start)] or nil
  if not chunk then
    chunk_highlight_trace(
      "chunk.commit.drop file=%s chunk=%s reason=missing-chunk revision=%s",
      tostring(self.doc.abs_filename or self.doc.filename),
      tostring(result.chunk_start),
      tostring(result.revision)
    )
    return false
  end
  if (chunk.highlight_revision or 0) ~= result.revision then
    chunk_highlight_trace(
      "chunk.commit.drop file=%s chunk=%s-%s reason=stale current_revision=%s result_revision=%s",
      tostring(self.doc.abs_filename or self.doc.filename),
      tostring(chunk.start_line),
      tostring(chunk.end_line),
      tostring(chunk.highlight_revision or 0),
      tostring(result.revision)
    )
    return false
  end
  local old_end_state = chunk.highlight_end_state
  chunk.highlight_tokens = result.tokens
  chunk.highlight_init_state = result.init_state
  chunk.highlight_end_state = result.end_state
  chunk.highlight_ready = true
  chunk.highlight_dirty = false
  chunk.highlight_anchored = result.anchored == true
  chunk.highlight_error = nil
  self:_touch_chunk(chunk)
  chunk_highlight_trace(
    "chunk.commit file=%s chunk=%s-%s revision=%s anchored=%s old_end=%s new_end=%s token_lines=%s",
    tostring(self.doc.abs_filename or self.doc.filename),
    tostring(chunk.start_line),
    tostring(chunk.end_line),
    tostring(result.revision),
    tostring(result.anchored == true),
    summarize_state(old_end_state),
    summarize_state(result.end_state),
    tostring(#(result.tokens or {}))
  )
  if old_end_state ~= nil and old_end_state ~= result.end_state then
    local next_chunk = self.doc.chunk_cache and self.doc.chunk_cache[chunk_key(chunk.end_line + 1)] or nil
    if next_chunk then
      chunk_highlight_trace(
        "chunk.propagate file=%s from=%s-%s to=%s-%s reason=end-state-changed",
        tostring(self.doc.abs_filename or self.doc.filename),
        tostring(chunk.start_line),
        tostring(chunk.end_line),
        tostring(next_chunk.start_line),
        tostring(next_chunk.end_line)
      )
      self:_mark_chunk_dirty(next_chunk, true)
    end
  end
  core.redraw = true
  return true
end

function ChunkHighlighter:evict_far_chunks()
  if not self.pending_visible then
    return
  end
  local chunk_size = math.max(1, self.doc.chunk_line_count or 1)
  local window_start = self.doc:get_chunk_start_for_line(self.pending_visible.start_line)
  local window_end = self.doc:get_chunk_start_for_line(self.pending_visible.end_line)
  local keep_before = window_start - (chunk_size * 2)
  local keep_after = window_end + (chunk_size * 2)
  for _, chunk in pairs(self.doc.chunk_cache or {}) do
    if chunk.start_line < keep_before or chunk.start_line > keep_after then
      local had_tokens = chunk.highlight_tokens ~= nil
      chunk.highlight_tokens = nil
      chunk.highlight_ready = false
      chunk.highlight_dirty = true
      chunk.highlight_anchored = false
      if had_tokens then
        chunk_highlight_trace(
          "chunk.evict file=%s chunk=%s-%s keep=%s-%s",
          tostring(self.doc.abs_filename or self.doc.filename),
          tostring(chunk.start_line),
          tostring(chunk.end_line),
          tostring(keep_before),
          tostring(keep_after)
        )
      end
    end
  end
end

return ChunkHighlighter
