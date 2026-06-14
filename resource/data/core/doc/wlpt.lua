local core = require "core"
local translate = require "core.doc.translate"
local LargeFileDoc = require "core.doc.largefile"
local WlPtSession = require "core.doc.wlpt_session"
local system = require "system"

---@class core.wlptdoc : core.largefiledoc
local WlPtDoc = LargeFileDoc:extend()

local function notify_binary_readonly(self)
  if not self._large_file_readonly_notified or (system.get_time() - self._large_file_readonly_notified) > 1.5 then
    self._large_file_readonly_notified = system.get_time()
    local message = string.format("Binary hex view is read-only: %s", tostring(self:get_name()))
    core.log("%s", message)
  end
end

local function localize_save_error(err)
  local raw = tostring(err or "unknown error")
  local lower = raw:lower()

  if lower:find("no space left on device", 1, true)
    or lower:find("there is not enough space", 1, true)
    or lower:find("not enough space", 1, true)
    or lower:find("disk full", 1, true) then
    return "保存失败：磁盘剩余空间不足，临时保存文件无法写完。原文件未被修改，当前未保存修改仍然保留。"
  end

  if lower:find("source baseline changed during save", 1, true) then
    return "保存失败：保存过程中源文件已被外部程序修改。原文件未被覆盖，当前未保存修改仍然保留。"
  end

  if lower:find("failed to replace target file", 1, true) then
    return "保存失败：临时文件已经写出，但替换目标文件时失败。原文件未被覆盖，当前未保存修改仍然保留。"
  end

  if lower:find("access is denied", 1, true)
    or lower:find("permission denied", 1, true) then
    return "保存失败：没有权限写入目标文件。原文件未被修改，当前未保存修改仍然保留。"
  end

  if lower:find("failed to read source line", 1, true) then
    return "保存失败：读取原文件内容时出错。原文件未被修改，当前未保存修改仍然保留。"
  end

  if lower:find("save cancelled", 1, true) then
    return "保存已取消。原文件未被修改，当前未保存修改仍然保留。"
  end

  return string.format(
    "保存失败：%s。原文件未被修改，当前未保存修改仍然保留。",
    raw
  )
end

local function notify_save_failure(err)
  local localized = localize_save_error(err)
  core.error("%s", localized)
end

local function maybe_prompt_recovery_conflict(self, session)
  if not session or not session.has_pending_recovery_conflict or not session:has_pending_recovery_conflict() then
    return
  end
  local conflict = session:get_pending_recovery_conflict()
  if not conflict or conflict.prompted or not core.nag_view then
    return
  end
  session:mark_pending_recovery_conflict_prompted()
  core.nag_view:show(
    "文件恢复冲突",
    string.format(
      "%s 在你上次未保存修改之后，已经被外部程序改动过。\n是否保留上次未保存的修改？\n\n保留：恢复上次未保存的修改，但之后如果你保存，可能覆盖外部的新改动。\n丢弃：放弃上次未保存的修改，保留当前磁盘文件内容。",
      tostring(self.filename or self.abs_filename or "file")
    ),
    {
      { text = "保留未保存修改", default_yes = true },
      { text = "丢弃未保存修改", default_no = true },
    },
    function(item)
      if item and item.text == "保留未保存修改" then
        if session:restore_pending_recovery_conflict() then
          core.redraw = true
        end
      else
        session:discard_pending_recovery_conflict()
        core.redraw = true
      end
    end
  )
end

