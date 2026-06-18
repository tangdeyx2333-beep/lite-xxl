local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local search = require "core.doc.search"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local StatusView = require "core.statusview"

local last_view, last_fn, last_text, last_sel
core.find_replace_largefile = core.find_replace_largefile or { visible = false }
core.find_replace_status = core.find_replace_status or {
  total_matches = 0,
  current_index = 0,
  is_large_file = false,
  chunk_start = nil,
  chunk_end = nil,
  chunk_match_count = 0,
}

local case_sensitive = config.find_case_sensitive or false
local find_regex = config.find_regex or false
local found_expression
local run_largefile_chunk_search
local get_search_scope
local insert_unique
local chunk_key_repeat_state = {
  direction = nil,
  initial_at = 0,
  repeat_ready_at = 0,
  last_repeat_at = 0,
}
local chunk_key_repeat_delay = 0.35
local chunk_key_repeat_interval = 0.5
local chunk_key_repeat_min_interval = 0.18
local chunk_key_repeat_ramp_duration = 1.6

local function largefile_find_trace(...) end

local function get_doc_trace_name(target_doc)
  if not target_doc then
    return "<nil-doc>"
  end
  return tostring(target_doc.abs_filename or target_doc.filename or "<unsaved>")
end

local function doc()
  local is_DocView = core.active_view:is(DocView) and not core.active_view:is(CommandView)
  return is_DocView and core.active_view.doc or (last_view and last_view.doc)
end

local function clear_largefile_nav()
  core.find_replace_largefile = { visible = false }
end

local function center_found_match(view, line1, col1, line2, col2)
  if not view then
    return
  end

  view:scroll_to_line(line2, true)
  view:scroll_to_make_visible(line1, col1)

  local _, _, scroll_w = view.v_scrollbar:get_track_rect()
  local size_x = math.max(0, view.size.x - scroll_w)
  if size_x <= 0 then
    return
  end

  local gw = view:get_gutter_width()
  local x1 = view:get_col_x_offset(line1, col1)
  local x2 = view:get_col_x_offset(line2, col2)
  local target_x = math.max(x1, x2)
  view.scroll.to.x = math.max(0, target_x + gw - size_x / 2)
end

local function set_active_find_match(target_doc, line1, col1, line2, col2)
  if not target_doc then
    core.active_find_match = nil
    return
  end
  core.active_find_match = {
    doc = target_doc,
    line1 = line1,
    col1 = col1,
    line2 = line2,
    col2 = col2,
  }
  largefile_find_trace(
    target_doc,
    "find.active_match file=%s line1=%s col1=%s line2=%s col2=%s",
    tostring(target_doc.abs_filename or target_doc.filename),
    tostring(line1),
    tostring(col1),
    tostring(line2),
    tostring(col2)
  )
end

local function reset_find_status(target_doc)
  core.find_replace_status = {
    total_matches = 0,
    current_index = 0,
    is_large_file = target_doc and target_doc.is_large_file or false,
    chunk_start = nil,
    chunk_end = nil,
    chunk_match_count = 0,
  }
  core.active_find_match = nil
end

local function get_largefile_chunk_range(target_doc, anchor_line)
  if not target_doc or not target_doc.is_large_file then
    return nil
  end
  local line = math.max(1, math.min(target_doc:line_count(), anchor_line or 1))
  local start_line = target_doc.get_chunk_start_for_line and target_doc:get_chunk_start_for_line(line) or line
  local end_line = target_doc.get_chunk_end_for_start and target_doc:get_chunk_end_for_start(start_line) or line
  return start_line, math.min(end_line, target_doc:line_count())
end

local function count_matches_in_chunk(target_doc, text)
  if not target_doc or not target_doc.is_large_file or not text or text == "" then
    return 0
  end
  local line1, col1, line2, col2 = target_doc:get_selection(true)
  local anchor_line = math.min(line1, line2)
  local start_line, end_line = get_largefile_chunk_range(target_doc, anchor_line)
  if not start_line or not end_line then
    largefile_find_trace(
      target_doc,
      "find.chunk_count.skip file=%s anchor=%s reason=no-range text=%q",
      tostring(target_doc.abs_filename or target_doc.filename),
      tostring(anchor_line),
      tostring(text):gsub("\n", "\\n"):sub(1, 120)
    )
    return 0
  end

  largefile_find_trace(
    target_doc,
    "find.chunk_count.begin file=%s selection=%d:%d-%d:%d anchor=%d chunk=%d-%d text=%q",
    tostring(target_doc.abs_filename or target_doc.filename),
    line1,
    col1,
    line2,
    col2,
    anchor_line,
    start_line,
    end_line,
    tostring(text):gsub("\n", "\\n"):sub(1, 120)
  )

  local count = 0
  local search_line, search_col = start_line, 1
  while true do
    local match_line1, match_col1, match_line2, match_col2 = search.find(target_doc, search_line, search_col, text, {
      wrap = false,
      no_case = not case_sensitive,
      regex = find_regex,
      reverse = false,
      limit_start_line = start_line,
      limit_end_line = end_line,
    })
    if not match_line1 then
      largefile_find_trace(
        target_doc,
        "find.chunk_count.stop file=%s next_search=%d:%d count=%d",
        tostring(target_doc.abs_filename or target_doc.filename),
        search_line,
        search_col,
        count
      )
      break
    end
    count = count + 1
    largefile_find_trace(
      target_doc,
      "find.chunk_count.hit file=%s count=%d match=%d:%d-%d:%d",
      tostring(target_doc.abs_filename or target_doc.filename),
      count,
      match_line1,
      match_col1,
      match_line2,
      match_col2
    )
    search_line = match_line2
    search_col = match_col2
    if search_line > end_line then
      largefile_find_trace(
        target_doc,
        "find.chunk_count.end file=%s next_search=%d:%d count=%d reason=passed-end",
        tostring(target_doc.abs_filename or target_doc.filename),
        search_line,
        search_col,
        count
      )
      break
    end
  end
  return count
