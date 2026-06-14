local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local ime = require "core.ime"
local View = require "core.view"
local ContextMenu = require "core.contextmenu"
local DEBUG_LOG_PATH = USERDIR and (USERDIR .. PATHSEP .. "wlpt-debug.log") or nil

local function docview_trace(fmt, ...)
  if not DEBUG_LOG_PATH then
    return
  end
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then
    text = tostring(fmt)
  end
  local fp = io.open(DEBUG_LOG_PATH, "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " [DEBUG-wlpt-hit] ", text, "\n")
    fp:close()
  end
end

local function get_render_highlighter(doc)
  if doc and doc.is_large_file_mode and doc:is_large_file_mode()
    and not config.large_file_disable_highlight
    and doc.chunk_highlighter
  then
    return doc.chunk_highlighter
  end
  return doc and doc.highlighter or nil
end

local function get_screen_position_for_selection(self, line, col)
  -- 这里统一走“带列号的屏幕坐标”，这样软换行后的 IME 就能落到实际显示的那一段行上。
  return self:get_line_screen_position(line, col)
end

local function log_hit_test(self, stage, x, y, line, col)
  if not (self and self.doc and self.doc.is_wlpt_mode and self.doc:is_wlpt_mode()) then
    return
  end
  local chunk = self.doc.get_chunk_for_line and self.doc:get_chunk_for_line(line) or nil
  local line_text = self.doc.get_line and self.doc:get_line(line) or nil
  if type(line_text) == "string" then
    line_text = line_text:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
    if #line_text > 80 then
      line_text = line_text:sub(1, 80) .. "..."
    end
  end
  docview_trace(
    "hit.%s file=%s xy=%s,%s line=%s col=%s chunk=%s ready=%s dirty=%s anchored=%s cached=%s render=%s scroll=%s,%s text=\"%s\"",
    tostring(stage),
    tostring(self.doc.abs_filename or self.doc.filename),
    tostring(math.floor(x or 0)),
    tostring(math.floor(y or 0)),
    tostring(line),
    tostring(col),
    tostring(chunk and (tostring(chunk.start_line) .. "-" .. tostring(chunk.end_line)) or "nil"),
    tostring(chunk and chunk.highlight_ready or nil),
    tostring(chunk and chunk.highlight_dirty or nil),
    tostring(chunk and chunk.highlight_anchored or nil),
    tostring(self.doc.has_cached_line and self.doc:has_cached_line(line) or nil),
    tostring(get_render_highlighter(self.doc) and (get_render_highlighter(self.doc).is_chunk_mode and get_render_highlighter(self.doc):is_chunk_mode() and "chunk" or "line") or "nil"),
    tostring(self.scroll and self.scroll.x),
    tostring(self.scroll and self.scroll.y),
    tostring(line_text)
  )
end

---@class core.docview : core.view
---@field super core.view
local DocView = View:extend()

function DocView:__tostring() return "DocView" end

local function find_scroll_trace(...) end

function DocView:draw_find_match_overlay(line, x, y)
  local line1, col1, line2, col2
  local active_find_match = core.active_find_match
  if active_find_match and active_find_match.doc == self.doc then
    line1, col1, line2, col2 = active_find_match.line1, active_find_match.col1, active_find_match.line2, active_find_match.col2
  elseif active_find_match and not self:is(require "core.commandview") and self.doc and self.doc.get_selection then
    line1, col1, line2, col2 = self.doc:get_selection(true)
  end

  if not line1 or line < line1 or line > line2 then
    return
  end
  local text = self.doc:get_line(line)
  local lh = self:get_line_height()

  if line1 ~= line then col1 = 1 end
  if line2 ~= line then col2 = #text + 1 end

  local x1 = x + self:get_col_x_offset(line, col1)
  local x2 = x + self:get_col_x_offset(line, col2)
  if x1 == x2 then
    return
  end

  renderer.draw_rect(x1, y + 1, x2 - x1, math.max(1, lh - 2), style.find_match or { 0xFF, 0x8C, 0x00, 0xFF })
  local match_text = text:sub(col1, math.max(col1, col2 - 1))
  if match_text ~= "" then
    renderer.draw_text(
      self:get_font(),
      match_text,
      x1,
      y + self:get_line_text_y_offset(),
      style.find_match_text or { 0xFF, 0xFF, 0xFF, 0xFF }
    )
  end
end

local function get_largefile_visible_line_range(self)
  local lh = math.max(1, self:get_line_height())
  local usable_height = math.max(lh, (self.size.y or 0) - style.padding.y * 2)
  local visible_lines = math.max(1, math.ceil(usable_height / lh) + 1)
  local minline = math.max(1, math.floor(((self.scroll.y or 0) - style.padding.y) / lh) + 1)
  local maxline = math.min(self.doc:line_count(), minline + visible_lines)
  return minline, maxline
end

DocView.context = "session"

local function move_to_line_offset(dv, line, col, offset)
  local xo = dv.last_x_offset
  if xo.line ~= line or xo.col ~= col then
    xo.offset = dv:get_col_x_offset(line, col)
  end
  xo.line = line + offset
  xo.col = dv:get_x_offset_col(line + offset, xo.offset)
  return xo.line, xo.col
end


DocView.translate = {
  ["previous_page"] = function(doc, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return line - (max - min), 1
  end,

  ["next_page"] = function(doc, line, col, dv)
    local line_count = doc:line_count()
    if line == line_count then
      return line_count, doc:get_line_length(line_count)
    end
    local min, max = dv:get_visible_line_range()
    return line + (max - min), 1
  end,

  ["previous_line"] = function(doc, line, col, dv)
    if line == 1 then
      return 1, 1
    end
    return move_to_line_offset(dv, line, col, -1)
  end,

  ["next_line"] = function(doc, line, col, dv)
    local line_count = doc:line_count()
    if line == line_count then
      return line_count, math.huge
    end
    return move_to_line_offset(dv, line, col, 1)
  end,
}


function DocView:new(doc)
  DocView.super.new(self)
  self.cursor = "ibeam"
  self.scrollable = true
  self.doc = assert(doc)
  self.font = "code_font"
  self.last_x_offset = {}
  self.ime_selection = { from = 0, size = 0 }
  self.ime_status = false
  self.ime_editing = nil
  self.hovering_gutter = false
  self.v_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.h_scrollbar:set_forced_status(config.force_scrollbar_status)
end


function DocView:try_close(do_close)
  local is_unsaved_confirm_active = core.active_view == core.command_view
    and core.command_view.label == "Unsaved Changes; Confirm Close: "

  if self.doc:is_dirty()
  and #core.get_views_referencing_doc(self.doc) == 1 then
    if self.close_confirm_pending and is_unsaved_confirm_active then
      self.close_confirm_pending = false
      -- 中文说明：用户第二次触发关闭确认，等同于明确选择“不保存关闭”。
      self.doc._close_without_saving_requested = true
      do_close()
      return
    end

    self.close_confirm_pending = true
    core.command_view:enter("Unsaved Changes; Confirm Close", {
      submit = function(_, item)
        self.close_confirm_pending = false
        if item.text:match("^[cC]") then
          -- 中文说明：记录用户明确选择 Close Without Saving，后续 WLPT 关闭日志会读取这个标记。
          self.doc._close_without_saving_requested = true
          do_close()
        elseif item.text:match("^[sS]") then
          self.doc._close_without_saving_requested = false
          self.doc:save()
          do_close()
        end
      end,
      cancel = function()
        self.close_confirm_pending = false
      end,
      suggest = function(text)
        local items = {}
        if not text:find("^[^cC]") then table.insert(items, "Close Without Saving") end
        if not text:find("^[^sS]") then table.insert(items, "Save And Close") end
        return items
      end
    })
  else
    self.close_confirm_pending = false
    if self.doc then
      self.doc._close_without_saving_requested = false
    end
    do_close()
  end
end


function DocView:get_name()
  local post = self.doc:is_dirty() and "*" or ""
  local name = self.doc:get_name()
  return name:match("[^/%\\]*$") .. post
end


function DocView:get_filename()
  if self.doc.abs_filename then
    local post = self.doc:is_dirty() and "*" or ""
    return common.home_encode(self.doc.abs_filename) .. post
  end
  return self:get_name()
end


function DocView:get_scrollable_size()
  local line_count = self.doc:line_count()
  if not config.scroll_past_end then
    local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
    return self:get_line_height() * line_count + style.padding.y * 2 + h_scroll
  end
  return self:get_line_height() * (line_count - 1) + self.size.y
end

function DocView:get_h_scrollable_size()
  return math.huge
end


function DocView:get_font()
  return style[self.font]
end


function DocView:get_line_height()
  return math.floor(self:get_font():get_height() * config.line_height)
end


function DocView:get_gutter_width()
  local padding = style.padding.x * 2
  return self:get_font():get_width(self.doc:line_count()) + padding, padding
end


function DocView:get_line_screen_position(line, col)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  y = y + (line-1) * lh + style.padding.y
  if col then
    return x + gw + self:get_col_x_offset(line, col), y
  else
    return x + gw, y
  end
end

function DocView:get_line_text_y_offset()
  local lh = self:get_line_height()
  local th = self:get_font():get_height()
  return (lh - th) / 2
end


function DocView:get_visible_line_range()
  if self.doc:is_large_file_mode() then
    return get_largefile_visible_line_range(self)
  end
  local x, y, x2, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  local minline = math.max(1, math.floor((y - style.padding.y) / lh) + 1)
  local maxline = math.min(self.doc:line_count(), math.floor((y2 - style.padding.y) / lh) + 1)
  return minline, maxline
end


function DocView:get_col_x_offset(line, col)
  local default_font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  default_font:set_tab_size(indent_size)
  local render_highlighter = get_render_highlighter(self.doc)
  if self.doc:is_large_file_mode() and not (render_highlighter and render_highlighter.is_chunk_mode and render_highlighter:is_chunk_mode()) then
    local xoffset = 0
    local line_text = self.doc:get_line(line)
    if col <= 1 then
      return 0
    end
    local column = 1
    for char in common.utf8_chars(line_text) do
      if column >= col then
        return xoffset
      end
      xoffset = xoffset + default_font:get_width(char, {tab_offset = xoffset})
      column = column + #char
    end
    return xoffset
  end
  local column = 1
  local xoffset = 0
  for _, type, text in render_highlighter:each_token(line) do
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    local length = #text
    if column + length <= col then
      xoffset = xoffset + font:get_width(text, {tab_offset = xoffset})
      column = column + length
      if column >= col then
        return xoffset
      end
    else
      for char in common.utf8_chars(text) do
        if column >= col then
          return xoffset
        end
        xoffset = xoffset + font:get_width(char, {tab_offset = xoffset})
        column = column + #char
      end
    end
  end

  return xoffset
end


function DocView:get_x_offset_col(line, x)
  local line_text = self.doc:get_line(line)

  local xoffset, i = 0, 1
  local default_font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  default_font:set_tab_size(indent_size)
  local render_highlighter = get_render_highlighter(self.doc)
  if self.doc:is_large_file_mode() and not (render_highlighter and render_highlighter.is_chunk_mode and render_highlighter:is_chunk_mode()) then
    for char in common.utf8_chars(line_text) do
      local w = default_font:get_width(char, {tab_offset = xoffset})
      if xoffset + w >= x then
        return (x <= xoffset + (w / 2)) and i or i + #char
      end
      xoffset = xoffset + w
      i = i + #char
    end
    return #line_text
  end
  for _, type, text in render_highlighter:each_token(line) do
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    local width = font:get_width(text, {tab_offset = xoffset})
    -- Don't take the shortcut if the width matches x,
    -- because we need last_i which should be calculated using utf-8.
    if xoffset + width < x then
      xoffset = xoffset + width
      i = i + #text
    else
      for char in common.utf8_chars(text) do
        local w = font:get_width(char, {tab_offset = xoffset})
        if xoffset + w >= x then
          return (x <= xoffset + (w / 2)) and i or i + #char
        end
        xoffset = xoffset + w
        i = i + #char
      end
    end
  end

  return #line_text
end


function DocView:resolve_screen_position(x, y)
  local ox, oy = self:get_line_screen_position(1)
  local line = math.floor((y - oy) / self:get_line_height()) + 1
  line = common.clamp(line, 1, self.doc:line_count())
  local col = self:get_x_offset_col(line, x - ox)
  return line, col
end


function DocView:scroll_to_line(line, ignore_if_visible, instant)
  local min, max = self:get_visible_line_range()
  if not (ignore_if_visible and line > min and line < max) then
    local x, y = self:get_line_screen_position(line)
    local ox, oy = self:get_content_offset()
    local _, _, _, scroll_h = self.h_scrollbar:get_track_rect()
    self.scroll.to.y = math.max(0, y - oy - (self.size.y - scroll_h) / 2)
    if instant then
      self.scroll.y = self.scroll.to.y
    end
  end
end


function DocView:supports_text_input()
  return true
end


function DocView:scroll_to_make_visible(line, col)
  local _, oy = self:get_content_offset()
  local _, ly = self:get_line_screen_position(line, col)
  local lh = self:get_line_height()
  local _, _, _, scroll_h = self.h_scrollbar:get_track_rect()
  local overscroll = math.min(lh * 2, self.size.y) -- always show the previous / next line when possible
  self.scroll.to.y = common.clamp(self.scroll.to.y, ly - oy - self.size.y + scroll_h + overscroll, ly - oy - lh)
  local gw = self:get_gutter_width()
  local xoffset = self:get_col_x_offset(line, col)
  local xmargin = 3 * self:get_font():get_width(' ')
  local xsup = xoffset + gw + xmargin
  local xinf = xoffset - xmargin
  local _, _, scroll_w = self.v_scrollbar:get_track_rect()
  local size_x = math.max(0, self.size.x - scroll_w)
  if xsup > self.scroll.x + size_x then
    self.scroll.to.x = xsup - size_x
  elseif xinf < self.scroll.x then
    self.scroll.to.x = math.max(0, xinf)
  end
end

function DocView:on_mouse_moved(x, y, ...)
  DocView.super.on_mouse_moved(self, x, y, ...)

  self.hovering_gutter = false
  local gw = self:get_gutter_width()

  if self:scrollbar_hovering() or self:scrollbar_dragging() then
    self.cursor = "arrow"
  elseif gw > 0 and x >= self.position.x and x <= (self.position.x + gw) then
    self.cursor = "arrow"
    self.hovering_gutter = true
  else
    self.cursor = "ibeam"
  end

  if self.mouse_selecting then
    local l1, c1 = self:resolve_screen_position(x, y)
    local l2, c2, snap_type = table.unpack(self.mouse_selecting)
    if keymap.modkeys["ctrl"] then
      if l1 > l2 then l1, l2 = l2, l1 end
      self.doc.selections = { }
      for i = l1, l2 do
        local line_length = self.doc:get_line_length(i)
        self.doc:set_selections(i - l1 + 1, i, math.min(c1, line_length), i, math.min(c2, line_length))
      end
    else
      if snap_type then
        l1, c1, l2, c2 = self:mouse_selection(self.doc, snap_type, l1, c1, l2, c2)
      end
      self.doc:set_selection(l1, c1, l2, c2)
    end
  end
end


function DocView:mouse_selection(doc, snap_type, line1, col1, line2, col2)
  local swap = line2 < line1 or line2 == line1 and col2 <= col1
  if swap then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  if snap_type == "word" then
    line1, col1 = translate.start_of_word(doc, line1, col1)
    line2, col2 = translate.end_of_word(doc, line2, col2)
  elseif snap_type == "lines" then
    col1, col2, line2 = 1, 1, line2 + 1
  end
  if swap then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end


function DocView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" or not self.hovering_gutter then
    if button == "left" then
      local line, col = self:resolve_screen_position(x, y)
      log_hit_test(self, "before-press", x, y, line, col)
    end
    local res = DocView.super.on_mouse_pressed(self, button, x, y, clicks)
    if button == "left" then
      local line1, col1 = self.doc:get_selection()
      log_hit_test(self, "after-press", x, y, line1, col1)
    end
    self:update_ime_location(true)
    return res
  end
  local line = self:resolve_screen_position(x, y)
  log_hit_test(self, "gutter-press", x, y, line, 1)
  if keymap.modkeys["shift"] then
    local sline, scol, sline2, scol2 = self.doc:get_selection(true)
    if line > sline then
      self.doc:set_selection(sline, 1, line, self.doc:get_line_length(line))
    else
      self.doc:set_selection(line, 1, sline2, self.doc:get_line_length(sline2))
    end
  else
    if clicks == 1 then
      self.doc:set_selection(line, 1, line, 1)
    elseif clicks == 2 then
      self.doc:set_selection(line, 1, line, self.doc:get_line_length(line))
    end
  end
  self:update_ime_location(true)
  return true
end


function DocView:on_mouse_released(...)
  DocView.super.on_mouse_released(self, ...)
  self.mouse_selecting = nil
end


function DocView:on_text_input(text)
  self.doc:text_input(text)
end

function DocView:on_ime_text_editing(text, start, length)
  if self.doc.loading then return end
  self.doc:ime_text_editing(text, start, length)
  self.ime_editing = text
  self.ime_status = #text > 0
  self.ime_selection.from = start
  self.ime_selection.size = length

  -- Set the composition bounding box that the system IME
  -- will consider when drawing its interface
  local line1, col1, line2, col2 = self.doc:get_selection(true)
  local col = math.min(col1, col2)
  self:update_ime_location()
  self:scroll_to_make_visible(line1, col + start)
end

---Update the composition bounding box that the system IME
---will consider when drawing its interface
function DocView:update_ime_location(force)
  if not (force or (self.ime_status and core.active_view == self)) then return end

  local line1, col1, line2, col2 = self.doc:get_selection(true)
  local h = self:get_line_height()
  local col = math.min(col1, col2)
  local anchor_line, anchor_col
  local target_line, target_col

  if self.ime_status and self.ime_selection.size > 0 then
    -- 组合串存在选区时，锚点使用组合串起点，避免软换行后仍然落在逻辑行首对应的 y 上。
    local from = col + self.ime_selection.from
    local to = from + self.ime_selection.size
    anchor_line, anchor_col = line1, from
    target_line, target_col = line1, to
  else
    -- 没有组合串选区时，直接使用当前选择范围的实际屏幕坐标。
    anchor_line, anchor_col = line1, col1
    target_line, target_col = line2, col2
  end
  local x, y = get_screen_position_for_selection(self, anchor_line, anchor_col)
  local x2 = select(1, get_screen_position_for_selection(self, target_line, target_col))

  ime.set_location(x, y, x2 - x, h)
end

function DocView:update()
  local minline, maxline = self:get_visible_line_range()
  self.doc:request_visible_window(minline, maxline, 32)
  self.doc:poll_ready_window(0)
  if self.doc.chunk_highlighter and not config.large_file_disable_highlight then
    self.doc.chunk_highlighter:ensure_visible_chunks(minline, maxline, 32, self.scroll.x, self.scroll.y)
  end

  -- scroll to make caret visible and reset blink timer if it moved
  local line1, col1, line2, col2 = self.doc:get_selection()
  if (line1 ~= self.last_line1 or col1 ~= self.last_col1 or
      line2 ~= self.last_line2 or col2 ~= self.last_col2) and self.size.x > 0 then
    if core.active_view == self and not ime.editing then
      self:scroll_to_make_visible(line1, col1)
    end
    core.blink_reset()
    self.last_line1, self.last_col1 = line1, col1
    self.last_line2, self.last_col2 = line2, col2
    if core.active_view == self then
      self:update_ime_location(true)
    end
  end

  -- update blink timer
  if not config.disable_blink and system.window_has_focus(core.window) and self == core.active_view and not self.mouse_selecting then
    local T, t0 = config.blink_period, core.blink_start
    local ta, tb = core.blink_timer, system.get_time()
    if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
      core.redraw = true
    end
    core.blink_timer = tb
  end

  self:update_ime_location()

  DocView.super.update(self)
end


function DocView:draw_line_highlight(x, y)
  local lh = self:get_line_height()
  renderer.draw_rect(x, y, self.size.x, lh, style.line_highlight)
end


function DocView:draw_line_text(line, x, y)
  local render_highlighter = get_render_highlighter(self.doc)
  if self.doc:is_large_file_mode() and self.doc.has_cached_line and not self.doc:has_cached_line(line) then
    local default_font = self:get_font()
    renderer.draw_text(default_font, "Loading...", x, y + self:get_line_text_y_offset(), style.dim or style.text)
    return self:get_line_height()
  end
  if self.doc:is_large_file_mode() and not (render_highlighter and render_highlighter.is_chunk_mode and render_highlighter:is_chunk_mode()) then
    local default_font = self:get_font()
    local text = self.doc:get_line(line)
    if text:sub(-1) == "\n" then
      text = text:sub(1, -2)
    end
    renderer.draw_text(default_font, text, x, y + self:get_line_text_y_offset(), style.text)
    return self:get_line_height()
  end
  local default_font = self:get_font()
  local tx, ty = x, y + self:get_line_text_y_offset()
  local last_token = nil
  local tokens = render_highlighter:get_line(line).tokens
  local tokens_count = #tokens
  if string.sub(tokens[tokens_count], -1) == "\n" then
    last_token = tokens_count - 1
  end
  local start_tx = tx
  for tidx, type, text in render_highlighter:each_token(line) do
    local color = style.syntax[type]
    local font = style.syntax_fonts[type] or default_font
    -- do not render newline, fixes issue #1164
    if tidx == last_token then text = text:sub(1, -2) end
    tx = renderer.draw_text(font, text, tx, ty, color, {tab_offset = tx - start_tx})
    if tx > self.position.x + self.size.x then break end
  end
  return self:get_line_height()
end


function DocView:draw_overwrite_caret(x, y, width)
  local lh = self:get_line_height()
  renderer.draw_rect(x, y + lh - style.caret_width, width, style.caret_width, style.caret)
end


function DocView:draw_caret(x, y)
  local lh = self:get_line_height()
  renderer.draw_rect(x, y, style.caret_width, lh, style.caret)
end

local function get_loading_text(base)
  local frames = { ".", "..", "...", "...." }
  local t = math.floor(system.get_time() * 3) % #frames + 1
  return base .. frames[t]
end

function DocView:selection_overlaps_find_match(line1, col1, line2, col2)
  local active_find_match = core.active_find_match
  if not active_find_match or active_find_match.doc ~= self.doc then
    return false
  end

  local sel_start_line, sel_start_col = line1, col1
  local sel_end_line, sel_end_col = line2, col2
  if sel_start_line > sel_end_line or (sel_start_line == sel_end_line and sel_start_col > sel_end_col) then
    sel_start_line, sel_start_col, sel_end_line, sel_end_col =
      sel_end_line, sel_end_col, sel_start_line, sel_start_col
  end

  local match_start_line, match_start_col = active_find_match.line1, active_find_match.col1
  local match_end_line, match_end_col = active_find_match.line2, active_find_match.col2
  if match_start_line > match_end_line or (match_start_line == match_end_line and match_start_col > match_end_col) then
    match_start_line, match_start_col, match_end_line, match_end_col =
      match_end_line, match_end_col, match_start_line, match_start_col
  end

  local selection_before_match =
    sel_end_line < match_start_line or
    (sel_end_line == match_start_line and sel_end_col <= match_start_col)
  local selection_after_match =
    sel_start_line > match_end_line or
    (sel_start_line == match_end_line and sel_start_col >= match_end_col)

  return not selection_before_match and not selection_after_match
end

function DocView:draw_line_body(line, x, y)
  -- draw highlight if any selection ends on this line
  local draw_highlight = false
  local hcl = config.highlight_current_line
  if hcl ~= false then
    for lidx, line1, col1, line2, col2 in self.doc:get_selections(false) do
      if line1 == line then
        if hcl == "no_selection" then
          if (line1 ~= line2) or (col1 ~= col2) then
            draw_highlight = false
            break
          end
        end
        draw_highlight = true
        break
      end
    end
  end
  if draw_highlight and core.active_view == self then
    self:draw_line_highlight(x + self.scroll.x, y)
  end

  -- draw selection if it overlaps this line
  local lh = self:get_line_height()
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
    local is_active_find_selection = self:selection_overlaps_find_match(line1, col1, line2, col2)
    if line >= line1 and line <= line2 then
      local text = self.doc:get_line(line)
      if line1 ~= line then col1 = 1 end
      if line2 ~= line then col2 = #text + 1 end
      local x1 = x + self:get_col_x_offset(line, col1)
      local x2 = x + self:get_col_x_offset(line, col2)
      if x1 ~= x2 and not is_active_find_selection then
        renderer.draw_rect(x1, y, x2 - x1, lh, style.selection)
      end
    end
  end
  -- draw line's text
  local result = self:draw_line_text(line, x, y)
  self:draw_find_match_overlay(line, x, y)
  return result
end


function DocView:draw_line_gutter(line, x, y, width)
  local color = style.line_number
  for _, line1, _, line2 in self.doc:get_selections(true) do
    if line >= line1 and line <= line2 then
      color = style.line_number2
      break
    end
  end
  x = x + style.padding.x
  local lh = self:get_line_height()
  common.draw_text(self:get_font(), color, line, "right", x, y, width, lh)
  return lh
end


function DocView:draw_ime_decoration(line1, col1, line2, col2)
  local col = math.min(col1, col2)
  local x, y = get_screen_position_for_selection(self, line1, col)
  local line_size = math.max(1, SCALE)
  local lh = self:get_line_height()

  -- Draw the IME composition text inline at the caret position.
  if self.ime_editing and #self.ime_editing > 0 then
    local font = self:get_font()
    local text_width = font:get_width(self.ime_editing)
    -- Background highlight for composition text
    renderer.draw_rect(x, y, text_width, lh, style.background3)
    renderer.draw_text(font, self.ime_editing, x, y, style.text)
    -- Accent underline for composition text
    renderer.draw_rect(x, y + lh - line_size, text_width, line_size, style.accent)
  end

  -- Draw IME underline for any active document selection.
  local x1 = select(1, get_screen_position_for_selection(self, line1, col1))
  local x2 = select(1, get_screen_position_for_selection(self, line2, col2))
  renderer.draw_rect(math.min(x1, x2), y + lh - line_size, math.abs(x1 - x2), line_size, style.text)

  -- Draw IME selection within the composition string.
  local from = col + self.ime_selection.from
  local to = from + self.ime_selection.size
  x1 = select(1, get_screen_position_for_selection(self, line1, from))
  if from ~= to then
    x2 = select(1, get_screen_position_for_selection(self, line1, to))
    line_size = style.caret_width
    renderer.draw_rect(math.min(x1, x2), y + lh - line_size, math.abs(x1 - x2), line_size, style.caret)
  end
  self:draw_caret(x1, y)
end


function DocView:draw_overlay()
  if core.active_view == self then
    local minline, maxline = self:get_visible_line_range()
    -- draw caret if it overlaps this line
    local T = config.blink_period
    for _, line1, col1, line2, col2 in self.doc:get_selections() do
      if line1 >= minline and line1 <= maxline
      and system.window_has_focus(core.window) then
        if ime.editing then
          self:draw_ime_decoration(line1, col1, line2, col2)
        else
          if config.disable_blink
          or (core.blink_timer - core.blink_start) % T < T / 2 then
            local x, y = self:get_line_screen_position(line1, col1)
            if self.doc.overwrite then
              self:draw_overwrite_caret(x, y, self:get_font():get_width(self.doc:get_char(line1, col1)))
            else
              self:draw_caret(x, y)
            end
          end
        end
      end
    end
  end
end

function DocView:draw()
  self:draw_background(style.background)

  if self.doc.loading_error then
    local text = "Loading failed: " .. tostring(self.doc.loading_error)
    local font = self:get_font()
    local tw = font:get_width(text)
    local th = font:get_height()
    local x = self.position.x + (self.size.x - tw) / 2
    local y = self.position.y + (self.size.y - th) / 2
    renderer.draw_text(font, text, x, y, style.accent or style.text)
    self:draw_scrollbar()
    return
  end

  local minline, maxline = self:get_visible_line_range()
  local view_ready = self.doc:is_view_ready(minline, maxline)
  local has_partial_largefile_view = self.doc:is_large_file_mode()
    and self.doc.has_any_cached_lines
    and self.doc:has_any_cached_lines(minline, maxline)

  if self.doc.loading and (not self.doc:is_large_file_mode() or not view_ready) then
    if self.doc:is_large_file_mode() and has_partial_largefile_view then
      -- keep drawing available chunks while native indexing continues
    else
      local loaded_lines = self.doc.loading_progress_lines or self.doc.loading_progress or 0
      local loaded_mb = (self.doc.loading_progress_bytes or 0) / (1024 * 1024)
      local total_mb = math.max((self.doc.loading_total_bytes or 0) / (1024 * 1024), 0)
      local text = string.format(
        "%s %d lines (%.1f / %.1f MB)",
        get_loading_text("Loading large file"),
        loaded_lines,
        loaded_mb,
        total_mb
      )
      local font = self:get_font()
      local tw = font:get_width(text)
      local th = font:get_height()
      local x = self.position.x + (self.size.x - tw) / 2
      local y = self.position.y + (self.size.y - th) / 2
      renderer.draw_text(font, text, x, y, style.text)
      self:draw_scrollbar()
      return
    end
  end

  if self.doc:is_large_file_mode() and not view_ready then
    if not has_partial_largefile_view then
      local text = get_loading_text("Loading current view")
      local font = self:get_font()
      local tw = font:get_width(text)
      local th = font:get_height()
      local x = self.position.x + (self.size.x - tw) / 2
      local y = self.position.y + (self.size.y - th) / 2
      renderer.draw_text(font, text, x, y, style.dim or style.text)
      core.redraw = true
      self:draw_scrollbar()
      return
    end
  end

  local _, indent_size = self.doc:get_indent_info()
  self:get_font():set_tab_size(indent_size)
  local lh = self:get_line_height()

  local x, y = self:get_line_screen_position(minline)
  local gw, gpad = self:get_gutter_width()
  for i = minline, maxline do
    y = y + (self:draw_line_gutter(i, self.position.x, y, gpad and gw - gpad or gw) or lh)
  end

  local pos = self.position
  x, y = self:get_line_screen_position(minline)
  -- the clip below ensure we don't write on the gutter region. On the
  -- right side it is redundant with the Node's clip.
  core.push_clip_rect(pos.x + gw, pos.y, self.size.x - gw, self.size.y)
  for i = minline, maxline do
    y = y + (self:draw_line_body(i, x, y) or lh)
  end
  self:draw_overlay()
  core.pop_clip_rect()

  if self.doc.loading and self.doc:is_large_file_mode() then
    local loaded_lines = self.doc.loading_progress_lines or self.doc.loading_progress or 0
    local loaded_mb = (self.doc.loading_progress_bytes or 0) / (1024 * 1024)
    local total_mb = math.max((self.doc.loading_total_bytes or 0) / (1024 * 1024), 0)
    local text = string.format(
      "%s %d lines (%.1f / %.1f MB)",
      get_loading_text("Indexing large file"),
      loaded_lines,
      loaded_mb,
      total_mb
    )
    renderer.draw_rect(
      self.position.x,
      self.position.y,
      self.size.x,
      self:get_line_height() + style.padding.y * 2,
      style.background2
    )
    renderer.draw_text(
      self:get_font(),
      text,
      self.position.x + style.padding.x,
      self.position.y + self:get_line_text_y_offset(),
      style.dim or style.text
    )
    core.redraw = true
  end

  self:draw_scrollbar()
end

function DocView:on_context_menu()
  return { items = {
    { text = "Cut",     command = "doc:cut" },
    { text = "Copy",    command = "doc:copy" },
    { text = "Paste",   command = "doc:paste" },
    ContextMenu.DIVIDER,
    { text = "Find",    command = "find-replace:find"    },
    { text = "Replace", command = "find-replace:replace" }
  } }, self
end

return DocView
