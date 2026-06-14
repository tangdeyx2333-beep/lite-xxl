-- mod-version:4
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local system = require "system"
local ContextMenu = require "core.contextmenu"
local View = require "core.view"
local DocView = require "core.docview"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function render_inline(text)
  text = text:gsub("!%[([^%]]*)%]%(([^%)]+)%)", "🖼 %1 (%2)")
  text = text:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1 (%2)")
  text = text:gsub("`([^`]+)`", "%1")

  -- strong/emphasis
  text = text:gsub("%*%*%*([^*]-)%*%*%*", "%1")
  text = text:gsub("___([^_]-)___", "%1")
  text = text:gsub("%*%*([^*]-)%*%*", "%1")
  text = text:gsub("__([^_]-)__", "%1")
  text = text:gsub("%*([^*]-)%*", "%1")
  text = text:gsub("_([^_]-)_", "%1")

  -- extra common markdown syntaxes
  text = text:gsub("~~([^~]-)~~", "%1")      -- strikethrough
  text = text:gsub("==([^=]-)==", "%1")      -- mark
  text = text:gsub("%^([^%^]-)%^", "%1")     -- superscript hint
  text = text:gsub("~([^~]-)~", "%1")        -- subscript hint

  -- lightweight html inline tags
  text = text:gsub("<[Uu]>(.-)</[Uu]>", "%1")
  text = text:gsub("<[Ss][Uu][Bb]>(.-)</[Ss][Uu][Bb]>", "%1")
  text = text:gsub("<[Ss][Uu][Pp]>(.-)</[Ss][Uu][Pp]>", "%1")
  text = text:gsub("<[Mm][Aa][Rr][Kk]>(.-)</[Mm][Aa][Rr][Kk]>", "%1")

  return text
end

local function wrap_text(font, text, max_width)
  text = text or ""
  if text == "" then
    return { "" }
  end

  local lines = {}
  local current = ""

  local function push_current()
    table.insert(lines, current)
    current = ""
  end

  local function append_word(word)
    if current == "" then
      current = word
      return
    end
    local candidate = current .. " " .. word
    if font:get_width(candidate) <= max_width then
      current = candidate
    else
      push_current()
      current = word
    end
  end

  local function split_long_word(word)
    local chunk = ""
    for ch in common.utf8_chars(word) do
      local candidate = chunk .. ch
      if chunk ~= "" and font:get_width(candidate) > max_width then
        table.insert(lines, chunk)
        chunk = ch
      else
        chunk = candidate
      end
    end
    if chunk ~= "" then
      append_word(chunk)
    end
  end

  for word in text:gmatch("%S+") do
    if font:get_width(word) > max_width then
      if current ~= "" then
        push_current()
      end
      split_long_word(word)
    else
      append_word(word)
    end
  end

  if current ~= "" then
    push_current()
  end

  return #lines > 0 and lines or { "" }
end