end

local function get_current_match_position(target_doc, text, match_line, match_col)
  if not target_doc or not text or text == "" or not match_line or not match_col then
    return 0
  end
  local start_line, end_line
  if target_doc.is_large_file then
    start_line, end_line = get_largefile_chunk_range(target_doc, match_line)
  else
    start_line, end_line = 1, target_doc:line_count()
  end
  local count = 0
  local search_line, search_col = start_line, 1
  while true do
    local line1, col1, line2, col2 = search.find(target_doc, search_line, search_col, text, {
      wrap = false,
      no_case = not case_sensitive,
      regex = find_regex,
      reverse = false,
      limit_start_line = start_line,
      limit_end_line = end_line,
    })
    if not line1 then
      break
    end
    count = count + 1
    if line1 == match_line and col1 == match_col then
      return count
    end
    search_line, search_col = line2, col2
    if search_line > end_line then
      break
    end
  end
  return 0
end

local function set_largefile_nav(target_doc, text, anchor_line)
  local chunk_start, chunk_end = get_largefile_chunk_range(target_doc, anchor_line)
  if not chunk_start then
    clear_largefile_nav()
    return
  end
  core.find_replace_largefile = {
    visible = true,
    doc = target_doc,
    text = text,
    chunk_start = chunk_start,
    chunk_end = chunk_end,
  }
end

local function show_largefile_scope_message(target_doc, text, anchor_line, found)
  set_largefile_nav(target_doc, text, anchor_line)
  local state = core.find_replace_largefile
  if not state.visible then
    return
  end
  state.match_count = count_matches_in_chunk(target_doc, text)
  core.find_replace_status.is_large_file = true
  core.find_replace_status.chunk_start = state.chunk_start
  core.find_replace_status.chunk_end = state.chunk_end
  core.find_replace_status.chunk_match_count = state.match_count or 0
  if not found then
    core.find_replace_status.total_matches = 0
    core.find_replace_status.current_index = 0
  end
  largefile_find_trace(
    target_doc,
    "find.chunk_state file=%s chunk=%d-%d found=%s count=%d text=%q",
    tostring(target_doc.abs_filename or target_doc.filename),
    state.chunk_start or -1,
    state.chunk_end or -1,
    tostring(found),
    state.match_count or 0,
    tostring(text):gsub("\n", "\\n"):sub(1, 120)
  )
  local message
  if found then
    message = string.format(
      "Large file search is limited to chunk %d-%d. Use Prev Chunk / Next Chunk to continue.",
      state.chunk_start,
      state.chunk_end
    )
  else
    message = string.format(
      "No match in current chunk %d-%d. Use Prev Chunk / Next Chunk to switch chunks.",
      state.chunk_start,
      state.chunk_end
    )
  end
  core.status_view:show_message("info", message)
end

local function log_match_summary(target_doc, text, line1, col1)
  local total_matches = 0
  local current_index = 0
  local scope_start, scope_end = get_search_scope(target_doc, line1 or 1)
  if target_doc and text and text ~= "" then
    local search_line, search_col = 1, 1
    while true do
      local l1, c1, l2, c2 = search.find(target_doc, search_line, search_col, text, {
        wrap = false,
        no_case = not case_sensitive,
        regex = find_regex,
        reverse = false,
        limit_start_line = scope_start,
        limit_end_line = scope_end,
      })
      if not l1 then break end
      total_matches = total_matches + 1
      search_line, search_col = l2, c2
      if search_line > scope_end then break end
    end
  end
  current_index = get_current_match_position(target_doc, text, line1, col1)
  core.find_replace_status.total_matches = total_matches
  core.find_replace_status.current_index = current_index
  core.find_replace_status.is_large_file = target_doc and target_doc.is_large_file or false
  core.find_replace_status.chunk_start = core.find_replace_status.is_large_file and scope_start or nil
  core.find_replace_status.chunk_end = core.find_replace_status.is_large_file and scope_end or nil
  core.find_replace_status.chunk_match_count = core.find_replace_status.is_large_file and total_matches or 0
  largefile_find_trace(
    target_doc,
    "find.summary file=%s is_large=%s scope=%s-%s total=%d current=%d text=%q match=%s:%s",
    tostring(target_doc and (target_doc.abs_filename or target_doc.filename)),
    tostring(target_doc and target_doc.is_large_file),
    tostring(scope_start),
    tostring(scope_end),
    total_matches,
    current_index,
    tostring(text):gsub("\n", "\\n"):sub(1, 120),
    tostring(line1),
    tostring(col1)
  )
