-- mod-version:4
local core = require "core"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local config = require "core.config"
local common = require "core.common"

-- 准备阶段：先合并括号匹配的默认配置，后续绘制和命令切换都只消费这一份配置。
config.plugins.bracketmatch = common.merge({
  highlight_both = true,
  style = "underline",
  color_char = false,
  line_size = math.ceil(1 * SCALE),
  config_spec = {
    name = "Bracket Match",
    {
      label = "Highlight Both",
      description = "Highlight the current bracket too.",
      path = "highlight_both",
      type = "toggle",
      default = true
    },
    {
      label = "Style",
      description = "The visual indicator for pair brackets.",
      path = "style",
      type = "selection",
      default = "underline",
      values = {
        {"Underline", "underline"},
        {"Block", "block"},
        {"Frame", "frame"},
        {"None", "none"}
      }
    },
    {
      label = "Colorize Bracket",
      description = "Change the color of the matching brackets.",
      path = "color_char",
      type = "toggle",
      default = false
    },
    {
      label = "Line Size",
      description = "Height of the underline on matching brackets.",
      path = "line_size",
      type = "number",
      default = 1,
      min = 1,
      step = 1,
      get_value = function(value)
        return math.floor(value / SCALE)
      end,
      set_value = function(value)
        return math.ceil(value * SCALE)
      end
    }
  }
}, config.plugins.bracketmatch)

local bracket_maps = {
  { [91] = 93, [40] = 41, [123] = 125, direction =  1 },
  { [93] = 91, [41] = 40, [125] = 123, direction = -1 },
}

local function get_token_at(doc, line, col)
  local column = 0
  for _, type, text in doc.highlighter:each_token(line) do
    column = column + #text
    if column >= col then return type, text end
  end
end

local function get_matching_bracket(doc, line, col, line_limit, open_byte, close_byte, direction)
  local end_line = line + line_limit * direction
  local depth = 0

  -- 使用阶段：沿指定方向扫描括号，并忽略注释里的括号，避免高亮到无效位置。
  while line ~= end_line do
    local byte = doc.lines[line]:byte(col)
    if byte == open_byte and get_token_at(doc, line, col) ~= "comment" then
      depth = depth + 1
    elseif byte == close_byte and get_token_at(doc, line, col) ~= "comment" then
      depth = depth - 1
      if depth == 0 then return line, col end
    end

    local prev_line, prev_col = line, col
    line, col = doc:position_offset(line, col, direction)
    if line == prev_line and col == prev_col then break end
  end
end

local state = {}
local select_adj = 0

local function update_state(line_limit)
  line_limit = line_limit or math.huge

  -- 准备阶段：只有正文编辑视图才维护括号匹配状态，离开文档时清空旧状态。
  local doc = core.active_view and core.active_view.doc
  if not doc then
    state = {}
    return
  end

  -- 处理阶段：光标和文档版本没有变化时复用缓存，避免每帧重复扫描。
  local line, col = doc:get_selection()
  local change_id = doc:get_change_id()
  if state.doc == doc and state.line == line and state.col == col
  and state.change_id == change_id and state.limit == line_limit then
    return
  end

  local line2, col2
  for _, map in ipairs(bracket_maps) do
    for i = 0, -1, -1 do
      local check_line, check_col = doc:position_offset(line, col, i)
      local open = doc.lines[check_line]:byte(check_col)
      local close = map[open]
      if close and get_token_at(doc, check_line, check_col) ~= "comment" then
        -- 使用阶段：记录光标相对括号的位置，后续绘制当前括号时要靠它修正列号。
        select_adj = i + 1
        line2, col2 = get_matching_bracket(doc, check_line, check_col, line_limit, open, close, map.direction)
        line, col = check_line, check_col
        goto found
      end
    end
  end
  ::found::

  state = {
    change_id = change_id,
    doc = doc,
    line = line,
    col = col,
    line2 = line2,
    col2 = col2,
    limit = line_limit,
  }