local function parse_markdown(source)
  source = source:gsub("\r\n", "\n"):gsub("\r", "\n")
  local blocks = {}
  local para = {}
  local in_code = false
  local code_lines = {}

  local function push_paragraph()
    if #para == 0 then return end
    local text = trim(table.concat(para, " "))
    if text ~= "" then
      table.insert(blocks, { type = "paragraph", text = render_inline(text) })
    end
    para = {}
  end

  local function push_code()
    if #code_lines == 0 then return end
    table.insert(blocks, { type = "code", text = table.concat(code_lines, "\n") })
    code_lines = {}
  end

  for line in (source .. "\n"):gmatch("(.-)\n") do
    if line:match("^```") then
      if in_code then
        push_code()
        in_code = false
      else
        push_paragraph()
        in_code = true
      end
    elseif in_code then
      table.insert(code_lines, line)
    else
      local heading_marks, heading_text = line:match("^(#+)%s*(.-)%s*$")
      local quote_text = line:match("^%s*>%s?(.*)$")
      local leading_spaces, ordered_n, ordered_item = line:match("^(%s*)(%d+)%.%s+(.*)$")
      local leading_spaces_u, unordered_item = line:match("^(%s*)[-*+]%s+(.*)$")

      if line:match("^%s*$") then
        push_paragraph()
      elseif heading_marks then
        push_paragraph()
        table.insert(blocks, {
          type = "heading",
          level = #heading_marks,
          text = render_inline(trim(heading_text))
        })
      elseif line:match("^%s*[-*_][-%s*_]*$") then
        push_paragraph()
        table.insert(blocks, { type = "hr" })
      elseif quote_text then
        push_paragraph()
        table.insert(blocks, { type = "quote", text = render_inline(trim(quote_text)) })
      elseif ordered_n and ordered_item then
        push_paragraph()
        table.insert(blocks, {
          type = "list",
          ordered = true,
          marker = ordered_n .. ".",
          indent = math.floor(#leading_spaces / 2),
          text = render_inline(trim(ordered_item))
        })
      elseif unordered_item then
        push_paragraph()
        table.insert(blocks, {
          type = "list",
          ordered = false,
          marker = "•",
          indent = math.floor(#leading_spaces_u / 2),
          text = render_inline(trim(unordered_item))
        })
      else
        table.insert(para, line)
      end
    end
  end

  push_paragraph()
  if in_code then
    push_code()
  end

  return blocks
end

local MarkdownPreviewView = View:extend()

function MarkdownPreviewView:__tostring() return "MarkdownPreviewView" end

MarkdownPreviewView.context = "session"

function MarkdownPreviewView:apply_fonts()
  local zoom = self._zoom or 1
  self._fonts = {
    h1 = style.font:copy(26 * SCALE * zoom),
    h2 = style.font:copy(22 * SCALE * zoom),
    h3 = style.font:copy(18 * SCALE * zoom),
    body = style.font:copy(15 * SCALE * zoom),
    code = style.code_font:copy(14 * SCALE * zoom),
  }
  self._layout_width = 0
end

function MarkdownPreviewView:new(source_view)
  MarkdownPreviewView.super.new(self)
  self.scrollable = true
  self._md_source_view = source_view
  self.doc = source_view.doc
  self._md_blocks = {}
  self._layout_items = {}
  self._layout_width = 0
  self._content_height = 0
  self._last_source_change_id = -1
  self._zoom = 1
  self._selection_anchor = nil
  self._selection_cursor = nil
  self._mouse_selecting_preview = false
  self:apply_fonts()
  self:refresh_from_source()
end

function MarkdownPreviewView:on_scale_change()
  self:apply_fonts()
end

function MarkdownPreviewView:get_name()
  return self._md_source_view:get_name() .. " [MD]"
end

function MarkdownPreviewView:get_filename()
  return self._md_source_view:get_filename() .. " [MD]"
end

function MarkdownPreviewView:try_close(do_close)
  self._md_source_view:try_close(do_close)
end

function MarkdownPreviewView:supports_text_input()
  return false
end

function MarkdownPreviewView:on_text_input()
end

function MarkdownPreviewView:adjust_zoom(delta)
  local next_zoom = common.clamp((self._zoom or 1) + delta, 0.6, 2.4)
  if next_zoom == self._zoom then return end
  self._zoom = next_zoom
  self:apply_fonts()
  self:rebuild_layout()
  core.redraw = true
end

function MarkdownPreviewView:on_mouse_wheel(y, x)
  if keymap.modkeys["ctrl"] then
    local delta = y ~= 0 and y or -x
    if delta > 0 then
      self:adjust_zoom(0.1)
    elseif delta < 0 then
      self:adjust_zoom(-0.1)
    end
    return true
  end
end

local function get_text_width_until(font, text, col)
  if col <= 1 then
    return 0
  end
  return font:get_width(text:sub(1, col - 1))
end

local function get_col_at_x(font, text, x)
  if x <= 0 then
    return 1
  end
  local offset = 0
  local col = 1
  for ch in common.utf8_chars(text or "") do
    local width = font:get_width(ch)
    if offset + width >= x then
      return x <= offset + width / 2 and col or col + #ch
    end
    offset = offset + width
    col = col + #ch
  end
  return #(text or "") + 1
end

function MarkdownPreviewView:get_text_item_screen_rect(item)
  local page_x = self:get_page_x()
  local _, oy = self:get_content_offset()
  local page_y = oy + style.padding.y * 2
  return page_x + item.x, page_y + item.y, item.font:get_width(item.text), item.h
end

function MarkdownPreviewView:hit_test_text(x, y)
  local best_idx, best_item, best_distance
  local page_x = self:get_page_x()
  local page_w = self:get_page_width()
  for idx, item in ipairs(self._layout_items or {}) do
    if item.kind == "text" then
      local sx, sy, sw, sh = self:get_text_item_screen_rect(item)
      local distance = 0
      if y < sy then
        distance = sy - y
      elseif y > sy + sh then
        distance = y - (sy + sh)
      end
      if y >= sy and y <= sy + sh and x >= sx and x <= sx + math.max(sw, 1) then
        return { item = idx, col = get_col_at_x(item.font, item.text, x - sx) }
      end
      if x >= page_x and x <= page_x + page_w and (not best_distance or distance < best_distance) then
        best_idx, best_item, best_distance = idx, item, distance
      end
    end
  end
  if best_item then
    local sx = self:get_text_item_screen_rect(best_item)
    return { item = best_idx, col = get_col_at_x(best_item.font, best_item.text, x - sx) }
  end
end

function MarkdownPreviewView:normalize_selection()
  local anchor = self._selection_anchor
  local cursor = self._selection_cursor
  if not (anchor and cursor) then
    return nil
  end
  if anchor.item > cursor.item or (anchor.item == cursor.item and anchor.col > cursor.col) then
    anchor, cursor = cursor, anchor
  end
  if anchor.item == cursor.item and anchor.col == cursor.col then
    return nil
  end
  return anchor, cursor
end

function MarkdownPreviewView:clear_preview_selection()
  self._selection_anchor = nil
  self._selection_cursor = nil
  self._mouse_selecting_preview = false
  core.redraw = true
end

function MarkdownPreviewView:get_selected_text()
  local first, last = self:normalize_selection()
  if not (first and last) then
    return ""
  end
  local lines = {}
  for idx = first.item, last.item do
    local item = self._layout_items[idx]
    if item and item.kind == "text" then
      local col1 = idx == first.item and first.col or 1
      local col2 = idx == last.item and last.col or (#item.text + 1)
      if col2 > col1 then
        lines[#lines + 1] = item.text:sub(col1, col2 - 1)
      elseif first.item ~= last.item then
        lines[#lines + 1] = ""
      end
    end
  end
  return table.concat(lines, "\n")
end

function MarkdownPreviewView:copy_selection()
  local text = self:get_selected_text()
  if text == "" then
    return false
  end
  -- 中文说明：复制的是预览页实际显示的文本，而不是原始 Markdown 标记。
  system.set_clipboard(text)
  core.log("Copied markdown preview selection")
  return true
end

function MarkdownPreviewView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    if self:scrollbar_overlaps_point(x, y) then
      return MarkdownPreviewView.super.on_mouse_pressed(self, button, x, y, clicks)
    end
    local pos = self:hit_test_text(x, y)
    if pos then
      self._selection_anchor = pos
      self._selection_cursor = { item = pos.item, col = pos.col }
      self._mouse_selecting_preview = true
      core.redraw = true
      return true
    end
    self:clear_preview_selection()
  end
  return MarkdownPreviewView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function MarkdownPreviewView:on_mouse_moved(x, y, dx, dy)
  if self._mouse_selecting_preview then
    local pos = self:hit_test_text(x, y)
    if pos then
      self._selection_cursor = pos
      core.redraw = true
    end
    return true
  end
  return MarkdownPreviewView.super.on_mouse_moved(self, x, y, dx, dy)
end

function MarkdownPreviewView:on_mouse_released(button, x, y)
  if button == "left" and self._mouse_selecting_preview then
    self._mouse_selecting_preview = false
    return true
  end
  return MarkdownPreviewView.super.on_mouse_released(self, button, x, y)
end

function MarkdownPreviewView:on_context_menu(x, y)
  return { items = {
    { text = "Copy", command = function(view) view:copy_selection() end },
    ContextMenu.DIVIDER,
    { text = "Select All", command = function(view)
      view:select_all_preview_text()
    end },
  } }, self
end

function MarkdownPreviewView:select_all_preview_text()
  local first, last
  for idx, item in ipairs(self._layout_items or {}) do
    if item.kind == "text" then
      first = first or { item = idx, col = 1 }
      last = { item = idx, col = #item.text + 1 }
    end
  end
  self._selection_anchor = first
  self._selection_cursor = last
  core.redraw = true
end

function MarkdownPreviewView:scroll_by_lines(delta)
  local step = self._fonts.body:get_height() + math.max(2, math.floor(style.padding.y * 0.5))
  self.scroll.to.y = math.max(0, self.scroll.to.y + step * delta)
  return true
end

function MarkdownPreviewView:refresh_from_source()
  local src = self._md_source_view
  local text = src.doc:get_text(1, 1, math.huge, math.huge)
  self._md_blocks = parse_markdown(text)
  self._last_source_change_id = src.doc:get_change_id()
  self._layout_width = 0
  -- 中文说明：源文件变化后旧选区的行列坐标可能失效，必须清理避免复制错位内容。
  self._selection_anchor = nil
  self._selection_cursor = nil
  self._mouse_selecting_preview = false
end

function MarkdownPreviewView:get_page_width()
  local outer_margin = math.max(style.padding.x, math.floor(self.size.x * 0.015))
  return math.max(100, self.size.x - outer_margin * 2)
end

function MarkdownPreviewView:get_page_x()
  local page_w = self:get_page_width()
  return self.position.x + math.floor((self.size.x - page_w) / 2)
end

function MarkdownPreviewView:get_page_inset()
  return math.max(style.padding.x * 2, math.floor(self:get_page_width() * 0.03))
end

function MarkdownPreviewView:rebuild_layout()
  local page_w = self:get_page_width()
  local inset = self:get_page_inset()
  local text_w = math.max(100, page_w - inset * 2)



  self._layout_items = {}
  local y = style.padding.y * 3
  local line_gap = math.max(2, math.floor(style.padding.y * 0.5))

  local function line_block_height(font, count)
    if count <= 0 then return 0 end
    local h = font:get_height()
    return count * h + (count - 1) * line_gap
  end

  local function add_line(text, font, color, x, extra)
    table.insert(self._layout_items, {
      kind = "text",
      text = text,
      font = font,
      color = color,
      x = x,
      y = y,
      h = font:get_height(),
      extra = extra
    })
    y = y + font:get_height() + line_gap
  end

  local function add_space(px)
    y = y + (px or math.floor(style.padding.y * 0.9))
  end

  for _, block in ipairs(self._md_blocks) do
    if block.type == "heading" then
      local level = block.level or 1
      local font = level == 1 and self._fonts.h1 or (level == 2 and self._fonts.h2 or self._fonts.h3)
      local lines = wrap_text(font, block.text, text_w)
      add_space(style.padding.y)
      for _, line in ipairs(lines) do
        add_line(line, font, style.text, inset)
      end
      add_space(style.padding.y)
      table.insert(self._layout_items, {
        kind = "rule",
        x = inset,
        y = y,
        w = text_w,
        h = math.max(1, SCALE),
        color = style.divider
      })
      add_space(style.padding.y)

    elseif block.type == "paragraph" then
      local lines = wrap_text(self._fonts.body, block.text, text_w)
      for _, line in ipairs(lines) do
        add_line(line, self._fonts.body, style.text, inset)
      end
      add_space(style.padding.y)

    elseif block.type == "quote" then
      local quote_x = inset + style.padding.x
      local quote_w = text_w - style.padding.x * 2
      local lines = wrap_text(self._fonts.body, block.text, quote_w)
      table.insert(self._layout_items, {
        kind = "quote_line",
        x = inset,
        y = y,
        w = math.max(2, SCALE * 2),
        h = line_block_height(self._fonts.body, #lines) + style.padding.y,
        color = style.dim
      })
      for _, line in ipairs(lines) do
        add_line(line, self._fonts.body, style.dim, quote_x)
      end
      add_space(style.padding.y)

    elseif block.type == "list" then
      local indent = math.max(0, block.indent or 0) * style.padding.x
      local marker_w = self._fonts.body:get_width((block.marker or "•") .. " ")
      local base_x = inset + indent
      local text_x = base_x + marker_w
      local lines = wrap_text(self._fonts.body, block.text, text_w - indent - marker_w)
      if #lines > 0 then
        add_line((block.marker or "•") .. " " .. lines[1], self._fonts.body, style.text, base_x)
        for i = 2, #lines do
          add_line(lines[i], self._fonts.body, style.text, text_x)
        end
      end
      add_space(math.floor(style.padding.y / 2))

    elseif block.type == "code" then
      local code_lines = {}
      for line in (block.text .. "\n"):gmatch("(.-)\n") do
        table.insert(code_lines, line)
      end

      local wrapped_code_lines = {}
      for _, line in ipairs(code_lines) do
        local wrapped = wrap_text(self._fonts.code, line, text_w - style.padding.x * 2)
        for _, chunk in ipairs(wrapped) do
          table.insert(wrapped_code_lines, chunk)
        end
      end

      local code_h = line_block_height(self._fonts.code, #wrapped_code_lines) + style.padding.y * 2
      table.insert(self._layout_items, {
        kind = "code_bg",
        x = inset,
        y = y,
        w = text_w,
        h = code_h,
        color = style.background3
      })
      add_space(style.padding.y)
      for _, chunk in ipairs(wrapped_code_lines) do
        add_line(chunk, self._fonts.code, style.text, inset + style.padding.x)
      end
      add_space(style.padding.y * 2)


    elseif block.type == "hr" then
      add_space(style.padding.y)
      table.insert(self._layout_items, {
        kind = "rule",
        x = inset,
        y = y,
        w = text_w,
        h = math.max(1, SCALE),
        color = style.divider
      })
      add_space(style.padding.y * 2)
    end
  end

  self._content_height = y + style.padding.y * 2
  self._layout_width = text_w
end

function MarkdownPreviewView:get_scrollable_size()
  if not self._layout_items then return self.size.y end
  return math.max(self.size.y, self._content_height + style.padding.y * 2)
end

function MarkdownPreviewView:get_h_scrollable_size()
  return self.size.x
end

function MarkdownPreviewView:update()
  local change_id = self._md_source_view.doc:get_change_id()
  if change_id ~= self._last_source_change_id then
    self:refresh_from_source()
  end

  local page_w = self:get_page_width()
  local inset = self:get_page_inset()
  local text_w = math.max(100, page_w - inset * 2)

  if self._layout_width ~= text_w then
    self:rebuild_layout()
  end

  MarkdownPreviewView.super.update(self)
end

function MarkdownPreviewView:draw_preview_selection(item_idx, item, page_x, y)
  local first, last = self:normalize_selection()
  if not (first and last) or item_idx < first.item or item_idx > last.item then
    return
  end
  local col1 = item_idx == first.item and first.col or 1
  local col2 = item_idx == last.item and last.col or (#item.text + 1)
  if col2 <= col1 then
    return
  end
  -- 中文说明：按渲染后的文本坐标画选区，避免影响源 Markdown 文档自身的选区。
  local x1 = page_x + item.x + get_text_width_until(item.font, item.text, col1)
  local x2 = page_x + item.x + get_text_width_until(item.font, item.text, col2)
  renderer.draw_rect(x1, y, math.max(1, x2 - x1), item.h, style.selection)
end

function MarkdownPreviewView:draw()
  self:draw_background(style.background)

  local page_w = self:get_page_width()
  local page_x = self:get_page_x()
  local _, oy = self:get_content_offset()
  local page_y = oy + style.padding.y * 2
  local page_h = math.max(self.size.y - style.padding.y * 4, self._content_height)


  renderer.draw_rect(page_x, page_y, page_w, page_h, style.background2)

  core.push_clip_rect(page_x, self.position.y, page_w, self.size.y)
  local min_y = self.position.y - style.padding.y
  local max_y = self.position.y + self.size.y + style.padding.y

  for item_idx, item in ipairs(self._layout_items) do
    local y = page_y + item.y
    if y + (item.h or 0) >= min_y and y <= max_y then
      if item.kind == "text" then
        self:draw_preview_selection(item_idx, item, page_x, y)
        renderer.draw_text(item.font, item.text, page_x + item.x, y, item.color)
      elseif item.kind == "rule" then
        renderer.draw_rect(page_x + item.x, y, item.w, item.h, item.color)
      elseif item.kind == "quote_line" then
        renderer.draw_rect(page_x + item.x, y, item.w, item.h, item.color)
      elseif item.kind == "code_bg" then
        renderer.draw_rect(page_x + item.x, y, item.w, item.h, item.color)
      end
    end
  end

  core.pop_clip_rect()
  self:draw_scrollbar()
end

local function replace_view(node, from_view, to_view)
  local idx = node:get_view_idx(from_view)
  if not idx then return false end
  node.views[idx] = to_view
  node:set_active_view(to_view)
  core.root_view.root_node:update_layout()
  return true
end

local function create_preview_view(source_view)
  local preview_view = MarkdownPreviewView(source_view)
  source_view._md_preview_view = preview_view
  return preview_view
end

local function get_toggle_target_view(view)
  if not view or view.context ~= "session" then
    return nil
  end
  if view._md_source_view then
    return view._md_source_view
  end
  if view:extends(DocView) and view.doc then
    return view
  end
  return nil
end

local function is_wlpt_doc(doc)
  return doc
    and doc.is_wlpt_mode
    and doc:is_wlpt_mode()
end

local function is_markdown_render_allowed(doc)
  if is_wlpt_doc(doc) and config.wlpt_disable_markdown_render ~= false then
    return false
  end
  return true
end

command.add(function()
  local view = get_toggle_target_view(core.active_view)
  return view ~= nil and is_markdown_render_allowed(view.doc), view
end, {
  ["markdown:toggle-render"] = function(view)
    local active_view = core.active_view
    local node = core.root_view.root_node:get_node_for_view(active_view)
    if not node then return end

    if active_view._md_source_view then
      replace_view(node, active_view, active_view._md_source_view)
      return
    end

    local source_view = view
    local preview_view = source_view._md_preview_view
    if not preview_view then
      preview_view = create_preview_view(source_view)
    else
      preview_view:refresh_from_source()
    end

    replace_view(node, source_view, preview_view)
  end
})

command.add(function()
  return core.active_view and core.active_view:extends(MarkdownPreviewView)
end, {
  ["markdown:preview-scroll-up"] = function()
    return core.active_view:scroll_by_lines(-3)
  end,
  ["markdown:preview-scroll-down"] = function()
    return core.active_view:scroll_by_lines(3)
  end,
})

command.add(function()
  local view = core.active_view
  if not (view and view:extends(MarkdownPreviewView)) then
    return false
  end
  return view:get_selected_text() ~= "", view
end, {
  ["markdown:preview-copy"] = function(view)
    view:copy_selection()
  end,
})

command.add(function()
  local view = core.active_view
  return view and view:extends(MarkdownPreviewView), view
end, {
  ["markdown:preview-select-all"] = function(view)
    view:select_all_preview_text()
  end,
})

keymap.add {
  ["ctrl+c"] = "markdown:preview-copy",
  ["ctrl+a"] = "markdown:preview-select-all",
  ["ctrl+m"] = "markdown:toggle-render",
  ["up"] = { "markdown:preview-scroll-up", "command:select-previous", "context-menu:focus-previous", "doc:move-to-previous-line" },
  ["down"] = { "markdown:preview-scroll-down", "command:select-next", "context-menu:focus-next", "doc:move-to-next-line" },
}