end

function get_search_scope(target_doc, line)
  if not target_doc then
    return 1, 1
  end
  if target_doc.is_large_file then
    return get_largefile_chunk_range(target_doc, line)
  end
  return 1, target_doc:line_count()
end

local function scoped_search_fn(target_doc, line, col, text, case_sensitive, find_regex, find_reverse)
  local start_line, end_line = get_search_scope(target_doc, line)
  largefile_find_trace(
    target_doc,
    "find.chunk_scope file=%s line=%d col=%d reverse=%s chunk=%d-%d text=%q",
    tostring(target_doc and (target_doc.abs_filename or target_doc.filename)),
    line,
    col,
    tostring(find_reverse),
    start_line or -1,
    end_line or -1,
    tostring(text):gsub("\n", "\\n"):sub(1, 120)
  )
  return search.find(target_doc, line, col, text, {
    wrap = false,
    no_case = not case_sensitive,
    regex = find_regex,
    reverse = find_reverse,
    limit_start_line = start_line,
    limit_end_line = end_line,
  })
end

local function chunk_wrapped_search_fn(target_doc, line, col, text, case_sensitive, find_regex, find_reverse)
  local start_line, end_line = get_search_scope(target_doc, line)
  local line1, col1, line2, col2 = search.find(target_doc, line, col, text, {
    wrap = false,
    no_case = not case_sensitive,
    regex = find_regex,
    reverse = find_reverse,
    limit_start_line = start_line,
    limit_end_line = end_line,
  })
  if line1 then
    return line1, col1, line2, col2
  end

  local wrap_line = find_reverse and end_line or start_line
  local wrap_col = find_reverse and target_doc:get_line_length(wrap_line) or 1
  largefile_find_trace(
    target_doc,
    "find.chunk_scope_wrap file=%s start=%d:%d wrap_to=%d:%d reverse=%s chunk=%d-%d text=%q",
    tostring(target_doc.abs_filename or target_doc.filename),
    line,
    col,
    wrap_line,
    wrap_col,
    tostring(find_reverse),
    start_line or -1,
    end_line or -1,
    tostring(text):gsub("\n", "\\n"):sub(1, 120)
  )
  return search.find(target_doc, wrap_line, wrap_col, text, {
    wrap = false,
    no_case = not case_sensitive,
    regex = find_regex,
    reverse = find_reverse,
    limit_start_line = start_line,
    limit_end_line = end_line,
  })
end

local function execute_find_action(target_view, text, reverse)
  if not target_view or not target_view.doc or not text or text == "" then
    return false
  end

  insert_unique(core.previous_find, text)
  local current_doc = target_view.doc
  local sl1, sc1, sl2, sc2 = current_doc:get_selection(true)
  local line1, col1, line2, col2
  if reverse then
    line1, col1, line2, col2 = chunk_wrapped_search_fn(current_doc, sl1, sc1, text, case_sensitive, find_regex, true)
  else
    line1, col1, line2, col2 = chunk_wrapped_search_fn(current_doc, sl2, sc2, text, case_sensitive, find_regex, false)
  end

  if line1 then
    -- 中文说明：Find / Enter / F3 找到下一处后，也只保留 find 命中语义，
    -- 不再把命中文本同时设为普通选区，避免再次进入“选区 + find”的重叠态。
    current_doc:set_selection(line2, col2, line2, col2)
    center_found_match(target_view, line1, col1, line2, col2)
    set_active_find_match(current_doc, line1, col1, line2, col2)
    log_match_summary(current_doc, text, line1, col1)
    if current_doc.is_large_file then
      show_largefile_scope_message(current_doc, text, line1, true)
    end
    last_text = text
    return true
  end

  if current_doc.is_large_file then
    show_largefile_scope_message(current_doc, text, reverse and sl1 or sl2, false)
  else
    core.active_find_match = nil
    core.error("Couldn't find %q", text)
  end
  last_text = text
  return false
end

local function get_find_tooltip()
  local rf = keymap.get_binding("find-replace:repeat-find")
  local ti = keymap.get_binding("find-replace:toggle-sensitivity")
  local tr = keymap.get_binding("find-replace:toggle-regex")
  return (find_regex and "[Regex] " or "") ..
    (case_sensitive and "[Sensitive] " or "") ..
    (rf and ("Press " .. rf .. " to select the next match.") or "") ..
    (ti and (" " .. ti .. " toggles case sensitivity.") or "") ..
    (tr and (" " .. tr .. " toggles regex find.") or "")
