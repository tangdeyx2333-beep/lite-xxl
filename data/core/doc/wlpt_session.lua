local Object = require "core.object"
local core = require "core"
local common = require "core.common"
local system = require "system"
local tokenizer = require "core.tokenizer"

---@class core.wlptsession : core.object
local WlPtSession = Object:extend()

local next_session_id = 0
local MAX_READ_COL = math.maxinteger or 2147483647
local DEBUG_TAG = "[DEBUG-wlpt-drift]"
local MAX_UNDO_TEXT_BYTES = 1024 * 1024
local RECOVERY_DIR = USERDIR .. PATHSEP .. "storage" .. PATHSEP .. "wlpt"

local function wlpt_trace(fmt, ...)
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then text = tostring(fmt) end
  local fp = io.open(USERDIR .. PATHSEP .. "wlpt-debug.log", "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " ", text, "\n")
    fp:close()
  end
end

local function summarize_window_preview(text)
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

local function make_session_id(path)
  path = type(path) == "string" and (common.normalize_volume(path) or path) or "<unsaved>"
  local checksum = 0
  for i = 1, #path do
    checksum = (checksum + path:byte(i) * i) % 2147483647
  end
  local slug = path:gsub("[^%w%-_]", "_")
  if #slug > 96 then
    slug = slug:sub(-96)
  end
  return string.format("%s_%08x_%d", slug, checksum, #path)
end

local function ensure_recovery_dir()
  if system.get_file_info(RECOVERY_DIR) then
    return true
  end
  return common.mkdirp(RECOVERY_DIR)
end

local function read_recovery_chunk(path)
  local fp = io.open(path, "rb")
  if not fp then
    return nil
  end
  local content = fp:read("*a")
  fp:close()
  return content
end

local function write_recovery_chunk(path, content)
  local ok, _, err_path = ensure_recovery_dir()
  if ok == false then
    return false, "unable to create wlpt recovery dir: " .. tostring(err_path)
  end
  local fp, err = io.open(path, "wb")
  if not fp then
    return false, err or "unable to open recovery file"
  end
  fp:write(content or "")
  fp:close()
  return true
end

local function hex_encode(text)
  return (text or ""):gsub(".", function(ch)
    return string.format("%02X", string.byte(ch))
  end)
end

local function hex_decode(text)
  if type(text) ~= "string" or text == "" then
    return ""
  end
  return (text:gsub("(%x%x)", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function encode_meta_line(key, value)
  return string.format("%s|%s\n", tostring(key), hex_encode(tostring(value or "")))
end

local function parse_meta_content(content)
  local result = {}
  for line in tostring(content or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^([^|]+)|(.+)$")
    if key and value then
      result[key] = hex_decode(value)
    end
  end
  return result
end

local function parse_snapshot_content(content)
  local result = { pieces = {} }
  for line in tostring(content or ""):gmatch("[^\r\n]+") do
    local prefix, rest = line:match("^([^|]+)|?(.*)$")
    if prefix == "CRLF" then
      result.crlf = rest == "1"
    elseif prefix == "PIECE" then
      local kind, source_id, source_start_line, line_count = rest:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
      result.pieces[#result.pieces + 1] = {
        kind = kind,
        source_id = tonumber(source_id) or source_id,
        source_start_line = tonumber(source_start_line) or 1,
        line_count = tonumber(line_count) or 0,
      }
    end
  end
  return result
end

local function parse_add_content(content)
  local add_blocks = {}
  local current_block_id = nil
  for line in tostring(content or ""):gmatch("[^\r\n]+") do
    local prefix, rest = line:match("^([^|]+)|?(.*)$")
    if prefix == "BLOCK" then
      local block_id = rest:match("^([^|]+)")
      current_block_id = tonumber(block_id) or block_id
      add_blocks[current_block_id] = { lines = {} }
    elseif prefix == "LINE" and current_block_id ~= nil then
      add_blocks[current_block_id].lines[#add_blocks[current_block_id].lines + 1] = hex_decode(rest)
    end
  end
  return add_blocks
end

local function initial_highlight_state()
  return string.char(0)
end

local function build_highlight_chunk_key(start_line)
  return tostring(start_line)
end

function WlPtSession:__tostring()
  return "WlPtSession"
end

function WlPtSession:new(doc)
  next_session_id = next_session_id + 1
  self.id = next_session_id
  self.doc = doc
  self.file = doc and (doc.abs_filename or doc.filename) or nil
  self.mode = "wlpt"
  self.edit_state = nil
  self.edit_epoch = 0
  self.dirty = false
  self.last_requested_window = nil
  self.request_generation = 0
  self.last_ready_window = nil
  self.last_emitted_request_generation = 0
  self.last_emitted_edit_epoch = -1
  self.origin_line_cache = {}
  self.origin_line_cache_count = 0
  self.highlight_cache = {
    syntax = nil,
    chunks = {},
    access_clock = 0,
  }
  self.save_in_progress = false
  self.save_state = nil
  self.pending_save_target = nil
  self.pending_recovery_conflict = nil
  self.session_id = make_session_id(self.file or doc and doc.filename)
  wlpt_trace(
    "session.create id=%s file=%s mode=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self.mode)
  )
  self:try_restore_recovery_state()
end

function WlPtSession:get_highlight_syntax()
  if self.doc and self.doc.get_highlight_syntax then
    return self.doc:get_highlight_syntax()
  end
  return self.doc and self.doc.syntax or nil
end

function WlPtSession:touch_highlight_chunk(chunk)
  local cache = self.highlight_cache
  cache.access_clock = (cache.access_clock or 0) + 1
  chunk.last_access = cache.access_clock
end

function WlPtSession:trim_highlight_cache()
  local cache = self.highlight_cache
  local max_cached = math.max(2, self.doc and self.doc.max_cached_chunks or 8)
  local entries = {}
  for key, chunk in pairs(cache.chunks or {}) do
    entries[#entries + 1] = { key = key, chunk = chunk }
  end
  if #entries <= max_cached then
    return
  end
  table.sort(entries, function(a, b)
    return (a.chunk.last_access or 0) < (b.chunk.last_access or 0)
  end)
  for i = 1, #entries - max_cached do
    cache.chunks[entries[i].key] = nil
  end
end

function WlPtSession:reset_highlight_cache()
  if not self.highlight_cache then
    self.highlight_cache = { syntax = nil, chunks = {}, access_clock = 0 }
    return
  end
  self.highlight_cache.syntax = nil
  self.highlight_cache.chunks = {}
  self.highlight_cache.access_clock = 0
end

function WlPtSession:ensure_highlight_cache()
  if not self.highlight_cache then
    self.highlight_cache = { syntax = nil, chunks = {}, access_clock = 0 }
  end
  local syntax = self:get_highlight_syntax()
  if self.highlight_cache.syntax ~= syntax then
    self:reset_highlight_cache()
    self.highlight_cache.syntax = syntax
  end
  return self.highlight_cache
end

function WlPtSession:get_highlight_source_chunk(line)
  if self.doc and self.doc.get_chunk_for_line then
    local chunk = self.doc:get_chunk_for_line(line)
    if chunk then
      return {
        start_line = chunk.start_line,
        end_line = chunk.end_line,
        epoch = chunk.epoch,
      }
    end
  end
  local chunk_line_count = math.max(1, self.doc and self.doc.chunk_line_count or 256)
  local start_line = math.floor((math.max(1, line) - 1) / chunk_line_count) * chunk_line_count + 1
  return {
    start_line = start_line,
    end_line = math.min(self:line_count(), start_line + chunk_line_count - 1),
    epoch = nil,
  }
end

function WlPtSession:invalidate_highlight_all()
  self:reset_highlight_cache()
end

function WlPtSession:invalidate_highlight_from(line)
  local cache = self.highlight_cache
  if not cache or not cache.chunks then
    return
  end
  for key, chunk in pairs(cache.chunks) do
    if line <= (chunk.start_line or 1) then
      cache.chunks[key] = nil
    elseif line <= (chunk.end_line or 0) then
      chunk.previous_ready_end_state = chunk.ready
        and chunk.lines
        and chunk.lines[chunk.end_line]
        and chunk.lines[chunk.end_line].state
        or nil
      chunk.ready = false
      chunk.ready_init_state = nil
      chunk.lines = {}
      chunk.pending_lines = nil
      chunk.pending_next_line = nil
      chunk.pending_prev_state = nil
    else
      chunk.init_state_source = nil
    end
  end
end

function WlPtSession:resolve_highlight_chunk_init_state(chunk)
  if not chunk or chunk.start_line <= 1 then
    return initial_highlight_state(), "root", true
  end

  local prev_source_chunk = self:get_highlight_source_chunk(chunk.start_line - 1)
  if not prev_source_chunk then
    return initial_highlight_state(), "fallback", false
  end

  local cache = self:ensure_highlight_cache()
  local prev_chunk = cache.chunks[build_highlight_chunk_key(prev_source_chunk.start_line)]
  if prev_chunk and prev_chunk.ready then
    local prev_line = prev_chunk.lines and prev_chunk.lines[prev_source_chunk.end_line]
    if prev_line and prev_line.state then
      return prev_line.state, "prev", true
    end
  end

  return initial_highlight_state(), "fallback", false
end

function WlPtSession:ensure_highlight_chunk(line)
  if not self:has_cached_line(line) then
    return nil
  end

  local cache = self:ensure_highlight_cache()
  local source_chunk = self:get_highlight_source_chunk(line)
  local key = build_highlight_chunk_key(source_chunk.start_line)
  local chunk = cache.chunks[key]

  if not chunk
    or chunk.start_line ~= source_chunk.start_line
    or chunk.end_line ~= source_chunk.end_line
  then
    chunk = {
      key = key,
      start_line = source_chunk.start_line,
      end_line = source_chunk.end_line,
      epoch = source_chunk.epoch,
      init_state = nil,
      init_state_source = nil,
      ready = false,
      ready_init_state = nil,
      lines = {},
      pending_lines = nil,
      pending_next_line = nil,
      pending_prev_state = nil,
    }
    cache.chunks[key] = chunk
  else
    chunk.epoch = source_chunk.epoch
  end

  local init_state, init_state_source, init_state_ready = self:resolve_highlight_chunk_init_state(chunk)
  if chunk.init_state ~= init_state or chunk.init_state_source ~= init_state_source then
    chunk.init_state = init_state
    chunk.init_state_source = init_state_source
    if init_state_ready and chunk.ready_init_state ~= init_state then
      chunk.ready = false
      chunk.ready_init_state = nil
      chunk.lines = {}
      chunk.pending_lines = nil
      chunk.pending_next_line = nil
      chunk.pending_prev_state = nil
    end
  end

  self:touch_highlight_chunk(chunk)
  self:trim_highlight_cache()
  return chunk
end

function WlPtSession:tokenize_highlight_line(line, init_state)
  local syntax = self:get_highlight_syntax()
  local text = self:get_line(line)
  if not syntax then
    return {
      text = text,
      init_state = init_state,
      tokens = { "normal", text },
      state = initial_highlight_state(),
      resume = nil,
    }
  end

  local tokens, end_state, resume = tokenizer.tokenize(syntax, text, init_state)
  while resume do
    tokens, end_state, resume = tokenizer.tokenize(syntax, text, init_state, resume)
  end

  return {
    text = text,
    init_state = init_state,
    tokens = tokens,
    state = end_state,
    resume = nil,
  }
end

function WlPtSession:get_cached_highlight_tokens(line)
  if not self:has_cached_line(line) then
    return nil
  end

  local cache = self:ensure_highlight_cache()
  local source_chunk = self:get_highlight_source_chunk(line)
  local chunk = cache.chunks[build_highlight_chunk_key(source_chunk.start_line)]
  if not chunk then
    return nil
  end

  if not chunk.ready then
    return nil
  end

  local entry = chunk.lines[line]
  if not entry then
    return nil
  end

  local current_text = self:get_line(line)
  local expected_init_state
  if line == chunk.start_line then
    expected_init_state = chunk.ready_init_state or chunk.init_state or initial_highlight_state()
  else
    local prev = chunk.lines[line - 1]
    if not prev then
      return nil
    end
    expected_init_state = prev.state
  end

  if entry.text ~= current_text or entry.init_state ~= expected_init_state then
    chunk.ready = false
    chunk.lines = {}
    chunk.pending_lines = nil
    chunk.pending_next_line = nil
    chunk.pending_prev_state = nil
    return nil
  end

  self:touch_highlight_chunk(chunk)
  return entry.tokens
end

function WlPtSession:get_highlight_tokens(line)
  return self:get_cached_highlight_tokens(line)
end

function WlPtSession:invalidate_highlight_after_chunk(chunk)
  if not chunk or not self.highlight_cache or not self.highlight_cache.chunks then
    return
  end
  for _, other in pairs(self.highlight_cache.chunks) do
    if (other.start_line or 0) > (chunk.start_line or 0) then
      other.ready = false
      other.ready_init_state = nil
      other.lines = {}
      other.pending_lines = nil
      other.pending_next_line = nil
      other.pending_prev_state = nil
    end
  end
end

function WlPtSession:begin_highlight_chunk_build(chunk)
  chunk.pending_lines = {}
  chunk.pending_next_line = chunk.start_line
  chunk.pending_prev_state = chunk.init_state or initial_highlight_state()
end

function WlPtSession:step_highlight_chunk_build(chunk, deadline)
  if not chunk then
    return false
  end
  if chunk.ready then
    return false
  end
  if not chunk.pending_lines then
    self:begin_highlight_chunk_build(chunk)
  end

  while chunk.pending_next_line and chunk.pending_next_line <= chunk.end_line do
    if system.get_time() > deadline then
      return false
    end
    local line = chunk.pending_next_line
    local entry = self:tokenize_highlight_line(line, chunk.pending_prev_state or initial_highlight_state())
    chunk.pending_lines[line] = entry
    chunk.pending_prev_state = entry.state
    chunk.pending_next_line = line + 1
  end

  local old_end_state = chunk.previous_ready_end_state
  chunk.lines = chunk.pending_lines or {}
  chunk.ready = true
  chunk.ready_init_state = chunk.init_state or initial_highlight_state()
  chunk.pending_lines = nil
  chunk.pending_next_line = nil
  chunk.pending_prev_state = nil
  chunk.previous_ready_end_state = nil
  local new_end_state = chunk.lines
    and chunk.lines[chunk.end_line]
    and chunk.lines[chunk.end_line].state
    or nil
  if old_end_state ~= nil and new_end_state ~= old_end_state then
    self:invalidate_highlight_after_chunk(chunk)
  end
  return true
end

function WlPtSession:prepare_highlight_window(start_line, end_line, time_budget)
  if not start_line or not end_line or end_line < start_line then
    return false
  end

  local cached_start, cached_end = self.doc:get_cached_window_range()
  if cached_start and cached_end then
    start_line = math.max(1, cached_start)
    end_line = math.max(start_line, cached_end)
  end

  local deadline = system.get_time() + math.max(0, time_budget or 0)
  local chunk_line_count = math.max(1, self.doc and self.doc.chunk_line_count or 256)
  local chunk_start = math.floor((math.max(1, start_line) - 1) / chunk_line_count) * chunk_line_count + 1
  local last_chunk_start = math.floor((math.max(chunk_start, end_line) - 1) / chunk_line_count) * chunk_line_count + 1

  while chunk_start <= last_chunk_start do
    if system.get_time() > deadline then
      return false
    end
    if self:has_cached_line(chunk_start) then
      local chunk = self:ensure_highlight_chunk(chunk_start)
      if chunk and not chunk.ready then
        return self:step_highlight_chunk_build(chunk, deadline)
      end
    end
    chunk_start = chunk_start + chunk_line_count
  end
  return false
end

function WlPtSession:get_mode_label()
  if self.save_in_progress then
    local state = self.save_state or {}
    local written = tonumber(state.progress_bytes or 0) or 0
    if written > 0 then
      return string.format("WL-PT SAVING %d MB", math.floor(written / (1024 * 1024)))
    end
    return "WL-PT SAVING"
  end
  return "WL-PT"
end

local function sort_positions(line1, col1, line2, col2)
  if line1 > line2 or (line1 == line2 and col1 > col2) then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end

local function split_doc_lines(text)
  local lines = {}
  local start_idx = 1
  while start_idx <= #text do
    local nl = text:find("\n", start_idx, true)
    if nl then
      lines[#lines + 1] = text:sub(start_idx, nl)
      start_idx = nl + 1
    else
      lines[#lines + 1] = text:sub(start_idx) .. "\n"
      break
    end
  end
  if #lines == 0 then
    lines[1] = "\n"
  end
  return lines
end

local function piece_total_lines(pieces)
  local total = 0
  for _, piece in ipairs(pieces or {}) do
    total = total + (piece.line_count or 0)
  end
  return math.max(total, 1)
end

local function sanitize_preview_text(text)
  if type(text) ~= "string" then
    return tostring(text)
  end
  text = text:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
  if #text > 72 then
    text = text:sub(1, 72) .. "..."
  end
  return text
end

local function copy_piece(piece, offset, line_count)
  return {
    kind = piece.kind,
    source_id = piece.source_id,
    source_start_line = (piece.source_start_line or 1) + offset,
    line_count = line_count,
  }
end

local function clone_pieces(pieces)
  local result = {}
  for i = 1, #(pieces or {}) do
    result[i] = copy_piece(pieces[i], 0, pieces[i].line_count)
  end
  return result
end

local function clone_add_blocks(add_blocks)
  local result = {}
  for id, block in pairs(add_blocks or {}) do
    result[id] = { lines = copy_array(block.lines or {}) }
  end
  return result
end

function WlPtSession:has_edits()
  return self.edit_state ~= nil
end

function WlPtSession:is_dirty()
  return self.dirty == true
end

function WlPtSession:clear_dirty()
  self.dirty = false
end

function WlPtSession:ensure_edit_state()
  if self.edit_state then
    return self.edit_state
  end
  local total_lines = math.max(self.doc:raw_line_count(), 1)
  self.edit_state = {
    pieces = {
      {
        kind = "origin",
        source_start_line = 1,
        line_count = total_lines,
      }
    },
    add_blocks = {},
    next_add_id = 1,
    undo_stack = { idx = 1 },
    redo_stack = { idx = 1 },
  }
  wlpt_trace(
    "session.edit_state.begin id=%s file=%s total_lines=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(total_lines)
  )
  return self.edit_state
end

function WlPtSession:create_state_snapshot()
  local state = self:ensure_edit_state()
  return {
    pieces = clone_pieces(state.pieces),
    add_blocks = clone_add_blocks(state.add_blocks),
    next_add_id = state.next_add_id,
    dirty = self.dirty,
  }
end

function WlPtSession:get_recovery_meta_path()
  return RECOVERY_DIR .. PATHSEP .. self.session_id .. ".meta"
end

function WlPtSession:get_recovery_snapshot_path()
  return RECOVERY_DIR .. PATHSEP .. self.session_id .. ".snapshot"
end

function WlPtSession:get_recovery_add_path()
  return RECOVERY_DIR .. PATHSEP .. self.session_id .. ".add"
end

function WlPtSession:serialize_recovery_state()
  if not self.edit_state or not self.dirty then
    return nil
  end
  local snapshot = self:create_state_snapshot()
  local info = self.doc and self.doc.abs_filename and system.get_file_info(self.doc.abs_filename) or nil
  return {
    meta = {
      source_abs_filename = self.doc and self.doc.abs_filename or self.file or "",
      source_filename = self.doc and self.doc.filename or "",
      source_mtime = info and info.modified or "",
      source_size = info and info.size or "",
      created_at = os.time(),
      selection = copy_array(self.doc and self.doc.selections or nil),
      last_selection = self.doc and self.doc.last_selection or 1,
    },
    snapshot = snapshot,
  }
end

function WlPtSession:persist_recovery_state()
  local payload = self:serialize_recovery_state()
  if not payload then
    self:clear_recovery_state()
    return false
  end
  local meta_lines = {
    encode_meta_line("SOURCE_ABS_FILENAME", payload.meta.source_abs_filename),
    encode_meta_line("SOURCE_FILENAME", payload.meta.source_filename),
    encode_meta_line("SOURCE_MTIME", payload.meta.source_mtime),
    encode_meta_line("SOURCE_SIZE", payload.meta.source_size),
    encode_meta_line("CREATED_AT", payload.meta.created_at),
    encode_meta_line("LAST_SELECTION", payload.meta.last_selection),
  }
  for i = 1, #(payload.meta.selection or {}) do
    meta_lines[#meta_lines + 1] = encode_meta_line("SELECTION_" .. i, payload.meta.selection[i])
  end

  local snapshot_lines = {
    "WLPTSNAP1\n",
    string.format("CRLF|%s\n", self.doc and self.doc.crlf and "1" or "0"),
  }
  for _, piece in ipairs(payload.snapshot.pieces or {}) do
    snapshot_lines[#snapshot_lines + 1] = string.format(
      "PIECE|%s|%s|%s|%s\n",
      tostring(piece.kind or ""),
      tostring(piece.source_id or ""),
      tostring(piece.source_start_line or 1),
      tostring(piece.line_count or 0)
    )
  end

  local add_lines = { "WLPTADD1\n" }
  for block_id, block in pairs(payload.snapshot.add_blocks or {}) do
    add_lines[#add_lines + 1] = string.format("BLOCK|%s|%s\n", tostring(block_id), tostring(#(block.lines or {})))
    for _, line in ipairs(block.lines or {}) do
      add_lines[#add_lines + 1] = string.format("LINE|%s\n", hex_encode(line))
    end
  end

  local ok_meta, err_meta = write_recovery_chunk(self:get_recovery_meta_path(), table.concat(meta_lines))
  if not ok_meta then
    wlpt_trace("session.recovery.persist.fail id=%s file=%s reason=%s", tostring(self.id), tostring(self.file), tostring(err_meta))
    return false
  end
  local ok_snapshot, err_snapshot = write_recovery_chunk(self:get_recovery_snapshot_path(), table.concat(snapshot_lines))
  if not ok_snapshot then
    wlpt_trace("session.recovery.persist.fail id=%s file=%s reason=%s", tostring(self.id), tostring(self.file), tostring(err_snapshot))
    return false
  end
  local ok_add, err_add = write_recovery_chunk(self:get_recovery_add_path(), table.concat(add_lines))
  if not ok_add then
    wlpt_trace("session.recovery.persist.fail id=%s file=%s reason=%s", tostring(self.id), tostring(self.file), tostring(err_add))
    return false
  end
  wlpt_trace(
    "session.recovery.persist id=%s file=%s session=%s pieces=%s add_blocks=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self.session_id),
    tostring(#(payload.snapshot.pieces or {})),
    tostring(payload.snapshot.add_blocks and next(payload.snapshot.add_blocks) ~= nil)
  )
  return true
end

function WlPtSession:clear_recovery_state()
  os.remove(self:get_recovery_meta_path())
  os.remove(self:get_recovery_snapshot_path())
  os.remove(self:get_recovery_add_path())
  wlpt_trace(
    "session.recovery.clear id=%s file=%s session=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self.session_id)
  )
end

function WlPtSession:apply_recovery_state(meta, snapshot, add_blocks)
  local state = self:ensure_edit_state()
  state.pieces = clone_pieces(snapshot.pieces)
  state.add_blocks = clone_add_blocks(add_blocks)
  local max_add_id = 0
  for add_id in pairs(add_blocks or {}) do
    if type(add_id) == "number" and add_id > max_add_id then
      max_add_id = add_id
    end
  end
  state.next_add_id = max_add_id + 1
  self.dirty = true
  self.edit_epoch = self.edit_epoch + 1
  self.last_ready_window = nil
  self.last_requested_window = nil
  self.last_emitted_request_generation = 0
  self.last_emitted_edit_epoch = -1
  self:invalidate_highlight_all()
  if self.doc and meta.SELECTION_1 then
    local selection = {}
    local idx = 1
    while meta["SELECTION_" .. idx] do
      selection[idx] = tonumber(meta["SELECTION_" .. idx]) or 1
      idx = idx + 1
    end
    if #selection >= 4 then
      self.doc.selections = selection
      self.doc.last_selection = tonumber(meta.LAST_SELECTION) or 1
    end
  end
  if self.doc then
    self.doc.crlf = snapshot.crlf == true
  end
end

function WlPtSession:try_restore_recovery_state()
  local meta = parse_meta_content(read_recovery_chunk(self:get_recovery_meta_path()))
  local snapshot = parse_snapshot_content(read_recovery_chunk(self:get_recovery_snapshot_path()))
  local add_blocks = parse_add_content(read_recovery_chunk(self:get_recovery_add_path()))
  if type(snapshot) ~= "table" or type(snapshot.pieces) ~= "table" or #snapshot.pieces == 0 then
    return false
  end
  local info = self.doc and self.doc.abs_filename and system.get_file_info(self.doc.abs_filename) or nil
  local current_mtime = info and tostring(info.modified) or ""
  local current_size = info and tostring(info.size) or ""
  local saved_mtime = tostring(meta.SOURCE_MTIME or "")
  local saved_size = tostring(meta.SOURCE_SIZE or "")
  local path_matches = tostring(meta.SOURCE_ABS_FILENAME or "") == tostring(self.doc and self.doc.abs_filename or self.file or "")
  local baseline_matches = saved_mtime ~= "" and saved_size ~= "" and saved_mtime == current_mtime and saved_size == current_size
  if not baseline_matches then
    self.pending_recovery_conflict = {
      meta = meta,
      snapshot = snapshot,
      add_blocks = add_blocks,
      path_matches = path_matches,
      saved_mtime = saved_mtime,
      current_mtime = current_mtime,
      saved_size = saved_size,
      current_size = current_size,
      prompted = false,
    }
    wlpt_trace(
      "session.recovery.skip id=%s file=%s session=%s path_match=%s saved_mtime=%s current_mtime=%s saved_size=%s current_size=%s conflict=pending",
      tostring(self.id),
      tostring(self.file),
      tostring(self.session_id),
      tostring(path_matches),
      tostring(saved_mtime),
      tostring(current_mtime),
      tostring(saved_size),
      tostring(current_size)
    )
    return false
  end
  self:apply_recovery_state(meta, snapshot, add_blocks)
  wlpt_trace(
    "session.recovery.restore id=%s file=%s session=%s pieces=%s path_match=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self.session_id),
    tostring(#(snapshot.pieces or {})),
    tostring(path_matches)
  )
  return true
end

function WlPtSession:has_pending_recovery_conflict()
  return self.pending_recovery_conflict ~= nil
end

function WlPtSession:get_pending_recovery_conflict()
  return self.pending_recovery_conflict
end

function WlPtSession:mark_pending_recovery_conflict_prompted()
  if self.pending_recovery_conflict then
    self.pending_recovery_conflict.prompted = true
  end
end

function WlPtSession:restore_pending_recovery_conflict()
  local conflict = self.pending_recovery_conflict
  if not conflict then
    return false
  end
  self:apply_recovery_state(conflict.meta or {}, conflict.snapshot or {}, conflict.add_blocks or {})
  self.pending_recovery_conflict = nil
  wlpt_trace(
    "session.recovery.conflict.restore id=%s file=%s session=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self.session_id)
  )
  return true
end

function WlPtSession:discard_pending_recovery_conflict()
  if not self.pending_recovery_conflict then
    return false
  end
  self.pending_recovery_conflict = nil
  self:clear_recovery_state()
  wlpt_trace(
    "session.recovery.conflict.discard id=%s file=%s session=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self.session_id)
  )
  return true
end

function WlPtSession:is_save_in_progress()
  return self.save_in_progress == true
end

function WlPtSession:get_save_state()
  return self.save_state
end

function WlPtSession:update_file_identity(filename, abs_filename)
  local old_session_id = self.session_id
  local new_file = abs_filename or filename or self.file
  self.file = new_file
  self.session_id = make_session_id(new_file)
  if old_session_id ~= self.session_id and self.dirty then
    local old_meta = RECOVERY_DIR .. PATHSEP .. old_session_id .. ".meta"
    local old_snapshot = RECOVERY_DIR .. PATHSEP .. old_session_id .. ".snapshot"
    local old_add = RECOVERY_DIR .. PATHSEP .. old_session_id .. ".add"
    os.remove(old_meta)
    os.remove(old_snapshot)
    os.remove(old_add)
    self:persist_recovery_state()
  end
end

function WlPtSession:begin_save()
  if self.save_in_progress then
    return false
  end
  self.save_in_progress = true
  self.save_state = {
    saving = true,
    complete = false,
    failed = false,
    progress_bytes = 0,
    total_bytes = 0,
    error = nil,
  }
  self.pending_save_target = nil
  wlpt_trace(
    "session.save.begin id=%s file=%s dirty=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self.dirty)
  )
  return true
end

function WlPtSession:end_save(ok)
  self.save_in_progress = false
  if self.save_state then
    self.save_state.saving = false
    self.save_state.complete = ok == true
    self.save_state.failed = ok ~= true
  end
  if not ok then
    self.pending_save_target = nil
  end
  wlpt_trace(
    "session.save.end id=%s file=%s ok=%s dirty=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(ok),
    tostring(self.dirty)
  )
end

function WlPtSession:mark_saved()
  self.dirty = false
  self.pending_save_target = nil
  self.save_state = nil
  self:clear_recovery_state()
end

function WlPtSession:reset_after_save()
  self.edit_state = nil
  self.origin_line_cache = {}
  self.origin_line_cache_count = 0
  self:invalidate_highlight_all()
  self.last_ready_window = nil
  self.last_requested_window = nil
  self.last_emitted_request_generation = 0
  self.last_emitted_edit_epoch = -1
  self.edit_epoch = self.edit_epoch + 1
end

function WlPtSession:set_pending_save_target(filename, abs_filename)
  self.pending_save_target = {
    filename = filename,
    abs_filename = abs_filename,
  }
end

function WlPtSession:get_pending_save_target()
  return self.pending_save_target
end

function WlPtSession:update_save_progress(state)
  if type(state) ~= "table" then
    return
  end
  local current = self.save_state or {}
  local prev_progress = tonumber(current.progress_bytes or 0) or 0
  for k, v in pairs(state) do
    current[k] = v
  end
  self.save_state = current
  local progress = tonumber(current.progress_bytes or 0) or 0
  local total = tonumber(current.total_bytes or 0) or 0
  local last_logged = tonumber(self._last_logged_save_progress_bytes or 0) or 0
  if progress > 0 and (progress == total or progress - last_logged >= (64 * 1024 * 1024) or prev_progress == 0) then
    self._last_logged_save_progress_bytes = progress
    wlpt_trace(
      "session.save.progress id=%s file=%s written=%s total=%s",
      tostring(self.id),
      tostring(self.file),
      tostring(progress),
      tostring(total)
    )
  end
end

function WlPtSession:get_save_snapshot_base_path()
  return RECOVERY_DIR .. PATHSEP .. self.session_id .. ".save"
end

function WlPtSession:export_save_snapshot(target_filename, target_abs_filename)
  local snapshot_state = self:create_state_snapshot()
  local base_path = self:get_save_snapshot_base_path()
  local path = base_path .. ".snapshot"
  local add_path = base_path .. ".add"
  local info = self.doc and self.doc.abs_filename and system.get_file_info(self.doc.abs_filename) or nil
  local snapshot_lines = {
    "WLPTSNAP1\n",
    encode_meta_line("SOURCE_ABS_FILENAME", self.doc and self.doc.abs_filename or self.file or ""),
    encode_meta_line("TARGET_FILENAME", target_filename or self.doc and self.doc.filename or ""),
    encode_meta_line("TARGET_ABS_FILENAME", target_abs_filename or self.doc and self.doc.abs_filename or self.file or ""),
    encode_meta_line("SOURCE_MTIME", info and info.modified or ""),
    encode_meta_line("SOURCE_MTIME_MS", info and math.floor((info.modified or 0) * 1000 + 0.5) or ""),
    encode_meta_line("SOURCE_SIZE", info and info.size or ""),
    string.format("CRLF|%s\n", self.doc and self.doc.crlf and "1" or "0"),
  }
  for _, piece in ipairs(snapshot_state.pieces or {}) do
    snapshot_lines[#snapshot_lines + 1] = string.format(
      "PIECE|%s|%s|%s|%s\n",
      tostring(piece.kind or ""),
      tostring(piece.source_id or ""),
      tostring(piece.source_start_line or 1),
      tostring(piece.line_count or 0)
    )
  end
  local add_lines = { "WLPTADD1\n" }
  for block_id, block in pairs(snapshot_state.add_blocks or {}) do
    add_lines[#add_lines + 1] = string.format("BLOCK|%s|%s\n", tostring(block_id), tostring(#(block.lines or {})))
    for _, line in ipairs(block.lines or {}) do
      add_lines[#add_lines + 1] = string.format("LINE|%s\n", hex_encode(line))
    end
  end
  local ok_snapshot, err_snapshot = write_recovery_chunk(path, table.concat(snapshot_lines))
  if not ok_snapshot then
    return nil, err_snapshot or "unable to write wlpt save snapshot"
  end
  local ok_add, err_add = write_recovery_chunk(add_path, table.concat(add_lines))
  if not ok_add then
    return nil, err_add or "unable to write wlpt save add buffer"
  end
  wlpt_trace(
    "session.save_snapshot.export id=%s file=%s target=%s path=%s add=%s pieces=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(target_abs_filename or self.doc and self.doc.abs_filename or self.file),
    tostring(path),
    tostring(add_path),
    tostring(#(snapshot_state and snapshot_state.pieces or {}))
  )
  return {
    save_base_path = base_path,
    snapshot_path = path,
    add_buffer_path = add_path,
    source_abs_filename = self.doc and self.doc.abs_filename or self.file,
    target_filename = target_filename or self.doc and self.doc.filename,
    target_abs_filename = target_abs_filename or self.doc and self.doc.abs_filename or self.file,
  }
end

function WlPtSession:clear_save_snapshot()
  local base_path = self:get_save_snapshot_base_path()
  wlpt_trace(
    "[DEBUG-wlpt-save-cancel] session.save_snapshot.clear id=%s file=%s snapshot=%s add=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(base_path .. ".snapshot"),
    tostring(base_path .. ".add")
  )
  os.remove(base_path .. ".snapshot")
  os.remove(base_path .. ".add")
end

function WlPtSession:restore_state_snapshot(snapshot)
  if not snapshot then
    return false
  end
  local state = self:ensure_edit_state()
  state.pieces = clone_pieces(snapshot.pieces)
  state.add_blocks = clone_add_blocks(snapshot.add_blocks)
  state.next_add_id = snapshot.next_add_id or 1
  self.dirty = snapshot.dirty == true
  self.edit_epoch = self.edit_epoch + 1
  self:invalidate_highlight_all()
  self.last_ready_window = nil
  return true
end

function WlPtSession:read_origin_line(source_line)
  local cached = self.origin_line_cache[source_line]
  if cached ~= nil then
    return cached
  end
  if self.doc.raw_read_range then
    local text = self.doc:raw_read_range(source_line, 1, source_line, MAX_READ_COL, true)
    if type(text) == "string" and text ~= "" then
      if not text:find("\n", 1, true) then
        text = text .. "\n"
      end
      self.origin_line_cache[source_line] = text
      self.origin_line_cache_count = self.origin_line_cache_count + 1
      if self.origin_line_cache_count > 2048 then
        self.origin_line_cache = {}
        self.origin_line_cache_count = 0
      end
      return text
    end
  end
  if self.doc.raw_has_cached_line and self.doc:raw_has_cached_line(source_line) then
    return self.doc:raw_get_line(source_line)
  end
  return "\n"
end

function WlPtSession:find_piece(line)
  local state = self.edit_state
  if not state then
    return nil
  end
  local cursor = 1
  for idx, piece in ipairs(state.pieces) do
    local piece_end = cursor + piece.line_count - 1
    if line >= cursor and line <= piece_end then
      return idx, piece, cursor, piece_end
    end
    cursor = piece_end + 1
  end
  return nil
end

function WlPtSession:resolve_session_line(line)
  if not self.edit_state then
    return {
      session_line = line,
      piece_index = nil,
      piece = nil,
      piece_start_line = line,
      piece_end_line = line,
      offset = 0,
      kind = "origin",
      source_line = line,
      text = self.doc:raw_get_line(line),
    }
  end
  local piece_index, piece, piece_start, piece_end = self:find_piece(line)
  if not piece then
    return {
      session_line = line,
      piece_index = nil,
      piece = nil,
      piece_start_line = nil,
      piece_end_line = nil,
      offset = nil,
      kind = "missing",
      source_line = nil,
      text = "\n",
    }
  end
  local offset = line - piece_start
  local source_line = (piece.source_start_line or 1) + offset
  local text
  if piece.kind == "origin" then
    text = self:read_origin_line(source_line)
  else
    local block = self.edit_state and self.edit_state.add_blocks[piece.source_id]
    text = (block and block.lines and block.lines[source_line]) or "\n"
  end
  return {
    session_line = line,
    piece_index = piece_index,
    piece = piece,
    piece_start_line = piece_start,
    piece_end_line = piece_end,
    offset = offset,
    kind = piece.kind,
    source_line = source_line,
    text = text,
  }
end

function WlPtSession:line_count()
  if not self.edit_state then
    return self.doc:raw_line_count()
  end
  return piece_total_lines(self.edit_state.pieces)
end

function WlPtSession:line_count_for_log()
  return self.doc:raw_line_count()
end

function WlPtSession:get_line(line)
  if not self.edit_state then
    return self.doc:raw_get_line(line)
  end
  return self:resolve_session_line(line).text or "\n"
end

function WlPtSession:get_line_for_log(line)
  return self.doc:raw_get_line(line)
end

function WlPtSession:get_line_length(line)
  return #self:get_line(line)
end

function WlPtSession:get_text(line1, col1, line2, col2, inclusive)
  if not self.edit_state then
    return self.doc:raw_get_text(line1, col1, line2, col2, inclusive)
  end
  line1, col1 = self.doc:sanitize_position(line1, col1)
  line2, col2 = self.doc:sanitize_position(line2, col2)
  line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)
  local col2_offset = inclusive and 0 or 1
  if line1 == line2 then
    return self:get_line(line1):sub(col1, col2 - col2_offset)
  end
  local lines = { self:get_line(line1):sub(col1) }
  for line = line1 + 1, line2 - 1 do
    lines[#lines + 1] = self:get_line(line)
  end
  lines[#lines + 1] = self:get_line(line2):sub(1, col2 - col2_offset)
  return table.concat(lines)
end

function WlPtSession:get_text_for_log(line1, col1, line2, col2, inclusive)
  return self.doc:raw_get_text(line1, col1, line2, col2, inclusive)
end

function WlPtSession:get_char(line, col)
  line, col = self.doc:sanitize_position(line, col)
  return self:get_text(line, col, line, col, true)
end

function WlPtSession:get_all_text()
  if not self.edit_state then
    return self.doc:raw_get_all_text()
  end
  local lines = {}
  for line = 1, self:line_count() do
    lines[#lines + 1] = self:get_line(line)
  end
  return table.concat(lines)
end

function WlPtSession:get_all_text_for_log()
  return self.doc:raw_get_all_text()
end

function WlPtSession:is_view_ready(start_line, end_line)
  if self.edit_state then
    return true
  end
  return self.doc:raw_is_view_ready(start_line, end_line)
end

function WlPtSession:has_any_cached_lines(start_line, end_line)
  if self.edit_state then
    return true
  end
  return self.doc:raw_has_any_cached_lines(start_line, end_line)
end

function WlPtSession:has_cached_line(line)
  if self.edit_state then
    line = math.max(1, math.min(line, self:line_count()))
    return self:resolve_session_line(line).kind ~= "missing"
  end
  return self.doc:raw_has_cached_line(line)
end

function WlPtSession:get_cached_window_range()
  if self.edit_state and self.last_ready_window then
    return self.last_ready_window.start_line, self.last_ready_window.end_line
  end
  return self.doc:raw_get_cached_window_range()
end

function WlPtSession:debug_describe_session_line(line)
  local total_lines = self:line_count()
  if line < 1 or line > total_lines then
    return string.format("line=%s session=<out-of-range>", tostring(line))
  end
  local resolved = self:resolve_session_line(line)
  return string.format(
    "line=%s session.kind=%s piece_index=%s piece_range=%s-%s offset=%s source_line=%s text=\"%s\"",
    tostring(line),
    tostring(resolved.kind),
    tostring(resolved.piece_index),
    tostring(resolved.piece_start_line),
    tostring(resolved.piece_end_line),
    tostring(resolved.offset),
    tostring(resolved.source_line),
    sanitize_preview_text(resolved.text)
  )
end

function WlPtSession:debug_describe_raw_line(line)
  local raw_total_lines = self:line_count_for_log()
  if line < 1 or line > raw_total_lines then
    return string.format("line=%s raw=<out-of-range>", tostring(line))
  end
  local cached = self.doc.raw_has_cached_line and self.doc:raw_has_cached_line(line) or false
  return string.format(
    "line=%s raw.cached=%s text=\"%s\"",
    tostring(line),
    tostring(cached),
    sanitize_preview_text(self:get_line_for_log(line))
  )
end

function WlPtSession:debug_log_line_probe(label, center_line, radius)
  local start_line = math.max(1, center_line - radius)
  local end_line = math.min(self:line_count(), center_line + radius)
  wlpt_trace(
    "%s %s id=%s file=%s center=%s range=%s-%s",
    DEBUG_TAG,
    tostring(label),
    tostring(self.id),
    tostring(self.file),
    tostring(center_line),
    tostring(start_line),
    tostring(end_line)
  )
  for line = start_line, end_line do
    wlpt_trace(
      "%s %s %s || %s",
      DEBUG_TAG,
      tostring(label),
      self:debug_describe_session_line(line),
      self:debug_describe_raw_line(line)
    )
  end
end

function WlPtSession:debug_log_window_probe(label, assembled, center_line, radius)
  if not assembled or not assembled.lines then
    return
  end
  local start_line = math.max(assembled.start_line or 1, center_line - radius)
  local end_line = math.min(assembled.end_line or center_line, center_line + radius)
  wlpt_trace(
    "%s %s id=%s file=%s center=%s window=%s-%s probe=%s-%s requested=%s-%s",
    DEBUG_TAG,
    tostring(label),
    tostring(self.id),
    tostring(self.file),
    tostring(center_line),
    tostring(assembled.start_line),
    tostring(assembled.end_line),
    tostring(start_line),
    tostring(end_line),
    tostring(assembled.requested_start_line),
    tostring(assembled.requested_end_line)
  )
  for line = start_line, end_line do
    local idx = line - (assembled.start_line or 1) + 1
    local ready_text = (assembled.lines and assembled.lines[idx]) or nil
    wlpt_trace(
      "%s %s line=%s ready.text=\"%s\" || %s",
      DEBUG_TAG,
      tostring(label),
      tostring(line),
      sanitize_preview_text(ready_text),
      self:debug_describe_session_line(line)
    )
  end
end

function WlPtSession:request_visible_window(start_line, end_line, margin)
  local request = {
    start_line = start_line,
    end_line = end_line,
    margin = margin or 0,
  }
  local last = self.last_requested_window
  if not last
    or last.start_line ~= request.start_line
    or last.end_line ~= request.end_line
    or last.margin ~= request.margin
  then
    self.request_generation = self.request_generation + 1
    wlpt_trace(
      "session.request_window id=%s file=%s request=%s-%s margin=%s",
      tostring(self.id),
      tostring(self.file),
      tostring(request.start_line),
      tostring(request.end_line),
      tostring(request.margin)
    )
    self.last_requested_window = request
  end
  if self.edit_state then
    self.doc:raw_request_visible_window(start_line, end_line, margin)
    return request
  end
  return self.doc:raw_request_visible_window(start_line, end_line, margin)
end

function WlPtSession:poll_ready_window(budget_hint)
  if self.edit_state and self.last_requested_window then
    local backend_ready = self.doc:raw_poll_ready_window(budget_hint)
    if backend_ready and backend_ready.lines then
      -- Keep origin window cache warm even after entering edited mode.
      wlpt_trace(
        "session.backend_window id=%s file=%s request=%s-%s backend=%s-%s lines=%s first=\"%s\" last=\"%s\"",
        tostring(self.id),
        tostring(self.file),
        tostring(self.last_requested_window and self.last_requested_window.start_line),
        tostring(self.last_requested_window and self.last_requested_window.end_line),
        tostring(backend_ready.start_line),
        tostring(backend_ready.end_line),
        tostring(#(backend_ready.lines or {})),
        summarize_window_preview(backend_ready.lines and backend_ready.lines[1]),
        summarize_window_preview(backend_ready.lines and backend_ready.lines[#(backend_ready.lines or {})])
      )
      self.doc:store_snapshot_chunks(backend_ready)
    end
    local should_emit = self.last_emitted_request_generation ~= self.request_generation
      or self.last_emitted_edit_epoch ~= self.edit_epoch
    if not should_emit then
      return nil
    end
    local request = self.last_requested_window
    local start_line = math.max(1, request.start_line - (request.margin or 0))
    local end_line = math.min(self:line_count(), request.end_line + (request.margin or 0))
    local lines = {}
    for line = start_line, end_line do
      lines[#lines + 1] = self:get_line(line)
    end
    local ready = {
      start_line = start_line,
      end_line = end_line,
      requested_start_line = request.start_line,
      requested_end_line = request.end_line,
      margin = request.margin or 0,
      epoch = (self.last_ready_window and (self.last_ready_window.epoch or 0) or 0) + 1,
      chunk_line_count = self.doc.chunk_line_count or 256,
      lines = lines,
    }
    local assembled = self:assemble_window(ready)
    wlpt_trace(
      "session.assembled_window id=%s file=%s request=%s-%s local=%s-%s assembled=%s-%s lines=%s first=\"%s\" last=\"%s\"",
      tostring(self.id),
      tostring(self.file),
      tostring(request.start_line),
      tostring(request.end_line),
      tostring(ready.start_line),
      tostring(ready.end_line),
      tostring(assembled.start_line),
      tostring(assembled.end_line),
      tostring(#(assembled.lines or {})),
      summarize_window_preview(assembled.lines and assembled.lines[1]),
      summarize_window_preview(assembled.lines and assembled.lines[#(assembled.lines or {})])
    )
    self.doc:store_snapshot_chunks(assembled)
    if self.last_edit_probe
      and self.last_edit_probe.edit_epoch == self.edit_epoch
      and self.last_edit_probe.line >= assembled.start_line
      and self.last_edit_probe.line <= assembled.end_line
    then
      self:debug_log_window_probe("session.ready_window_probe", assembled, self.last_edit_probe.line, 4)
    end
    self.last_ready_window = {
      start_line = assembled.start_line,
      end_line = assembled.end_line,
      requested_start_line = assembled.requested_start_line,
      requested_end_line = assembled.requested_end_line,
      line_count = #(assembled.lines or {}),
      epoch = assembled.epoch,
    }
    self.last_emitted_request_generation = self.request_generation
    self.last_emitted_edit_epoch = self.edit_epoch
    wlpt_trace(
      "session.ready_window id=%s file=%s request=%s-%s resolved=%s-%s lines=%s cached=%s-%s mode=edited",
      tostring(self.id),
      tostring(self.file),
      tostring(assembled.requested_start_line),
      tostring(assembled.requested_end_line),
      tostring(assembled.start_line),
      tostring(assembled.end_line),
      tostring(#(assembled.lines or {})),
      tostring(assembled.start_line),
      tostring(assembled.end_line)
    )
    core.redraw = true
    return assembled
  end
  local ready = self.doc:raw_poll_ready_window(budget_hint)
  if ready and ready.lines then
    local assembled = self:assemble_window(ready)
    self.doc:store_snapshot_chunks(assembled)
    self.last_ready_window = {
      start_line = assembled.start_line,
      end_line = assembled.end_line,
      requested_start_line = assembled.requested_start_line,
      requested_end_line = assembled.requested_end_line,
      line_count = #(assembled.lines or {}),
    }
    local cached_start, cached_end = self:get_cached_window_range()
    wlpt_trace(
      "session.ready_window id=%s file=%s request=%s-%s resolved=%s-%s lines=%s cached=%s-%s",
      tostring(self.id),
      tostring(self.file),
      tostring(assembled.requested_start_line),
      tostring(assembled.requested_end_line),
      tostring(assembled.start_line),
      tostring(assembled.end_line),
      tostring(#(assembled.lines or {})),
      tostring(cached_start),
      tostring(cached_end)
    )
    core.redraw = true
    return assembled
  end
  return ready
end

function WlPtSession:assemble_window(ready)
  -- Phase B keeps the existing origin-window path, but the final handoff to
  -- viewport cache is centralized here so later pt/add assembly can replace it.
  return ready
end

function WlPtSession:create_add_piece(lines)
  local state = self:ensure_edit_state()
  local id = state.next_add_id
  state.next_add_id = id + 1
  state.add_blocks[id] = { lines = lines }
  return {
    kind = "add",
    source_id = id,
    source_start_line = 1,
    line_count = #lines,
  }
end

function WlPtSession:replace_line_span(line1, line2, replacement_lines)
  local state = self:ensure_edit_state()
  local prefix = {}
  local suffix = {}
  local cursor = 1
  for _, piece in ipairs(state.pieces) do
    local piece_end = cursor + piece.line_count - 1
    if piece_end < line1 then
      prefix[#prefix + 1] = copy_piece(piece, 0, piece.line_count)
    elseif cursor > line2 then
      suffix[#suffix + 1] = copy_piece(piece, 0, piece.line_count)
    else
      if cursor < line1 then
        prefix[#prefix + 1] = copy_piece(piece, 0, line1 - cursor)
      end
      if piece_end > line2 then
        local offset = line2 - cursor + 1
        suffix[#suffix + 1] = copy_piece(piece, offset, piece_end - line2)
      end
    end
    cursor = piece_end + 1
  end

  local pieces = {}
  for _, piece in ipairs(prefix) do
    pieces[#pieces + 1] = piece
  end
  if replacement_lines and #replacement_lines > 0 then
    pieces[#pieces + 1] = self:create_add_piece(replacement_lines)
  end
  for _, piece in ipairs(suffix) do
    pieces[#pieces + 1] = piece
  end
  if #pieces == 0 then
    pieces[1] = self:create_add_piece({ "\n" })
  end
  state.pieces = pieces
end

function WlPtSession:replace_range(line1, col1, line2, col2, new_text, options)
  options = options or {}
  local selection_before = options.selection_before and copy_array(options.selection_before) or nil
  line1, col1 = self.doc:sanitize_position(line1, col1)
  line2, col2 = self.doc:sanitize_position(line2, col2)
  line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)

  local snapshot_before = nil
  if options.record_undo then
    local approx_span = math.max(0, line2 - line1) * 16 + math.max(0, col2 - col1)
    if approx_span > MAX_UNDO_TEXT_BYTES then
      snapshot_before = self:create_state_snapshot()
    end
  end
  local old_text = snapshot_before and "" or self:get_text(line1, col1, line2, col2)
  local start_line = self:get_line(line1)
  local end_line = self:get_line(line2)
  local replacement_text = start_line:sub(1, col1 - 1) .. (new_text or "") .. end_line:sub(col2)
  local replacement_lines = split_doc_lines(replacement_text)

  self:replace_line_span(line1, line2, replacement_lines)
  self.edit_epoch = self.edit_epoch + 1
  self.dirty = true
  self:invalidate_highlight_from(line1)
  self.last_ready_window = nil
  self.last_edit_probe = {
    line = line1,
    col = col1,
    edit_epoch = self.edit_epoch,
  }

  local cursor_line, cursor_col = self.doc:position_offset(line1, col1, #(new_text or ""))
  local selection_after = options.selection_after and copy_array(options.selection_after) or { cursor_line, cursor_col, cursor_line, cursor_col }

  if options.record_undo then
    local state = self:ensure_edit_state()
    state.redo_stack = { idx = 1 }
    local idx = state.undo_stack.idx
    state.undo_stack[idx] = {
      kind = "replace_range",
      line1 = line1,
      col1 = col1,
      old_text = old_text,
      new_text = new_text or "",
      state_snapshot = snapshot_before,
      selection_before = selection_before,
      selection_after = selection_after,
    }
    state.undo_stack[idx + 1] = nil
    state.undo_stack.idx = idx + 1
  end

  wlpt_trace(
    "session.replace_range id=%s file=%s range=%s:%s-%s:%s old_len=%s new_len=%s total_lines=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(line1),
    tostring(col1),
    tostring(line2),
    tostring(col2),
    tostring(#old_text),
    tostring(#(new_text or "")),
    tostring(self:line_count())
  )
  self:debug_log_line_probe("session.replace_probe", line1, 4)
  self:persist_recovery_state()

  return {
    line1 = line1,
    col1 = col1,
    line2 = cursor_line,
    col2 = cursor_col,
    old_text = old_text,
    selection_after = selection_after,
  }
end

function WlPtSession:undo()
  local state = self.edit_state
  if not state then
    return nil
  end
  local cmd = state.undo_stack[state.undo_stack.idx - 1]
  if not cmd then
    return nil
  end
  state.undo_stack.idx = state.undo_stack.idx - 1
  if cmd.state_snapshot then
    local redo_snapshot = self:create_state_snapshot()
    self:restore_state_snapshot(cmd.state_snapshot)
    local redo_idx = state.redo_stack.idx
    state.redo_stack[redo_idx] = {
      kind = "state_snapshot",
      state_snapshot = redo_snapshot,
      selection_before = copy_array(self.doc.selections),
      selection_after = cmd.selection_after and copy_array(cmd.selection_after) or nil,
    }
    state.redo_stack[redo_idx + 1] = nil
    state.redo_stack.idx = redo_idx + 1
    self.doc.selections = cmd.selection_before and copy_array(cmd.selection_before) or self.doc.selections
    self.doc.last_selection = 1
  wlpt_trace(
    "session.undo id=%s file=%s total_lines=%s mode=snapshot",
      tostring(self.id),
      tostring(self.file),
      tostring(self:line_count())
    )
    self:persist_recovery_state()
    return {
      line1 = self.doc.selections[1],
      col1 = self.doc.selections[2],
    }
  end
  local cursor_line, cursor_col = self.doc:position_offset(cmd.line1, cmd.col1, #cmd.new_text)
  local redo_selection_before = copy_array(self.doc.selections)
  local result = self:replace_range(cmd.line1, cmd.col1, cursor_line, cursor_col, cmd.old_text, {
    record_undo = false,
  })
  local redo_idx = state.redo_stack.idx
  state.redo_stack[redo_idx] = {
    kind = "replace_range",
    line1 = cmd.line1,
    col1 = cmd.col1,
    old_text = cmd.old_text,
    new_text = cmd.new_text,
    selection_before = redo_selection_before,
    selection_after = cmd.selection_after and copy_array(cmd.selection_after) or nil,
  }
  state.redo_stack[redo_idx + 1] = nil
  state.redo_stack.idx = redo_idx + 1
  self.doc.selections = cmd.selection_before and copy_array(cmd.selection_before) or self.doc.selections
  self.doc.last_selection = 1
  wlpt_trace(
    "session.undo id=%s file=%s total_lines=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self:line_count())
  )
  self:persist_recovery_state()
  return result
end

function WlPtSession:redo()
  local state = self.edit_state
  if not state then
    return nil
  end
  local cmd = state.redo_stack[state.redo_stack.idx - 1]
  if not cmd then
    return nil
  end
  state.redo_stack.idx = state.redo_stack.idx - 1
  if cmd.state_snapshot then
    local undo_snapshot = self:create_state_snapshot()
    self:restore_state_snapshot(cmd.state_snapshot)
    local undo_idx = state.undo_stack.idx
    state.undo_stack[undo_idx] = {
      kind = "state_snapshot",
      state_snapshot = undo_snapshot,
      selection_before = copy_array(self.doc.selections),
      selection_after = cmd.selection_after and copy_array(cmd.selection_after) or nil,
    }
    state.undo_stack[undo_idx + 1] = nil
    state.undo_stack.idx = undo_idx + 1
    self.doc.selections = cmd.selection_after and copy_array(cmd.selection_after) or self.doc.selections
    self.doc.last_selection = 1
  wlpt_trace(
    "session.redo id=%s file=%s total_lines=%s mode=snapshot",
      tostring(self.id),
      tostring(self.file),
      tostring(self:line_count())
    )
    self:persist_recovery_state()
    return {
      line1 = self.doc.selections[1],
      col1 = self.doc.selections[2],
    }
  end
  local cursor_line, cursor_col = self.doc:position_offset(cmd.line1, cmd.col1, #cmd.old_text)
  local undo_selection_before = copy_array(self.doc.selections)
  local result = self:replace_range(cmd.line1, cmd.col1, cursor_line, cursor_col, cmd.new_text, {
    record_undo = false,
  })
  local undo_idx = state.undo_stack.idx
  state.undo_stack[undo_idx] = {
    kind = "replace_range",
    line1 = cmd.line1,
    col1 = cmd.col1,
    old_text = cmd.old_text,
    new_text = cmd.new_text,
    selection_before = undo_selection_before,
    selection_after = cmd.selection_after and copy_array(cmd.selection_after) or nil,
  }
  state.undo_stack[undo_idx + 1] = nil
  state.undo_stack.idx = undo_idx + 1
  self.doc.selections = cmd.selection_after and copy_array(cmd.selection_after) or self.doc.selections
  self.doc.last_selection = 1
  wlpt_trace(
    "session.redo id=%s file=%s total_lines=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self:line_count())
  )
  self:persist_recovery_state()
  return result
end

function WlPtSession:close()
  local save_state = self.save_state or {}
  local save_base_path = self:get_save_snapshot_base_path()
  wlpt_trace(
    "[DEBUG-wlpt-save-cancel] session.close.begin id=%s file=%s dirty=%s save_in_progress=%s progress=%s/%s snapshot=%s add=%s target=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self.dirty),
    tostring(self.save_in_progress),
    tostring(save_state.progress_bytes),
    tostring(save_state.total_bytes),
    tostring(save_base_path .. ".snapshot"),
    tostring(save_base_path .. ".add"),
    tostring(self.pending_save_target and self.pending_save_target.abs_filename)
  )
  if self.dirty then
    self:persist_recovery_state()
  end
  wlpt_trace(
    "[DEBUG-wlpt-save-cancel] session.close.done id=%s file=%s mode=%s dirty=%s save_in_progress=%s",
    tostring(self.id),
    tostring(self.file),
    tostring(self.mode),
    tostring(self.dirty),
    tostring(self.save_in_progress)
  )
end

return WlPtSession
