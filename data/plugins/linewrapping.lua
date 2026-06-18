-- mod-version:4 --priority:10
local core = require "core"
local common = require "core.common"
local DocView = require "core.docview"
local Doc = require "core.doc"
local style = require "core.style"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local get_line_idx_col_count
local doc_line_count
local doc_line_text


config.plugins.linewrapping = common.merge({
	-- The type of wrapping to perform. Can be "letter" or "word".
  mode = "letter",
	-- If nil, uses the DocView's size, otherwise, uses this exact width. Can be a function.
  width_override = nil,
	-- Whether or not to draw a guide
  guide = true,
  -- Whether or not we should indent ourselves like the first line of a wrapped block.
  indent = true,
  -- Whether or not to enable wrapping by default when opening files.
  enable_by_default = true,
  -- Requires tokenization
  require_tokenization = false,
  -- The config specification used by gui generators
  config_spec = {
    name = "Line Wrapping",
    {
      label = "Mode",
      description = "The type of wrapping to perform.",
      path = "mode",
      type = "selection",
      default = "letter",
      values = {
        {"Letters", "letter"},
        {"Words", "word"}
      }
    },
    {
      label = "Guide",
      description = "Whether or not to draw a guide.",
      path = "guide",
      type = "toggle",
      default = true
    },
    {
      label = "Indent",
      description = "Whether or not to follow the indentation of wrapped line.",
      path = "indent",
      type = "toggle",
      default = true
    },
    {
      label = "Enable by Default",
      description = "Whether or not to enable wrapping by default when opening files.",
      path = "enable_by_default",
      type = "toggle",
      default = false
    },
    {
      label = "Require Tokenization",
      description = "Use tokenization when applying wrapping.",
      path = "require_tokenization",
      type = "toggle",
      default = false
    }
  }
}, config.plugins.linewrapping)

local LineWrapping = {}

function doc_line_count(doc)
  return doc and doc.line_count and doc:line_count() or #(doc.lines or {})
end

function doc_line_text(doc, line)
  if doc and doc.get_line then
    return doc:get_line(line)
  end
  return (doc.lines and doc.lines[line]) or "\n"
end

local function wrapping_unavailable(doc_or_view)
  local doc = doc_or_view and (doc_or_view.doc or doc_or_view)
  return not doc
    or doc.disable_line_wrapping
    or doc:is_large_file_mode()
    or not doc:supports_full_line_array()
end

-- Optimzation function. The tokenizer is relatively slow (at present), and
-- so if we don't need to run it, should be run sparingly.
local function spew_tokens(doc, line) if line < math.huge then return math.huge, "normal", doc_line_text(doc, line) end end
local function get_tokens(doc, line)
  if doc.disable_line_wrapping or doc:is_large_file_mode() or not doc:supports_full_line_array() then
    return spew_tokens, doc, line
  end
  if config.plugins.linewrapping.require_tokenization then
    return doc.highlighter:each_token(line)
  end
  return spew_tokens, doc, line
end

-- Computes the breaks for a given line, width and mode. Returns a list of columns
-- at which the line should be broken.
function LineWrapping.compute_line_breaks(doc, default_font, line, width, mode)
  local xoffset, last_i, i, last_space, last_width, begin_width = 0, 1, 1, nil, 0, 0
  local splits = { 1 }
  for idx, type, text in get_tokens(doc, line) do
    local font = style.syntax_fonts[type] or default_font
    if idx == 1 or idx == math.huge and config.plugins.linewrapping.indent then
      local _, indent_end = text:find("^%s+")
      if indent_end then begin_width = font:get_width(text:sub(1, indent_end)) end
    end
    local w = font:get_width(text)
    if xoffset + w > width then
      for char in common.utf8_chars(text) do
        w = font:get_width(char)
        xoffset = xoffset + w
        if xoffset > width then
          if mode == "word" and last_space then
            table.insert(splits, last_space + 1)
            xoffset = w + begin_width + (xoffset - last_width)
          else
            table.insert(splits, i)
            xoffset = w + begin_width
          end
          last_space = nil
        elseif char == ' ' then
          last_space = i
          last_width = xoffset
        end
        i = i + #char
      end
    else
      xoffset = xoffset + w
      i = i + #text
    end
  end
  return splits, begin_width
end