end

local function selection_is_nonempty(sel)
  return sel
    and sel[1] and sel[2] and sel[3] and sel[4]
    and (sel[1] ~= sel[3] or sel[2] ~= sel[4])
end

local function activate_selection_as_find_match(target_view, sel, text)
  if not target_view or not target_view.doc or not selection_is_nonempty(sel) or not text or text == "" then
    return false
  end

  local target_doc = target_view.doc
  local line1, col1, line2, col2 = table.unpack(sel)

  largefile_find_trace(
    target_doc,
    "find.seed_as_match file=%s match=%d:%d-%d:%d text=%q",
    tostring(target_doc.abs_filename or target_doc.filename),
    line1,
    col1,
    line2,
    col2,
    tostring(text):gsub("\n", "\\n"):sub(1, 120)
  )

  -- 中文说明：Ctrl+F 初次打开时，当前文档选区直接升级为当前 find 命中，
  -- 不再继续保留为普通非空选区，也不先走“查找下一个”的预览链。
  target_doc:set_selection(line2, col2, line2, col2)
  center_found_match(target_view, line1, col1, line2, col2)
  set_active_find_match(target_doc, line1, col1, line2, col2)
  found_expression = true

  local ok = pcall(log_match_summary, target_doc, text, line1, col1)
  if not ok then
    core.find_replace_status.total_matches = 0
    core.find_replace_status.current_index = 0
    core.find_replace_status.is_large_file = target_doc.is_large_file or false
    core.find_replace_status.chunk_start = nil
    core.find_replace_status.chunk_end = nil
    core.find_replace_status.chunk_match_count = 0
  end

  if target_doc.is_large_file then
    pcall(show_largefile_scope_message, target_doc, text, line1, true)
  else
    clear_largefile_nav()
  end

  return true
end

local function update_preview(sel, search_fn, text)
  largefile_find_trace(
    last_view and last_view.doc,
    "find.preview.begin file=%s selection=%s,%s,%s,%s text=%q",
    tostring(last_view and last_view.doc and (last_view.doc.abs_filename or last_view.doc.filename)),
    tostring(sel[1]),
    tostring(sel[2]),
    tostring(sel[3]),
    tostring(sel[4]),
    tostring(text):gsub("\n", "\\n"):sub(1, 120)
  )
  local ok, line1, col1, line2, col2 = pcall(search_fn, last_view.doc,
    sel[1], sel[2], text, case_sensitive, find_regex)
  if ok and line1 and text ~= "" then
    largefile_find_trace(
      last_view.doc,
      "find.preview.result file=%s ok=%s line1=%s col1=%s line2=%s col2=%s",
      tostring(last_view.doc.abs_filename or last_view.doc.filename),
      tostring(ok),
      tostring(line1),
      tostring(col1),
      tostring(line2),
      tostring(col2)
    )
    -- 中文说明：当 Ctrl+F 由当前选区直接进入 find 时，
    -- 这段文本此后应升级为“find 命中”，不再继续保留为普通非空选区，
    -- 否则渲染层会把它同时当成普通选区和 find 命中，落入重叠态。
    last_view.doc:set_selection(line2, col2, line2, col2)
    center_found_match(last_view, line1, col1, line2, col2)
    set_active_find_match(last_view.doc, line1, col1, line2, col2)
    found_expression = true
    log_match_summary(last_view.doc, text, line1, col1)
    if last_view.doc.is_large_file then
      show_largefile_scope_message(last_view.doc, text, line1, true)
    else
      clear_largefile_nav()
    end
    largefile_find_trace(
      last_view.doc,
      "find.preview.hit file=%s match=%d:%d-%d:%d",
      tostring(last_view.doc.abs_filename or last_view.doc.filename),
      line1,
      col1,
      line2,
      col2
    )
  else
    largefile_find_trace(
      last_view and last_view.doc,
      "find.preview.result file=%s ok=%s line1=%s col1=%s line2=%s col2=%s",
      tostring(last_view and last_view.doc and (last_view.doc.abs_filename or last_view.doc.filename)),
      tostring(ok),
      tostring(line1),
      tostring(col1),
      tostring(line2),
      tostring(col2)
    )
    -- 中文说明：未命中时恢复到打开 find 前的原始文档选区，
    -- 这样用户还能看到自己最初拿来查找的那段内容。
    last_view.doc:set_selection(table.unpack(sel))
    core.active_find_match = nil
    found_expression = false
    if last_view and last_view.doc and last_view.doc.is_large_file and text ~= "" then
      show_largefile_scope_message(last_view.doc, text, sel[1], false)
    else
      clear_largefile_nav()
    end
    largefile_find_trace(
      last_view and last_view.doc,
      "find.preview.miss file=%s ok=%s text_empty=%s",
      tostring(last_view and last_view.doc and (last_view.doc.abs_filename or last_view.doc.filename)),
      tostring(ok),
      tostring(text == "")
    )
  end