local function wlpt_trace(fmt, ...)
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then text = tostring(fmt) end
  local fp = io.open(USERDIR .. PATHSEP .. "wlpt-debug.log", "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " ", text, "\n")
    fp:close()
  end
end

local function trace_selection(self, stage)
  local line1, col1, line2, col2 = self:get_selection(true)
  wlpt_trace(
    "[DEBUG-wlpt-selection] %s file=%s sel=%s:%s-%s:%s last=%s ime_saved=%s",
    tostring(stage),
    tostring(self.abs_filename or self.filename),
    tostring(line1),
    tostring(col1),
    tostring(line2),
    tostring(col2),
    tostring(self.last_selection),
    tostring(self._ime_composition_selection and "yes" or "no")
  )
end

local function get_session(self)
  return self.wlpt_session
end

local function invalidate_chunk_highlight(self, line)
  if self.chunk_highlighter and line then
    self.chunk_highlighter:invalidate_from_line(line)
  end
end

local function copy_array(values)
  local result = {}
  for i = 1, #(values or {}) do
    result[i] = values[i]
  end
  return result
end

local function trace_docview_positions(self, label)
  local views = core.get_views_referencing_doc and core.get_views_referencing_doc(self) or {}
  local line1, col1, line2, col2 = self:get_selection(true)
  wlpt_trace(
    "doc.%s.selection file=%s sel=%s:%s-%s:%s views=%s",
    tostring(label),
    tostring(self.abs_filename or self.filename),
    tostring(line1),
    tostring(col1),
    tostring(line2),
    tostring(col2),
    tostring(#views)
  )
  for i, view in ipairs(views) do
    wlpt_trace(
      "doc.%s.view[%s] file=%s scroll=%s,%s visible=%s-%s",
      tostring(label),
      tostring(i),
      tostring(self.abs_filename or self.filename),
      tostring(view and view.scroll and view.scroll.x),
      tostring(view and view.scroll and view.scroll.y),
      tostring(view and view.get_visible_line_range and select(1, view:get_visible_line_range())),
      tostring(view and view.get_visible_line_range and select(2, view:get_visible_line_range()))
    )
  end
end

local function restore_docview_positions(self, label)
  local views = core.get_views_referencing_doc and core.get_views_referencing_doc(self) or {}
  local line1 = select(1, self:get_selection(true))
  for i, view in ipairs(views) do
    if view and view.scroll_to_line then
      view:scroll_to_line(line1, false, true)
      wlpt_trace(
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

local function trace_bootstrap_fallback(self, method)
  if self._wlpt_bootstrap_fallback_logged then
    return
  end
  self._wlpt_bootstrap_fallback_logged = true
  wlpt_trace(
    "doc.bootstrap_fallback file=%s method=%s session=nil",
    tostring(self.abs_filename or self.filename),
    tostring(method)
  )
end

function WlPtDoc:__tostring()
  return "WlPtDoc"
end

function WlPtDoc:new(filename, abs_filename, new_file, skip_load)
  WlPtDoc.super.new(self, filename, abs_filename, new_file, skip_load)
  self.wlpt_mode = true
  self.wlpt_session = WlPtSession(self)
  self._ime_composition_selection = nil
  wlpt_trace(
    "doc.create file=%s new_file=%s session=%s mode=wlpt",
    tostring(self.abs_filename or self.filename),
    tostring(new_file),
    tostring(self.wlpt_session and self.wlpt_session.id)
  )
end

function WlPtDoc:is_wlpt_mode()
  return self.wlpt_mode == true
end

function WlPtDoc:reset_syntax()
  WlPtDoc.super.reset_syntax(self)
  if self.wlpt_session and self.wlpt_session.invalidate_highlight_all then
    self.wlpt_session:invalidate_highlight_all()
  end
end

function WlPtDoc:get_highlight_syntax()
  local syntax = self.syntax
  if self.logical_syntax
    and syntax
    and syntax.name == "Plain Text"
    and self.logical_syntax.name ~= "Plain Text"
  then
    syntax = self.logical_syntax
  end
  return syntax or self.logical_syntax
end

function WlPtDoc:get_highlight_tokens(line)
  local session = get_session(self)
  if session and session.get_highlight_tokens then
    return session:get_highlight_tokens(line)
  end
  return nil
end

function WlPtDoc:get_cached_highlight_tokens(line)
  local session = get_session(self)
  if session and session.get_cached_highlight_tokens then
    return session:get_cached_highlight_tokens(line)
  end
  return nil
end

function WlPtDoc:prepare_highlight_window(start_line, end_line, time_budget)
  local session = get_session(self)
  if session and session.prepare_highlight_window then
    return session:prepare_highlight_window(start_line, end_line, time_budget)
  end
  return false
end

function WlPtDoc:get_mode_label()
  return self.wlpt_session and self.wlpt_session:get_mode_label() or "WL-PT"
end

function WlPtDoc:raw_line_count()
  return WlPtDoc.super.line_count(self)
end

function WlPtDoc:raw_get_line(line)
  return WlPtDoc.super.get_line(self, line)
end

function WlPtDoc:raw_get_text(line1, col1, line2, col2, inclusive)
  return WlPtDoc.super.get_text(self, line1, col1, line2, col2, inclusive)
end

function WlPtDoc:raw_has_cached_line(line)
  return WlPtDoc.super.has_cached_line(self, line)
end

function WlPtDoc:raw_get_all_text()
  return WlPtDoc.super.get_all_text(self)
end

function WlPtDoc:raw_is_view_ready(start_line, end_line)
  return WlPtDoc.super.is_view_ready(self, start_line, end_line)
end

function WlPtDoc:raw_has_any_cached_lines(start_line, end_line)
  return WlPtDoc.super.has_any_cached_lines(self, start_line, end_line)
end

function WlPtDoc:raw_get_cached_window_range()
  return WlPtDoc.super.get_cached_window_range(self)
end

function WlPtDoc:raw_request_visible_window(start_line, end_line, margin)
  return WlPtDoc.super.request_visible_window(self, start_line, end_line, margin)
end

function WlPtDoc:raw_poll_ready_window(budget_hint)
  if self.loading_error or not self.backend then
    return nil
  end
  return self.backend:poll_ready_window(budget_hint)
end

function WlPtDoc:poll_save()
  if not self.backend or not self.backend.poll_save then
    return nil
  end
  return self.backend:poll_save()
end

function WlPtDoc:raw_read_range(start_line, start_col, end_line, end_col, inclusive)
  if self.backend and self.backend.read_range then
    return self.backend:read_range(start_line, start_col, end_line, end_col, inclusive)
  end
  return nil
end

function WlPtDoc:line_count()
  local session = get_session(self)
  if session then
    return session:line_count()
  end
  trace_bootstrap_fallback(self, "line_count")
  return self:raw_line_count()
end

function WlPtDoc:get_line(line)
  local session = get_session(self)
  if session then
    return session:get_line(line)
  end
  trace_bootstrap_fallback(self, "get_line")
  return self:raw_get_line(line)
end

function WlPtDoc:get_line_length(line)
  local session = get_session(self)
  if session then
    return session:get_line_length(line)
  end
  trace_bootstrap_fallback(self, "get_line_length")
  return #self:raw_get_line(line)
end

function WlPtDoc:get_text(line1, col1, line2, col2, inclusive)
  local session = get_session(self)
  if session then
    return session:get_text(line1, col1, line2, col2, inclusive)
  end
  trace_bootstrap_fallback(self, "get_text")
  return self:raw_get_text(line1, col1, line2, col2, inclusive)
end

function WlPtDoc:get_char(line, col)
  local session = get_session(self)
  if session then
    return session:get_char(line, col)
  end
  trace_bootstrap_fallback(self, "get_char")
  return self:raw_get_text(line, col, line, col, true)
end

function WlPtDoc:get_all_text()
  local session = get_session(self)
  if session then
    return session:get_all_text()
  end
  trace_bootstrap_fallback(self, "get_all_text")
  return self:raw_get_all_text()
end

function WlPtDoc:is_view_ready(start_line, end_line)
  local session = get_session(self)
  if session then
    return session:is_view_ready(start_line, end_line)
  end
  return self:raw_is_view_ready(start_line, end_line)
end

function WlPtDoc:has_any_cached_lines(start_line, end_line)
  local session = get_session(self)
  if session then
    return session:has_any_cached_lines(start_line, end_line)
  end
  return self:raw_has_any_cached_lines(start_line, end_line)
end

function WlPtDoc:has_cached_line(line)
  local session = get_session(self)
  if session and session.has_cached_line then
    return session:has_cached_line(line)
  end
  return self:raw_has_cached_line(line)
end

function WlPtDoc:get_cached_window_range()
  local session = get_session(self)
  if session then
    return session:get_cached_window_range()
  end
  return self:raw_get_cached_window_range()
end

function WlPtDoc:request_visible_window(start_line, end_line, margin)
  local session = get_session(self)
  if session then
    return session:request_visible_window(start_line, end_line, margin)
  end
  return self:raw_request_visible_window(start_line, end_line, margin)
end

function WlPtDoc:poll_ready_window(budget_hint)
  local session = get_session(self)
  if session then
    maybe_prompt_recovery_conflict(self, session)
    local save_state = self:poll_save()
    if save_state then
      session:update_save_progress(save_state)
      if save_state.complete then
        trace_docview_positions(self, "save_complete.before_reopen")
        local target = session:get_pending_save_target()
        session:end_save(true)
        session:clear_save_snapshot()
        session:mark_saved()
        if target then
          self:set_filename(target.filename, target.abs_filename)
          session:update_file_identity(target.filename, target.abs_filename)
        else
          session:update_file_identity(self.filename, self.abs_filename)
        end
        session:reset_after_save()
        self.new_file = false
        self:clean()
        if self.reopen_largefile_backend then
          self:reopen_largefile_backend()
        end
        restore_docview_positions(self, "save_complete")
        trace_docview_positions(self, "save_complete.after_reopen")
        core.redraw = true
      elseif save_state.failed then
        session:end_save(false)
        notify_save_failure(save_state.error)
        core.redraw = true
      elseif save_state.saving then
        core.redraw = true
      end
    end
    return session:poll_ready_window(budget_hint)
  end
  return self:raw_poll_ready_window(budget_hint)
end

function WlPtDoc:is_dirty()
  local session = get_session(self)
  if session and session:is_dirty() then
    return true
  end
  return WlPtDoc.super.is_dirty(self)
end

function WlPtDoc:save(filename, abs_filename)
  if self.binary_mode then
    notify_binary_readonly(self)
    error("Binary hex view is read-only.")
  end

  local session = get_session(self)
  if not session then
    return WlPtDoc.super.save(self, filename, abs_filename)
  end
  if self.loading or self.loading_error then
    error("Cannot save while document is loading or failed to load")
  end
  if session:is_save_in_progress() then
    error("WL-PT save already in progress")
  end
  if not filename then
    assert(self.filename, "no filename set to default to")
    filename = self.filename
    abs_filename = self.abs_filename
  else
    assert(self.filename or abs_filename, "calling save on unnamed doc without absolute path")
  end

  local file_info = abs_filename and system.get_file_info(abs_filename)
  if file_info and file_info.type == "file" and file_info.readonly then
    error("Target file is read-only. Use Save As or clear the read-only attribute.")
  end

  session:begin_save()
  local save_task, err = session:export_save_snapshot(filename, abs_filename)
  if not save_task then
    session:end_save(false)
    error(err or "WL-PT save snapshot export failed")
  end
  local ok, save_err = self.backend and self.backend.begin_save and self.backend:begin_save(save_task)
  if not ok then
    session:end_save(false)
    error(save_err or "WL-PT native save backend unavailable")
  end
  session:set_pending_save_target(filename, abs_filename)
  core.redraw = true
end

function WlPtDoc:insert(line, col, text)
  if self.binary_mode then
    notify_binary_readonly(self)
    return false
  end
  if self.loading or self.loading_error or self.wlpt_session:is_save_in_progress() then
    return false
  end
  self._ime_composition_selection = nil
  local result = self.wlpt_session:replace_range(line, col, line, col, text, {
    record_undo = true,
    selection_before = self.selections,
  })
  invalidate_chunk_highlight(self, result.line1)
  self:on_text_change("insert")
  self:set_selection(result.line2, result.col2, result.line2, result.col2)
  core.redraw = true
  return true
end

function WlPtDoc:remove(line1, col1, line2, col2)
  if self.binary_mode then
    notify_binary_readonly(self)
    return false
  end
  if self.loading or self.loading_error or self.wlpt_session:is_save_in_progress() then
    return false
  end
  self._ime_composition_selection = nil
  local result = self.wlpt_session:replace_range(line1, col1, line2, col2, "", {
    record_undo = true,
    selection_before = self.selections,
  })
  invalidate_chunk_highlight(self, result.line1)
  self:on_text_change("remove")
  self:set_selection(result.line1, result.col1, result.line1, result.col1)
  core.redraw = true
  return true
end

function WlPtDoc:text_input(text, idx)
  if self.binary_mode then
    notify_binary_readonly(self)
    return false
  end
  if self.loading or self.loading_error or self.wlpt_session:is_save_in_progress() then
    return false
  end
  trace_selection(self, "text_input.before")
  self._ime_composition_selection = nil
  for sidx, line1, col1, line2, col2 in self:get_selections(true, idx or true) do
    if self.overwrite
      and line1 == line2 and col1 == col2
      and self:get_line_length(line1) > col1
      and text:ulen() == 1
    then
      local next_line, next_col = translate.next_char(self, line1, col1)
      local result = self.wlpt_session:replace_range(line1, col1, next_line, next_col, text, {
        record_undo = true,
        selection_before = self.selections,
      })
      invalidate_chunk_highlight(self, result.line1)
      self:set_selections(sidx, line1, col1 + #text, line1, col1 + #text)
    else
      local result = self.wlpt_session:replace_range(line1, col1, line2, col2, text, {
        record_undo = true,
        selection_before = self.selections,
      })
      invalidate_chunk_highlight(self, result.line1)
      self:set_selections(sidx, result.line2, result.col2, result.line2, result.col2)
    end
  end
  self:merge_cursors(idx)
  self:on_text_change("insert")
  trace_selection(self, "text_input.after")
  core.redraw = true
  return true
end

function WlPtDoc:ime_text_editing(text, start, length, idx)
  if self.binary_mode then
    notify_binary_readonly(self)
    return false
  end
  if self.loading or self.loading_error or self.wlpt_session:is_save_in_progress() then
    return false
  end
  wlpt_trace(
    "[DEBUG-wlpt-selection] ime_text_editing.begin file=%s text_len=%s start=%s length=%s",
    tostring(self.abs_filename or self.filename),
    tostring(#(text or "")),
    tostring(start),
    tostring(length)
  )
  trace_selection(self, "ime_text_editing.before")
  local composition = self._ime_composition_selection
  if composition then
    self.selections = copy_array(composition)
    self.last_selection = 1
    trace_selection(self, "ime_text_editing.restore_saved")
  end
  for sidx, line1, col1, line2, col2 in self:get_selections(true, idx or true) do
    local result = self.wlpt_session:replace_range(line1, col1, line2, col2, text, {
      record_undo = true,
      selection_before = self.selections,
    })
    invalidate_chunk_highlight(self, result.line1)
    self:set_selections(sidx, result.line2, result.col2, line1, col1)
    trace_selection(self, "ime_text_editing.after_set_selection")
  end
  self._ime_composition_selection = #text > 0 and copy_array(self.selections) or nil
  self:merge_cursors(idx)
  self:on_text_change("insert")
  trace_selection(self, "ime_text_editing.after")
  core.redraw = true
  return true
end

function WlPtDoc:undo()
  if self.binary_mode then
    notify_binary_readonly(self)
    return false
  end
  if self.loading or self.loading_error or self.wlpt_session:is_save_in_progress() then
    return false
  end
  self._ime_composition_selection = nil
  local result = self.wlpt_session:undo()
  if result then
    invalidate_chunk_highlight(self, result.line1)
    self:on_text_change("undo")
    core.redraw = true
    return true
  end
  return false
end

function WlPtDoc:redo()
  if self.binary_mode then
    notify_binary_readonly(self)
    return false
  end
  if self.loading or self.loading_error or self.wlpt_session:is_save_in_progress() then
    return false
  end
  self._ime_composition_selection = nil
  local result = self.wlpt_session:redo()
  if result then
    invalidate_chunk_highlight(self, result.line1)
    self:on_text_change("redo")
    core.redraw = true
    return true
  end
  return false
end

function WlPtDoc:on_close()
  local session = self.wlpt_session
  local save_state = session and session.get_save_state and session:get_save_state() or nil
  wlpt_trace(
    "[DEBUG-wlpt-save-cancel] doc.close.begin file=%s session=%s save_in_progress=%s backend_cancel_save=%s progress=%s/%s snapshot_base=%s",
    tostring(self.abs_filename or self.filename),
    tostring(session and session.id),
    tostring(session and session.is_save_in_progress and session:is_save_in_progress()),
    tostring(self.backend and self.backend.cancel_save ~= nil),
    tostring(save_state and save_state.progress_bytes),
    tostring(save_state and save_state.total_bytes),
    tostring(session and session.get_save_snapshot_base_path and session:get_save_snapshot_base_path())
  )
  if session then
    session:close()
    self.wlpt_session = nil
  end
  WlPtDoc.super.on_close(self)
  wlpt_trace(
    "[DEBUG-wlpt-save-cancel] doc.close.done file=%s session=%s",
    tostring(self.abs_filename or self.filename),
    tostring(session and session.id)
  )
end

return WlPtDoc