-- breaks are held in a single table that contains n*2 elements, where n is the amount of line breaks.
-- each element represents line and column of the break. line_offset will check from the specified line
-- if the first line has not changed breaks, it will stop there.
function LineWrapping.reconstruct_breaks(docview, default_font, width, line_offset)
  if width ~= math.huge then
    local doc = docview.doc
    -- two elements per wrapped line; first maps to original line number, second to column number.
    docview.wrapped_lines = { }
    -- one element per actual line; maps to the first index of in wrapped_lines for this line
    docview.wrapped_line_to_idx = { }
    -- one element per actual line; gives the indent width for the acutal line
    docview.wrapped_line_offsets = { }
    docview.wrapped_settings = { ["width"] = width, ["font"] = default_font }
    for i = line_offset or 1, #doc.lines do
      local breaks, offset = LineWrapping.compute_line_breaks(doc, default_font, i, width, config.plugins.linewrapping.mode)
      table.insert(docview.wrapped_line_offsets, offset)
      for k, col in ipairs(breaks) do
        table.insert(docview.wrapped_lines, i)
        table.insert(docview.wrapped_lines, col)
      end
    end
    -- list of indices for wrapped_lines, that are based on original line number
    -- holds the index to the first in the wrapped_lines list.
    local last_wrap = nil
    for i = 1, #docview.wrapped_lines, 2 do
      if not last_wrap or last_wrap ~= docview.wrapped_lines[i] then
        table.insert(docview.wrapped_line_to_idx, (i + 1) / 2)
        last_wrap = docview.wrapped_lines[i]
      end
    end
  else
    docview.wrapped_lines = nil
    docview.wrapped_line_to_idx = nil
    docview.wrapped_line_offsets = nil
    docview.wrapped_settings = nil
  end
end