end


function insert_unique(t, v)
  local n = #t
  for i = 1, n do
    if t[i] == v then
      table.remove(t, i)
      break
    end
  end
  table.insert(t, 1, v)
end

local function find(label, search_fn)
  last_view, last_sel = core.active_view,
    { core.active_view.doc:get_selection(true) }
  local text = last_view.doc:get_text(table.unpack(last_sel))
  found_expression = false
  reset_find_status(last_view.doc)
  local seed_selection_pending = selection_is_nonempty(last_sel) and text ~= ""
  local seed_text = text

  largefile_find_trace(
    last_view.doc,
    "find.open file=%s is_large=%s selection=%s,%s,%s,%s seed=%q",
    tostring(last_view.doc.abs_filename or last_view.doc.filename),
    tostring(last_view.doc.is_large_file),
    tostring(last_sel[1]),
    tostring(last_sel[2]),
    tostring(last_sel[3]),
    tostring(last_sel[4]),
    tostring(text):gsub("\n", "\\n"):sub(1, 120)
  )

  core.status_view:show_tooltip(get_find_tooltip())

  local function perform_find_action(reverse)
    local text = core.command_view:get_text()
    last_fn, last_text = search_fn, text
    execute_find_action(last_view, text, reverse)
  end

  local function close_find_bar()
    largefile_find_trace(
      last_view and last_view.doc,
      "find.button file=%s action=close",
      tostring(last_view and last_view.doc and (last_view.doc.abs_filename or last_view.doc.filename))
    )
    core.command_view:exit(false)
  end
  local find_options = {
    text = text,
    select_text = true,
    show_suggestions = false,
    -- 中文说明：find 打开后允许用户把焦点切回文档继续点击、拖选、复制、编辑，
    -- 只有 Esc 或 Close 才真正关闭 find 组件。
    keep_open_on_focus_loss = true,
    buttons = {
      {
        text = "",
        get_text = function()
          local status = core.find_replace_status or {}
          local current = status.current_index or 0
          local total = status.total_matches or 0
          if total <= 0 then
            return "0/0"
          end
          return string.format("%d/%d", current, total)
        end,
        action = function() end,
      },
      { text = "Find", action = function() perform_find_action(false) end },
      { text = "Find Prev", action = function() perform_find_action(true) end },
      {
        text = "",
        get_text = function()
          local status = core.find_replace_status or {}
          if not status.is_large_file or not status.chunk_start or not status.chunk_end then
            return ""
          end
          return string.format(
            "Chunk %d-%d (%d)",
            status.chunk_start,
            status.chunk_end,
            status.chunk_match_count or 0
          )
        end,
        visible = function()
          local status = core.find_replace_status or {}
          return status.is_large_file and status.chunk_start ~= nil and status.chunk_end ~= nil
        end,
        action = function() end,
      },
      {
        text = "Prev Chunk",
        repeat_while_pressed = true,
        repeat_delay = 0.35,
        repeat_interval = 0.5,
        repeat_min_interval = 0.18,
        repeat_ramp_duration = 1.6,
        visible = function()
          local status = core.find_replace_status or {}
          return status.is_large_file == true
        end,
        action = function()
          if last_view and last_view.doc.is_large_file then
            run_largefile_chunk_search(last_view, -1)
          end
        end
      },
      {
        text = "Next Chunk",
        repeat_while_pressed = true,
        repeat_delay = 0.35,
        repeat_interval = 0.5,
        repeat_min_interval = 0.18,
        repeat_ramp_duration = 1.6,
        visible = function()
          local status = core.find_replace_status or {}
          return status.is_large_file == true
        end,
        action = function()
          if last_view and last_view.doc.is_large_file then
            run_largefile_chunk_search(last_view, 1)
          end
        end
      },
      { text = "Close", action = close_find_bar },
    },
    submit = function(text, item)
      insert_unique(core.previous_find, text)
      core.status_view:remove_tooltip()
      largefile_find_trace(
        last_view.doc,
        "find.submit file=%s found_expression=%s text=%q",
        tostring(last_view.doc.abs_filename or last_view.doc.filename),
        tostring(found_expression),
        tostring(text):gsub("\n", "\\n"):sub(1, 120)
      )
      if found_expression then
        last_fn, last_text = search_fn, text
      else
        clear_largefile_nav()
        core.error("Couldn't find %q", text)
        last_view.doc:set_selection(table.unpack(last_sel))
        last_view:scroll_to_make_visible(table.unpack(last_sel))
      end
    end,
    suggest = function(text)
      if seed_selection_pending and text == seed_text then
        last_fn, last_text = search_fn, text
        return core.previous_find
      end
      seed_selection_pending = false
      update_preview(last_sel, search_fn, text)
      last_fn, last_text = search_fn, text
      return core.previous_find
    end,
    cancel = function(explicit)
      -- 中文说明：Esc 与 Close 都只负责退出 find 并清理 find 状态，
      -- 不再回滚到打开 find 前保存的 last_sel 原始选区。
      largefile_find_trace(
        last_view and last_view.doc,
        "find.cancel file=%s explicit=%s active_view=%s",
        tostring(last_view and last_view.doc and (last_view.doc.abs_filename or last_view.doc.filename)),
        tostring(explicit),
        tostring(core.active_view)
      )
      core.status_view:remove_tooltip()
      clear_largefile_nav()
      reset_find_status(last_view and last_view.doc)
    end
  }

  if core.command_view:is_persistent_open() and tostring(core.command_view.label or ""):match("^Find") then
    -- 中文说明：当 find 已经打开时，再次按 Ctrl+F 不新开第二个命令栏，
    -- 而是复用同一个输入栏，并用当前选区重新填充搜索词。
    largefile_find_trace(
      last_view.doc,
      "find.reopen file=%s selection=%s,%s,%s,%s seed=%q",
      tostring(last_view.doc.abs_filename or last_view.doc.filename),
      tostring(last_sel[1]),
      tostring(last_sel[2]),
      tostring(last_sel[3]),
      tostring(last_sel[4]),
      tostring(text):gsub("\n", "\\n"):sub(1, 120)
    )
    core.command_view.state = common.merge(core.command_view.state, find_options)
    core.command_view.label = label .. ": "
    core.command_view:set_text(text, true)
    core.command_view:update_suggestions()
    core.command_view.gutter_text_brightness = 100
    core.set_active_view(core.command_view)
    if seed_selection_pending then
      seed_selection_pending = false
      activate_selection_as_find_match(last_view, last_sel, seed_text)
    end
    return
  end

  core.command_view:enter(label, find_options)
  if seed_selection_pending then
    seed_selection_pending = false
    activate_selection_as_find_match(last_view, last_sel, seed_text)
  end