end

local update = DocView.update

function DocView:update(...)
  update(self, ...)
  update_state(100)
end

local function redraw_char(dv, x, y, line, col, bg_color, char_color)
  local x1 = x + dv:get_col_x_offset(line, col)
  local x2 = x + dv:get_col_x_offset(line, col + 1)
  local lh = dv:get_line_height()
  local token = get_token_at(dv.doc, line, col)
  local font = style.syntax_fonts[token] or dv:get_font()
  local char = string.sub(dv.doc.lines[line], col, col)

  if not char_color then char_color = style.syntax[token] end

  -- 使用阶段：块状高亮需要先恢复局部背景，再重画括号字符，避免字符被背景盖住。
  if not bg_color then
    core.push_clip_rect(x1, y, x2 - x1, lh)
    local dlt = DocView.draw_line_text
    DocView.draw_line_text = function() end
    dv:draw_line_body(line, x, y)
    DocView.draw_line_text = dlt
    core.pop_clip_rect()
  else
    renderer.draw_rect(x1, y, x2 - x1, lh, bg_color)
  end
  renderer.draw_text(font, char, x1, y + dv:get_line_text_y_offset(), char_color)
end

local function draw_decoration(dv, x, y, line, col, width)
  local conf = config.plugins.bracketmatch
  local color = style.bracketmatch_color or style.syntax["function"]
  local char_color = style.bracketmatch_char_color
                     or (conf.style == "block" and style.background or style.syntax["keyword"])
  local block_color = style.bracketmatch_block_color or style.line_number2
  local frame_color = style.bracketmatch_frame_color or style.line_number2
  local h = conf.line_size

  -- 使用阶段：根据配置绘制字符变色、下划线、块背景或边框，匹配结果只负责提供位置。
  if conf.color_char or conf.style == "block" then
    for i = 1, width do
      redraw_char(dv, x, y, line, col + i - 1,
                  conf.style == "block" and block_color, conf.color_char and char_color)
    end
  end
  if conf.style == "underline" then
    local x1 = x + dv:get_col_x_offset(line, col)
    local x2 = x + dv:get_col_x_offset(line, col + width)
    local lh = dv:get_line_height()
    renderer.draw_rect(x1, y + lh - h, x2 - x1, h, color)
  elseif conf.style == "frame" then
    local x1 = x + dv:get_col_x_offset(line, col)
    local x2 = x + dv:get_col_x_offset(line, col + width)
    local lh = dv:get_line_height()
    renderer.draw_rect(x1, y + lh - h, x2 - x1, h, frame_color)
    renderer.draw_rect(x1, y, x2 - x1, h, frame_color)
    renderer.draw_rect(x1, y, h, lh, frame_color)
    renderer.draw_rect(x2, y, h, lh, frame_color)
  end
end

local draw_line_text = DocView.draw_line_text

function DocView:draw_line_text(line, x, y)
  local lh = draw_line_text(self, line, x, y)
  local width = 1
  if self.doc == state.doc and state.line2 then
    if line == state.line and config.plugins.bracketmatch.highlight_both then
      local offset = 0
      if state.line == state.line2 and math.abs(state.col + select_adj - 1 - state.col2) == 1 then
        width = 2
        if state.col > state.col2 then offset = -1 end
        if state.col2 > state.col + select_adj then offset = 1 end
      end
      draw_decoration(self, x, y, line, state.col + select_adj + offset - 1, width)
    end
    if line == state.line2 and width == 1 then
      draw_decoration(self, x, y, line, state.col2, width)
    end
  end
  return lh
end

command.add("core.docview", {
  ["bracketmatch:toggle"] = function()
    config.plugins.bracketmatch.highlight_both = not config.plugins.bracketmatch.highlight_both
  end
})

keymap.add {
  ["ctrl+m"] = "bracketmatch:toggle"
}