-- When we have an insertion or deletion, we have four sections of text.
-- 1. The unaffected section, located prior to the cursor. This is completely ignored.
-- 2. The beginning of the affected line prior to the insertion or deletion. Begins on column 1 of the selection.
-- 3. The removed/pasted lines.
-- 4. Every line after the modification, begins one line after the selection in the initial document.
function LineWrapping.update_breaks(docview, old_line1, old_line2, net_lines)
  -- Step 1: Determine the index for the line for #2.
  local old_idx1 = docview.wrapped_line_to_idx[old_line1] or 1
  -- Step 2: Determine the index of the line for #4.
  local old_idx2 = (docview.wrapped_line_to_idx[old_line2 + 1] or ((#docview.wrapped_lines / 2) + 1)) - 1
  -- Step 3: Remove all old breaks for the old lines from the table, and all old widths from wrapped_line_offsets.
  local offset = (old_idx1  - 1) * 2 + 1
  for i = old_idx1, old_idx2 do
    table.remove(docview.wrapped_lines, offset)
    table.remove(docview.wrapped_lines, offset)
  end
  for i = old_line1, old_line2 do
    table.remove(docview.wrapped_line_offsets, old_line1)
  end
  -- Step 4: Shift the line number of wrapped_lines past #4 by the amount of inserted/deleted lines.
  if net_lines ~= 0 then
    for i = offset, #docview.wrapped_lines, 2 do
      docview.wrapped_lines[i] = docview.wrapped_lines[i] + net_lines
    end
  end
  -- Step 5: Compute the breaks and offsets for the lines for #2 and #3. Insert them into the table.
  local new_line1 = old_line1
  local new_line2 = old_line2 + net_lines
  for line = new_line1, new_line2 do
    local breaks, begin_width = LineWrapping.compute_line_breaks(docview.doc, docview.wrapped_settings.font, line, docview.wrapped_settings.width, config.plugins.linewrapping.mode)
    table.insert(docview.wrapped_line_offsets, line, begin_width)
    for i,b in ipairs(breaks) do
      table.insert(docview.wrapped_lines, offset, b)
      table.insert(docview.wrapped_lines, offset, line)
      offset = offset + 2
    end
  end
  -- Step 6: Recompute the wrapped_line_to_idx cache from #2.
  local line = old_line1
  offset = (old_idx1  - 1) * 2 + 1
  while offset < #docview.wrapped_lines do
    if docview.wrapped_lines[offset + 1] == 1 then
      docview.wrapped_line_to_idx[line] = ((offset - 1) / 2) + 1
      line = line + 1
    end
    offset = offset + 2
  end
  while line <= #docview.wrapped_line_to_idx do
    table.remove(docview.wrapped_line_to_idx)
  end
end

-- Draws a guide if applicable to show where wrapping is occurring.
function LineWrapping.draw_guide(docview)
  if config.plugins.linewrapping.guide and docview.wrapped_settings.width ~= math.huge then
    local x, y = docview:get_content_offset()
    local gw = docview:get_gutter_width()
    renderer.draw_rect(x + gw + docview.wrapped_settings.width, y, 1, core.root_view.size.y, style.selection)
  end
end

function LineWrapping.update_docview_breaks(docview)
  local w = docview.v_scrollbar.expanded_size or style.expanded_scrollbar_size
  local width = (type(config.plugins.linewrapping.width_override) == "function" and config.plugins.linewrapping.width_override(docview))
    or config.plugins.linewrapping.width_override or (docview.size.x - docview:get_gutter_width() - w)
  if (not docview.wrapped_settings or docview.wrapped_settings.width == nil or width ~= docview.wrapped_settings.width) then
    docview.scroll.to.x = 0
    LineWrapping.reconstruct_breaks(docview, docview:get_font(), width)
  end
end

local function get_idx_line_col(docview, idx)
  local doc = docview.doc
  if not docview.wrapped_settings then
    local line_count = doc_line_count(doc)
    if idx > line_count then return line_count, #doc_line_text(doc, line_count) + 1 end
    return idx, 1
  end
  if idx < 1 then return 1, 1 end
  local offset = (idx - 1) * 2 + 1
  if offset > #docview.wrapped_lines then
    local line_count = doc_line_count(doc)
    return line_count, #doc_line_text(doc, line_count) + 1
  end
  return docview.wrapped_lines[offset], docview.wrapped_lines[offset + 1]
end

local function get_idx_line_length(docview, idx)
  local doc = docview.doc
  if not docview.wrapped_settings then
    local line_count = doc_line_count(doc)
    if idx > line_count then return #doc_line_text(doc, line_count) + 1 end
    return #doc_line_text(doc, idx)
  end
  local offset = (idx - 1) * 2 + 1
  local start = docview.wrapped_lines[offset + 1]
  if docview.wrapped_lines[offset + 2] and docview.wrapped_lines[offset + 2] == docview.wrapped_lines[offset] then
    return docview.wrapped_lines[offset + 3] - docview.wrapped_lines[offset + 1]
  else
    return #doc_line_text(doc, docview.wrapped_lines[offset]) - docview.wrapped_lines[offset + 1] + 1
  end
end

local function get_total_wrapped_lines(docview)
  if not docview.wrapped_settings then return docview.doc and doc_line_count(docview.doc) end
  return #docview.wrapped_lines / 2
end

-- If line end, gives the end of an index line, rather than the first character of the next line.
function get_line_idx_col_count(docview, line, col, line_end, ndoc)
  local doc = docview.doc
  local line_count = doc_line_count(doc)
  if not docview.wrapped_settings then return common.clamp(line, 1, line_count), col, 1, 1 end
  if line > line_count then return get_line_idx_col_count(docview, line_count, #doc_line_text(doc, line_count) + 1) end
  line = math.max(line, 1)
  local idx = docview.wrapped_line_to_idx[line] or 1
  local ncol, scol = 1, 1
  if col then
    local i = idx + 1
    while line == docview.wrapped_lines[(i - 1) * 2 + 1] and col >= docview.wrapped_lines[(i - 1) * 2 + 2] do
      local nscol = docview.wrapped_lines[(i - 1) * 2 + 2]
      if line_end and col == nscol then
        break
      end
      scol = nscol
      i = i + 1
      idx = idx + 1
    end
    ncol = (col - scol) + 1
  end
  local count = (docview.wrapped_line_to_idx[line + 1] or (get_total_wrapped_lines(docview) + 1)) - (docview.wrapped_line_to_idx[line] or get_total_wrapped_lines(docview))
  return idx, ncol, count, scol
end

local function get_line_col_from_index_and_x(docview, idx, x)
  local doc = docview.doc
  local line, col = get_idx_line_col(docview, idx)
  if idx < 1 then return 1, 1 end
  local xoffset, last_i, i = (col ~= 1 and docview.wrapped_line_offsets[line] or 0), col, 1
  if x < xoffset then return line, col end
  local default_font = docview:get_font()
  for _, type, text in doc.highlighter:each_token(line) do
    local font, w = style.syntax_fonts[type] or default_font, 0
    for char in common.utf8_chars(text) do
      if i >= col then
        if xoffset >= x then
          return line, (xoffset - x > (w / 2) and last_i or i)
        end
        w = font:get_width(char)
        xoffset = xoffset + w
      end
      last_i = i
      i = i + #char
    end
  end
  return line, #doc_line_text(doc, line)
end


local open_files = setmetatable({ }, { __mode = "k" })

local old_doc_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo_stack, time)
  local old_lines = #self.lines
  old_doc_insert(self, line, col, text, undo_stack, time)
  if open_files[self] then
    for i,docview in ipairs(open_files[self]) do
      if docview.wrapped_settings then
        local lines = #self.lines - old_lines
        LineWrapping.update_breaks(docview, line, line, lines)
      end
    end
  end
end

local old_doc_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  local old_lines = #self.lines
  old_doc_remove(self, line1, col1, line2, col2, undo_stack, time)
  if open_files[self] then
    for i,docview in ipairs(open_files[self]) do
      if docview.wrapped_settings then
        local lines = #self.lines - old_lines
        LineWrapping.update_breaks(docview, line1, line2, lines)
      end
    end
  end
end

local old_doc_update = DocView.update
function DocView:update()
  if wrapping_unavailable(self) then
    self.wrapping_enabled = false
    self.wrapped_settings = nil
    return old_doc_update(self)
  end
  old_doc_update(self)
  if self.wrapped_settings and self.size.x > 0 then
    LineWrapping.update_docview_breaks(self)
  end
end

function DocView:get_scrollable_size()
  if not config.scroll_past_end then
    return self:get_line_height() * get_total_wrapped_lines(self) + style.padding.y * 2
  end
  return self:get_line_height() * (get_total_wrapped_lines(self) - 1) + self.size.y
end

local old_get_h_scrollable_size = DocView.get_h_scrollable_size
function DocView:get_h_scrollable_size(...)
  if wrapping_unavailable(self) then
    return old_get_h_scrollable_size(self, ...)
  end
  if self.wrapping_enabled then return 0 end
  return old_get_h_scrollable_size(self, ...)
end

local old_new = DocView.new
function DocView:new(doc)
  old_new(self, doc)
  if not open_files[doc] then open_files[doc] = {} end
  table.insert(open_files[doc], self)
  if wrapping_unavailable(doc) then
    self.wrapping_enabled = false
    self.wrapped_settings = nil
    return
  end
  if config.plugins.linewrapping.enable_by_default then
    self.wrapping_enabled = true
    LineWrapping.update_docview_breaks(self)
  else
    self.wrapping_enabled = false
  end
end

local old_scroll_to_line = DocView.scroll_to_line
function DocView:scroll_to_line(...)
  if wrapping_unavailable(self) then
    return old_scroll_to_line(self, ...)
  end
  if self.wrapping_enabled then LineWrapping.update_docview_breaks(self) end
  old_scroll_to_line(self, ...)
end

local old_scroll_to_make_visible = DocView.scroll_to_make_visible
function DocView:scroll_to_make_visible(line, col)
  if wrapping_unavailable(self) then
    return old_scroll_to_make_visible(self, line, col)
  end
  if self.wrapping_enabled then LineWrapping.update_docview_breaks(self) end
  old_scroll_to_make_visible(self, line, col)
  if self.wrapped_settings then self.scroll.to.x = 0 end
end

local old_get_visible_line_range = DocView.get_visible_line_range
function DocView:get_visible_line_range()
  if not self.wrapped_settings then return old_get_visible_line_range(self) end
  local x, y, x2, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  local minline = get_idx_line_col(self, math.max(1, math.floor(y / lh)))
  local maxline = get_idx_line_col(self, math.min(get_total_wrapped_lines(self), math.floor(y2 / lh) + 1))
  return minline, maxline
end

local old_get_x_offset_col = DocView.get_x_offset_col
function DocView:get_x_offset_col(line, x)
  if not self.wrapped_settings then return old_get_x_offset_col(self, line, x) end
  local idx = get_line_idx_col_count(self, line)
  return get_line_col_from_index_and_x(self, idx, x)
end

-- If line end is true, returns the end of the previous line, in a multi-line break.
local old_get_col_x_offset = DocView.get_col_x_offset
function DocView:get_col_x_offset(line, col, line_end)
  if not self.wrapped_settings then return old_get_col_x_offset(self, line, col) end
  local idx, ncol, count, scol = get_line_idx_col_count(self, line, col, line_end)
  local xoffset, i = (scol ~= 1 and self.wrapped_line_offsets[line] or 0), 1
  local default_font = self:get_font()
  for _, type, text in self.doc.highlighter:each_token(line) do
    if i + #text >= scol then
      if i < scol then
        text = text:sub(scol - i + 1)
        i = scol
      end
      local font = style.syntax_fonts[type] or default_font
      for char in common.utf8_chars(text) do
        if i >= col then
          return xoffset
        end
        xoffset = xoffset + font:get_width(char)
        i = i + #char
      end
    else
     i = i + #text
    end
  end
  return xoffset
end

local old_get_line_screen_position = DocView.get_line_screen_position
function DocView:get_line_screen_position(line, col)
  if not self.wrapped_settings then return old_get_line_screen_position(self, line, col) end
  local idx, ncol, count = get_line_idx_col_count(self, line, col)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  return x + gw + (col and self:get_col_x_offset(line, col) or 0), y + (idx-1) * lh + style.padding.y
end

local old_resolve_screen_position = DocView.resolve_screen_position
function DocView:resolve_screen_position(x, y)
  if not self.wrapped_settings then return old_resolve_screen_position(self, x, y) end
  local ox, oy = self:get_line_screen_position(1)
  local idx = common.clamp(math.floor((y - oy) / self:get_line_height()) + 1, 1, get_total_wrapped_lines(self))
  return get_line_col_from_index_and_x(self, idx, x - ox)
end

local old_draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(line, x, y)
  if not self.wrapped_settings then return old_draw_line_text(self, line, x, y) end
  local default_font = self:get_font()
  local tx, ty, begin_width = x, y + self:get_line_text_y_offset(), self.wrapped_line_offsets[line]
  local lh = self:get_line_height()
  local idx, _, count = get_line_idx_col_count(self, line)
  local total_offset = 1
  for _, type, text in self.doc.highlighter:each_token(line) do
    local color = style.syntax[type]
    local font = style.syntax_fonts[type] or default_font
    local token_offset = 1
    -- Split tokens if we're at the end of the document.
    while text ~= nil and token_offset <= #text do
      local next_line, next_line_start_col = get_idx_line_col(self, idx + 1)
      if next_line ~= line then
        next_line_start_col = #doc_line_text(self.doc, line)
      end
      local max_length = next_line_start_col - total_offset
      local rendered_text = text:sub(token_offset, token_offset + max_length - 1)
      tx = renderer.draw_text(font, rendered_text, tx, ty, color)
      total_offset = total_offset + #rendered_text
      if total_offset ~= next_line_start_col or max_length == 0 then break end
      token_offset = token_offset + #rendered_text
      idx = idx + 1
      tx, ty = x + begin_width, ty + lh
    end
  end
  return lh * count
end

local old_draw_find_match_overlay = DocView.draw_find_match_overlay
local function split_wrapped_segments_by_selection(segments, overlap_segments, selection_col1, selection_col2)
  local next_segments = {}
  for _, seg in ipairs(segments) do
    if selection_col2 <= seg.col1 or selection_col1 >= seg.col2 then
      next_segments[#next_segments + 1] = seg
    else
      if seg.col1 < selection_col1 then
        next_segments[#next_segments + 1] = {
          col1 = seg.col1,
          col2 = math.min(seg.col2, selection_col1)
        }
      end
      local overlap_col1 = math.max(seg.col1, selection_col1)
      local overlap_col2 = math.min(seg.col2, selection_col2)
      if overlap_col1 < overlap_col2 then
        overlap_segments[#overlap_segments + 1] = {
          col1 = overlap_col1,
          col2 = overlap_col2
        }
      end
      if selection_col2 < seg.col2 then
        next_segments[#next_segments + 1] = {
          col1 = math.max(seg.col1, selection_col2),
          col2 = seg.col2
        }
      end
    end
  end
  return next_segments, overlap_segments
end

local function partition_wrapped_find_segments(self, line, text, col1, col2)
  local fill_segments = {
    { col1 = col1, col2 = col2 }
  }
  local overlap_segments = {}

  for _, sel_line1, sel_col1, sel_line2, sel_col2 in self.doc:get_selections(true) do
    if line >= sel_line1 and line <= sel_line2 then
      local selection_col1 = sel_line1 ~= line and 1 or sel_col1
      local selection_col2 = sel_line2 ~= line and #text + 1 or sel_col2
      fill_segments, overlap_segments =
        split_wrapped_segments_by_selection(fill_segments, overlap_segments, selection_col1, selection_col2)
    end
  end

  return fill_segments, overlap_segments
end

function DocView:draw_find_match_overlay(line, x, y)
  if not self.wrapped_settings then return old_draw_find_match_overlay(self, line, x, y) end

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
  if line1 ~= line then col1 = 1 end
  if line2 ~= line then col2 = #text + 1 end

  if col1 == col2 then return end

  local lh = self:get_line_height()
  local idx0 = get_line_idx_col_count(self, line)
  local fill_segments, overlap_segments = partition_wrapped_find_segments(self, line, text, col1, col2)

  for _, seg in ipairs(fill_segments) do
    local idx1 = get_line_idx_col_count(self, line, seg.col1)
    local idx2 = get_line_idx_col_count(self, line, seg.col2)

    for i = idx1, idx2 do
      local x1 = x + (idx1 == i and self:get_col_x_offset(line, seg.col1) or 0)
      local x2
      local next_col
      if self.wrapped_lines[i * 2 + 1] == line then
        next_col = self.wrapped_lines[i * 2 + 2]
      else
        next_col = #text + 1
      end

      if idx2 == i then
        x2 = x + self:get_col_x_offset(line, seg.col2)
      else
        x2 = x + self:get_col_x_offset(line, next_col, true)
      end

      if x1 ~= x2 then
        local rect_y = y + (i - idx0) * lh
        renderer.draw_rect(x1, rect_y + 1, x2 - x1, math.max(1, lh - 2), style.find_match or { 0xFF, 0x8C, 0x00, 0xFF })
        local match_col1 = (idx1 == i and seg.col1 or self.wrapped_lines[(i - 1) * 2 + 2])
        local match_col2 = (idx2 == i and seg.col2 or next_col)
        local match_text = text:sub(match_col1, math.max(match_col1, match_col2 - 1))
        if match_text ~= "" then
          renderer.draw_text(
            self:get_font(),
            match_text,
            x1,
            rect_y + self:get_line_text_y_offset(),
            style.find_match_text or { 0xFF, 0xFF, 0xFF, 0xFF }
          )
        end
      end
    end
  end

  for _, seg in ipairs(overlap_segments) do
    local idx1 = get_line_idx_col_count(self, line, seg.col1)
    local idx2 = get_line_idx_col_count(self, line, seg.col2)

    for i = idx1, idx2 do
      local x1 = x + (idx1 == i and self:get_col_x_offset(line, seg.col1) or 0)
      local x2
      local next_col
      if self.wrapped_lines[i * 2 + 1] == line then
        next_col = self.wrapped_lines[i * 2 + 2]
      else
        next_col = #text + 1
      end

      if idx2 == i then
        x2 = x + self:get_col_x_offset(line, seg.col2)
      else
        x2 = x + self:get_col_x_offset(line, next_col, true)
      end

      if x1 ~= x2 then
        local rect_y = y + (i - idx0) * lh
        renderer.draw_rect(x1, rect_y + lh - 1, math.max(1, x2 - x1), 1, style.find_match or { 0xFF, 0x8C, 0x00, 0xFF })
      end
    end
  end
end

local old_draw_line_body = DocView.draw_line_body
function DocView:draw_line_body(line, x, y)
  if not self.wrapped_settings then return old_draw_line_body(self, line, x, y) end
  local lh = self:get_line_height()
  local idx0, _, count = get_line_idx_col_count(self, line)
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if line >= line1 and line <= line2 then
      if line1 ~= line then col1 = 1 end
      if line2 ~= line then col2 = #doc_line_text(self.doc, line) + 1 end
      if col1 ~= col2 then
        local idx1, ncol1 = get_line_idx_col_count(self, line, col1)
        local idx2, ncol2 = get_line_idx_col_count(self, line, col2)
        for i = idx1, idx2 do
          local x1 = x + (idx1 == i and self:get_col_x_offset(line1, col1) or 0)
          local x2
          local next_col
          if self.wrapped_lines[i * 2 + 1] == line then
            next_col = self.wrapped_lines[i * 2 + 2]
          else
            next_col = #doc_line_text(self.doc, line) + 1
          end

          if idx2 == i then
            x2 = x + self:get_col_x_offset(line, col2)
          else
            x2 = x + self:get_col_x_offset(line, next_col, true)
          end
          renderer.draw_rect(x1, y + (i - idx0) * lh, x2 - x1, lh, style.selection)
        end
      end
    end
  end
  local draw_highlight = nil
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
    -- draw line highlight if caret is on this line
    if draw_highlight ~= false and config.highlight_current_line
    and line1 == line and core.active_view == self then
      draw_highlight = (line1 == line2 and col1 == col2)
    end
  end
  if draw_highlight then
    for i=1,count do
      self:draw_line_highlight(x + self.scroll.x, y + lh * (i - 1))
    end
  end
  -- draw line's text
  local result = self:draw_line_text(line, x, y)
  if self.draw_find_match_overlay then
    self:draw_find_match_overlay(line, x, y)
  end
  return result
end

local old_draw = DocView.draw
function DocView:draw()
  if wrapping_unavailable(self) then
    self.wrapping_enabled = false
    self.wrapped_settings = nil
    return old_draw(self)
  end
  old_draw(self)
  if self.wrapped_settings then
    LineWrapping.draw_guide(self)
  end
end

local old_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  local _, _, count = get_line_idx_col_count(self, line)
  return (old_draw_line_gutter(self, line, x, y, width) or lh) * count
end

local old_translate_end_of_line = translate.end_of_line
function translate.end_of_line(doc, line, col)
  if not core.active_view or core.active_view.doc ~= doc or not core.active_view.wrapped_settings then old_translate_end_of_line(doc, line, col) end
  local idx, ncol = get_line_idx_col_count(core.active_view, line, col)
  local nline, ncol2 = get_idx_line_col(core.active_view, idx + 1)
  if nline ~= line then return line, math.huge end
  return line, ncol2 - 1
end

local old_translate_start_of_line = translate.start_of_line
function translate.start_of_line(doc, line, col)
  if not core.active_view or core.active_view.doc ~= doc or not core.active_view.wrapped_settings then old_translate_start_of_line(doc, line, col) end
  local idx, ncol = get_line_idx_col_count(core.active_view, line, col)
  local nline, ncol2 = get_idx_line_col(core.active_view, idx - 1)
  if nline ~= line then return line, 1 end
  return line, ncol2 + 1
end

local old_previous_line = DocView.translate.previous_line
function DocView.translate.previous_line(doc, line, col, dv)
  if not dv.wrapped_settings then return old_previous_line(doc, line, col, dv) end
  local idx, ncol = get_line_idx_col_count(dv, line, col)
  return get_line_col_from_index_and_x(dv, idx - 1, dv:get_col_x_offset(line, col))
end

local old_next_line = DocView.translate.next_line
function DocView.translate.next_line(doc, line, col, dv)
  if not dv.wrapped_settings then return old_next_line(doc, line, col, dv) end
  local idx, ncol = get_line_idx_col_count(dv, line, col)
  return get_line_col_from_index_and_x(dv, idx + 1, dv:get_col_x_offset(line, col))
end

command.add(nil, {
  ["line-wrapping:enable"] = function()
    if core.active_view and core.active_view.doc and not wrapping_unavailable(core.active_view) then
      core.active_view.wrapping_enabled = true
      LineWrapping.update_docview_breaks(core.active_view)
    end
  end,
  ["line-wrapping:disable"] = function()
    if core.active_view and core.active_view.doc then
      core.active_view.wrapping_enabled = false
      LineWrapping.reconstruct_breaks(core.active_view, core.active_view:get_font(), math.huge)
    end
  end,
  ["line-wrapping:toggle"] = function()
    if core.active_view and core.active_view.doc and core.active_view.wrapped_settings then
      command.perform("line-wrapping:disable")
    else
      command.perform("line-wrapping:enable")
    end
  end
})

keymap.add {
  ["f10"] = "line-wrapping:toggle",
}

return LineWrapping