end

function run_largefile_chunk_search(dv, direction)
  if not last_text or last_text == "" then
    core.error("No find to continue from")
    return
  end
  if not dv or not dv.doc or not dv.doc.is_large_file then
    core.error("Chunk navigation is only available for large files")
    return
  end
  local target_doc = dv.doc
  local line1, col1, line2, col2 = target_doc:get_selection(true)
  local anchor_line = direction > 0 and line2 or line1
  local chunk_size = math.max(1, target_doc.chunk_line_count or 256)
  local current_start = target_doc:get_chunk_start_for_line(anchor_line)
  local next_start = current_start + direction * chunk_size
  largefile_find_trace(
    target_doc,
    "find.chunk_nav file=%s direction=%d anchor=%d current_start=%d chunk_size=%d next_start=%d line_count=%d",
    tostring(target_doc.abs_filename or target_doc.filename),
    direction,
    anchor_line,
    current_start,
    chunk_size,
    next_start,
    target_doc:line_count()
  )
  if next_start < 1 or next_start > target_doc:line_count() then
    largefile_find_trace(
      target_doc,
      "find.chunk_nav_blocked file=%s reason=out-of-range next_start=%d",
      tostring(target_doc.abs_filename or target_doc.filename),
      next_start
    )
    core.error("No more chunks in that direction")
    return
  end
  local next_end = math.min(target_doc:get_chunk_end_for_start(next_start), target_doc:line_count())
  largefile_find_trace(
    target_doc,
    "find.chunk_nav_target file=%s next_chunk=%d-%d",
    tostring(target_doc.abs_filename or target_doc.filename),
    next_start,
    next_end
  )
  target_doc:request_visible_window(next_start, next_end, 0)
  target_doc:poll_ready_window(0)
  local search_line = direction > 0 and next_start or next_end
  local search_col = direction > 0 and 1 or target_doc:get_line_length(search_line)
  target_doc:set_selection(search_line, search_col, search_line, search_col)
  dv:scroll_to_line(search_line, true)
  local match_line1, match_col1, match_line2, match_col2 =
    chunk_wrapped_search_fn(target_doc, search_line, search_col, last_text, case_sensitive, find_regex, direction < 0)
  if match_line1 then
    largefile_find_trace(
      target_doc,
      "find.chunk_nav_hit file=%s match=%d:%d-%d:%d",
      tostring(target_doc.abs_filename or target_doc.filename),
      match_line1,
      match_col1,
      match_line2,
      match_col2
    )
    target_doc:set_selection(match_line2, match_col2, match_line1, match_col1)
    center_found_match(dv, match_line1, match_col1, match_line2, match_col2)
    set_active_find_match(target_doc, match_line1, match_col1, match_line2, match_col2)
    log_match_summary(target_doc, last_text, match_line1, match_col1)
    show_largefile_scope_message(target_doc, last_text, match_line1, true)
  else
    largefile_find_trace(
      target_doc,
      "find.chunk_nav_miss file=%s search_pos=%d:%d target_chunk=%d-%d",
      tostring(target_doc.abs_filename or target_doc.filename),
      search_line,
      search_col,
      next_start,
      next_end
    )
    target_doc:set_selection(search_line, search_col, search_line, search_col)
    dv:scroll_to_line(search_line, true)
    core.active_find_match = nil
    show_largefile_scope_message(target_doc, last_text, search_line, false)
  end
end


local function replace(kind, default, fn)
  core.status_view:show_tooltip(get_find_tooltip())
  core.command_view:enter("Find To Replace " .. kind, {
    text = default,
    select_text = true,
    show_suggestions = false,
    submit = function(old)
      insert_unique(core.previous_find, old)

      local s = string.format("Replace %s %q With", kind, old)
      core.command_view:enter(s, {
        text = old,
        select_text = true,
        show_suggestions = false,
        submit = function(new)
          core.status_view:remove_tooltip()
          insert_unique(core.previous_replace, new)
          local results = doc():replace(function(text)
            return fn(text, old, new)
          end)
          local n = 0
          for _,v in pairs(results) do
            n = n + v
          end
          core.log("Replaced %d instance(s) of %s %q with %q", n, kind, old, new)
        end,
        suggest = function() return core.previous_replace end,
        cancel = function()
          core.status_view:remove_tooltip()
        end
      })
    end,
    suggest = function() return core.previous_find end,
    cancel = function()
      core.status_view:remove_tooltip()
    end
  })
end

local function has_selection()
  return core.active_view:is(DocView) and core.active_view.doc:has_selection()
end

local function has_unique_selection()
  if not doc() then return false end
  local text = nil
  for idx, line1, col1, line2, col2 in doc():get_selections(true, true) do
    if line1 == line2 and col1 == col2 then return false end
    local selection = doc():get_text(line1, col1, line2, col2)
    if text ~= nil and text ~= selection then return false end
    text = selection
  end
  return text ~= nil
end

local function is_in_selection(line, col, l1, c1, l2, c2)
  if line < l1 or line > l2 then return false end
  if line == l1 and col <= c1 then return false end
  if line == l2 and col > c2 then return false end
  return true
end

local function is_in_any_selection(line, col)
  for idx, l1, c1, l2, c2 in doc():get_selections(true, false) do
    if is_in_selection(line, col, l1, c1, l2, c2) then return true end
  end
  return false
end

local function select_add_next(all)
  local il1, ic1
  for _, l1, c1, l2, c2 in doc():get_selections(true, true) do
    if not il1 then
      il1, ic1 = l1, c1
    end
    local text = doc():get_text(l1, c1, l2, c2)
    repeat
      l1, c1, l2, c2 = search.find(doc(), l2, c2, text, { wrap = true })
      if l1 == il1 and c1 == ic1 then break end
      if l2 and not is_in_any_selection(l2, c2) then
        doc():add_selection(l2, c2, l1, c1)
        if not all then
          core.active_view:scroll_to_make_visible(l2, c2)
          return
        end
      end
    until not all or not l2
    if all then break end
  end
end

local function select_next(reverse)
  local l1, c1, l2, c2 = doc():get_selection(true)
  local text = doc():get_text(l1, c1, l2, c2)
  if reverse then
    l1, c1, l2, c2 = search.find(doc(), l1, c1, text, { wrap = true, reverse = true })
  else
    l1, c1, l2, c2 = search.find(doc(), l2, c2, text, { wrap = true })
  end
  if l2 then doc():set_selection(l2, c2, l1, c1) end
end

---@param in_selection? boolean whether to replace in the selections only, or in the whole file.
local function find_replace(in_selection)
  local l1, c1, l2, c2 = doc():get_selection()
  local selected_text = ""
  if not in_selection then
    selected_text = doc():get_text(l1, c1, l2, c2)
    doc():set_selection(l2, c2, l2, c2)
  end
  replace("Text", l1 == l2 and selected_text or "", function(text, old, new)
    if not find_regex then
      return text:gsub(old:gsub("%W", "%%%1"), new:gsub("%%", "%%%%"), nil)
    end
    local result, matches = regex.gsub(regex.compile(old, "m"), text, new)
    return result, matches
  end)
end

command.add(has_unique_selection, {
  ["find-replace:select-next"] = select_next,
  ["find-replace:select-previous"] = function() select_next(true) end,
  ["find-replace:select-add-next"] = select_add_next,
  ["find-replace:select-add-all"] = function() select_add_next(true) end
})

command.add("core.docview!", {
  ["find-replace:find"] = function()
    find("Find Text", scoped_search_fn)
  end,

  ["find-replace:replace"] = function()
    find_replace()
  end,

  ["find-replace:replace-in-selection"] = function()
    find_replace(true)
  end,

  ["find-replace:replace-symbol"] = function()
    local first = ""
    if doc():has_selection() then
      local text = doc():get_text(doc():get_selection())
      first = text:match(config.symbol_pattern) or ""
    end
    replace("Symbol", first, function(text, old, new)
      local n = 0
      local res = text:gsub(config.symbol_pattern, function(sym)
        if old == sym then
          n = n + 1
          return new
        end
      end)
      return res, n
    end)
  end,
})

local function valid_for_finding()
  -- Allow using this while in the CommandView
  if core.active_view:is(CommandView) and last_view then
    return true, last_view
  end
  return core.active_view:is(DocView), core.active_view
end

local function active_find_commandview()
  return core.active_view
    and core.active_view:is(CommandView)
    and last_view ~= nil
    and last_text ~= nil
    and type(core.command_view.state) == "table"
    and type(core.command_view.state.buttons) == "table"
end

local function should_run_chunk_key(direction)
  local now = system.get_time()
  if chunk_key_repeat_state.direction ~= direction
    or (now - (chunk_key_repeat_state.last_repeat_at or 0)) > 0.8 then
    chunk_key_repeat_state.direction = direction
    chunk_key_repeat_state.initial_at = now
    chunk_key_repeat_state.repeat_ready_at = now + chunk_key_repeat_delay
    chunk_key_repeat_state.last_repeat_at = now
    return true
  end

  if now < (chunk_key_repeat_state.repeat_ready_at or 0) then
    return false
  end

  local elapsed = math.max(0, now - (chunk_key_repeat_state.repeat_ready_at or now))
  local progress = math.min(1, elapsed / chunk_key_repeat_ramp_duration)
  local interval = chunk_key_repeat_interval
    - (chunk_key_repeat_interval - chunk_key_repeat_min_interval) * progress
  if now - (chunk_key_repeat_state.last_repeat_at or 0) < interval then
    return false
  end

  chunk_key_repeat_state.last_repeat_at = now
  return true
end

command.add(valid_for_finding, {
  ["find-replace:repeat-find"] = function(dv)
    if not last_fn then
      core.error("No find to continue from")
    else
      local text = active_find_commandview() and core.command_view:get_text() or last_text
      execute_find_action(dv, text, false)
    end
  end,

  ["find-replace:previous-find"] = function(dv)
    if not last_fn then
      core.error("No find to continue from")
    else
      local text = active_find_commandview() and core.command_view:get_text() or last_text
      execute_find_action(dv, text, true)
    end
  end,

  ["find-replace:large-file-prev-chunk"] = function(dv)
    run_largefile_chunk_search(dv, -1)
  end,

  ["find-replace:large-file-next-chunk"] = function(dv)
    run_largefile_chunk_search(dv, 1)
  end,
})

local function active_find_commandview_predicate(...)
  if active_find_commandview() then
    return true, core.active_view, ...
  end
  return false
end

command.add(active_find_commandview_predicate, {
  ["find-replace:commandview-next-find"] = function()
    if not active_find_commandview() then
      return false
    end
    largefile_find_trace(
      last_view and last_view.doc,
      "find.commandview action=down text=%q",
      tostring(last_text):gsub("\n", "\\n"):sub(1, 120)
    )
    return command.perform("find-replace:repeat-find")
  end,

  ["find-replace:commandview-previous-find"] = function()
    if not active_find_commandview() then
      return false
    end
    largefile_find_trace(
      last_view and last_view.doc,
      "find.commandview action=up text=%q",
      tostring(last_text):gsub("\n", "\\n"):sub(1, 120)
    )
    return command.perform("find-replace:previous-find")
  end,

  ["find-replace:commandview-prev-chunk"] = function()
    if not active_find_commandview() or not last_view or not last_view.doc or not last_view.doc.is_large_file then
      return false
    end
    if not should_run_chunk_key(-1) then
      return true
    end
    run_largefile_chunk_search(last_view, -1)
    return true
  end,

  ["find-replace:commandview-next-chunk"] = function()
    if not active_find_commandview() or not last_view or not last_view.doc or not last_view.doc.is_large_file then
      return false
    end
    if not should_run_chunk_key(1) then
      return true
    end
    run_largefile_chunk_search(last_view, 1)
    return true
  end,

  ["find-replace:toggle-sensitivity"] = function()
    case_sensitive = not case_sensitive
    core.status_view:show_tooltip(get_find_tooltip())
    if last_sel then update_preview(last_sel, last_fn, last_text) end
  end,

  ["find-replace:toggle-regex"] = function()
    find_regex = not find_regex
    core.status_view:show_tooltip(get_find_tooltip())
    if last_sel then update_preview(last_sel, last_fn, last_text) end
  end
})

keymap.add {
  ["up"] = "find-replace:commandview-previous-find",
  ["down"] = "find-replace:commandview-next-find",
  ["return"] = "find-replace:commandview-next-find",
  ["keypad enter"] = "find-replace:commandview-next-find",
  ["shift+return"] = "find-replace:commandview-previous-find",
  ["shift+keypad enter"] = "find-replace:commandview-previous-find",
  ["left"] = "find-replace:commandview-prev-chunk",
  ["right"] = "find-replace:commandview-next-chunk",
}
