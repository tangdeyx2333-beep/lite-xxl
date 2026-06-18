local core = require "core"
local common = require "core.common"
local core = require "core"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"
local USERDIR = USERDIR
local PATHSEP = PATHSEP


---@class core.commandview.input : core.doc
---@field super core.doc
local SingleLineDoc = Doc:extend()

function SingleLineDoc:__tostring() return "SingleLineDoc" end

function SingleLineDoc:insert(line, col, text)
  SingleLineDoc.super.insert(self, line, col, text:gsub("\n", ""))
end

---@class core.commandview : core.docview
---@field super core.docview
local CommandView = DocView:extend()

function CommandView:__tostring() return "CommandView" end

CommandView.context = "application"

local noop = function() end

---@class core.commandview.state
---@field submit function
---@field suggest function
---@field cancel function
---@field validate function
---@field text string
---@field select_text boolean
---@field show_suggestions boolean
---@field typeahead boolean
---@field wrap boolean
local default_state = {
  submit = noop,
  suggest = noop,
  cancel = noop,
  validate = function() return true end,
  text = "",
  select_text = false,
  show_suggestions = true,
  typeahead = true,
  wrap = true,
  buttons = nil,
  keep_open_on_focus_loss = false,
}

local DEBUG_LOG_PATH = USERDIR and (USERDIR .. PATHSEP .. "wlpt-debug.log") or nil

local function append_find_debug_log(fmt, ...)
  if not DEBUG_LOG_PATH then
    return
  end
  local ok, message = pcall(string.format, fmt, ...)
  if not ok then
    return
  end
  local fp = io.open(DEBUG_LOG_PATH, "a")
  if not fp then
    return
  end
  fp:write(os.date("%Y-%m-%d %H:%M:%S "))
  fp:write("[DEBUG-find-exit] ")
  fp:write(message)
  fp:write("\n")
  fp:close()
end

local function is_find_command_view(self)
  local label = self and self.label or ""
  return label:match("^Find")
end

function CommandView:is_persistent_open()
  -- 中文说明：用于识别“允许失焦后继续显示”的命令栏，例如 find。
  return self.state ~= default_state and self.state.keep_open_on_focus_loss
end


function CommandView:new()
  CommandView.super.new(self, SingleLineDoc())
  self.suggestion_idx = 1
  self.suggestions_offset = 1
  self.suggestions = {}
  self.suggestions_height = 0
  self.last_change_id = 0
  self.last_text = ""
  self.user_supplied_text = ""
  self.last_change = "text"
  self.gutter_width = 0
  self.gutter_text_brightness = 0
  self.selection_offset = 0
  self.state = default_state
  self.font = "font"
  self.size.y = 0
  self.label = ""
  self.button_padding_x = style.padding.x * 1.5
  self.button_gap = style.padding.x
  self.button_height = 0
  self.button_hovered = nil
  self.button_rects = {}
  self.button_pressed = nil
  self.button_repeat_start = nil
  self.button_repeat_last = nil
end


---@deprecated
function CommandView:set_hidden_suggestions()
  core.warn("Using deprecated function CommandView:set_hidden_suggestions")
  self.state.show_suggestions = false
end


function CommandView:get_name()
  return View.get_name(self)
end


function CommandView:get_line_screen_position(line, col)
  local x = CommandView.super.get_line_screen_position(self, 1, col)
  local _, y = self:get_content_offset()
  local lh = self:get_line_height()
  return x, y + (self.size.y - lh) / 2
end

function CommandView:get_buttons()
  return self.state.buttons or {}
end

function CommandView:get_visible_buttons()
  local resolved = {}
  for _, button in ipairs(self:get_buttons()) do
    local visible = button.visible
    if visible == nil or visible == true or (type(visible) == "function" and visible(self)) then
      resolved[#resolved + 1] = button
    end
  end
  return resolved
end

function CommandView:get_button_text(button)
  if type(button.get_text) == "function" then
    return button.get_text(self) or ""
  end
  return button.text or ""
end

function CommandView:get_buttons_width()
  local buttons = self:get_visible_buttons()
  if #buttons == 0 then
    return 0
  end
  local font = self:get_font()
  local button_height = math.max(font:get_height(), self:get_line_height())
  self.button_height = button_height
  local total = style.padding.x
  for i, button in ipairs(buttons) do
    local width = font:get_width(self:get_button_text(button))
      + self.button_padding_x * 2
    total = total + width
    if i < #buttons then
      total = total + self.button_gap
    end
  end
  return total
end

function CommandView:update_button_layout()
  self.button_rects = {}
  local buttons = self:get_visible_buttons()
  if #buttons == 0 then
    self.button_hovered = nil
    return
  end
  local font = self:get_font()
  local button_height = math.max(font:get_height(), self:get_line_height())
  self.button_height = button_height
  local x = self.position.x + self.size.x - self:get_buttons_width()
  local y = self.position.y + math.floor((self.size.y - button_height) / 2)
  for i, button in ipairs(buttons) do
    local width = font:get_width(self:get_button_text(button)) + self.button_padding_x * 2
    self.button_rects[i] = {
      button = button,
      x = x,
      y = y,
      w = width,
      h = button_height,
    }
    x = x + width + self.button_gap
  end
end

function CommandView:get_button_rect_at(x, y)
  for i, rect in ipairs(self.button_rects or {}) do
    if x >= rect.x and x <= rect.x + rect.w
      and y >= rect.y and y <= rect.y + rect.h then
      return rect, i
    end
  end
end

function CommandView:clear_button_press()
  self.button_pressed = nil
  self.button_repeat_start = nil
  self.button_repeat_last = nil
end

function CommandView:trigger_button_action(button)
  if type(button.action) == "function" then
    button.action(self)
  end
end

function CommandView:get_button_repeat_interval(button, now)
  local delay = button.repeat_delay or 0.35
  local base_interval = button.repeat_interval or 0.5
  local min_interval = button.repeat_min_interval or base_interval
  local ramp_duration = button.repeat_ramp_duration or 1.5
  if not self.button_repeat_start then
    return base_interval
  end
  local elapsed = math.max(0, now - (self.button_repeat_start + delay))
  if ramp_duration <= 0 or base_interval <= min_interval then
    return min_interval
  end
  local progress = math.min(1, elapsed / ramp_duration)
  return base_interval - (base_interval - min_interval) * progress
end


function CommandView:supports_text_input()
  return true
end


function CommandView:get_scrollable_size()
  return 0
end

function CommandView:get_h_scrollable_size()
  return 0
end


function CommandView:scroll_to_make_visible()
  -- no-op function to disable this functionality
end


function CommandView:get_text()
  return self.doc:get_text(1, 1, 1, math.huge)
end


function CommandView:set_text(text, select)
  self.last_text = text
  self.doc:remove(1, 1, math.huge, math.huge)
  self.doc:text_input(text)
  if select then
    self.doc:set_selection(math.huge, math.huge, 1, 1)
  end
end


function CommandView:move_suggestion_idx(dir)
  local function overflow_suggestion_idx(n, count)
    if count == 0 then return 0 end
    if self.state.wrap then
      return (n - 1) % count + 1
    else
      return common.clamp(n, 1, count)
    end
  end

  local function get_suggestions_offset()
    local max_visible = math.min(config.max_visible_commands, #self.suggestions)
    if dir > 0 then
      if self.suggestions_offset + max_visible < self.suggestion_idx + 1 then
        return self.suggestion_idx - max_visible + 1
      elseif self.suggestions_offset > self.suggestion_idx then
        return self.suggestion_idx
      end
    else
      if self.suggestions_offset > self.suggestion_idx then
        return self.suggestion_idx
      elseif self.suggestions_offset + max_visible < self.suggestion_idx + 1 then
        return self.suggestion_idx - max_visible + 1
      end
    end
    return self.suggestions_offset
  end

  self.last_change = "suggestion"
  if self.state.show_suggestions then
    local n = self.suggestion_idx + dir
    self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
    self:complete()
    self.last_change_id = self.doc:get_change_id()
  else
    local current_suggestion = #self.suggestions > 0 and self.suggestions[self.suggestion_idx].text
    local text = self:get_text()
    if text == current_suggestion then
      local n = self.suggestion_idx + dir
      if n == 0 and self.save_suggestion then
        self:set_text(self.save_suggestion)
      else
        self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
        self:complete()
      end
    else
      self.save_suggestion = text
      self:complete()
    end
    self.last_change_id = self.doc:get_change_id()
    self.state.suggest(self:get_text())
  end

  self.suggestions_offset = get_suggestions_offset()
end


function CommandView:complete()
  if #self.suggestions > 0 then
    self:set_text(self.suggestions[self.suggestion_idx].text)
  end
end


function CommandView:submit()
  local suggestion = self.suggestions[self.suggestion_idx]
  local text = self:get_text()
  if self.state.validate(text, suggestion) then
    local submit = self.state.submit
    self:exit(true)
    submit(text, suggestion)
  end
end

---@param label string
---@varargs any
---@overload fun(label:string, options: core.commandview.state)
function CommandView:enter(label, ...)
  if self.state ~= default_state then
    return
  end
  local options = select(1, ...)

  if type(options) ~= "table" then
    core.warn("Using CommandView:enter in a deprecated way")
    local submit, suggest, cancel, validate = ...
    options = {
      submit = submit,
      suggest = suggest,
      cancel = cancel,
      validate = validate,
    }
  end

  -- Support deprecated CommandView:set_hidden_suggestions
  -- Remove this when set_hidden_suggestions is not supported anymore
  if options.show_suggestions == nil then
    options.show_suggestions = self.state.show_suggestions
  end

  self.state = common.merge(default_state, options)

  -- We need to keep the text entered with CommandView:set_text to
  -- maintain compatibility with deprecated usage, but still allow
  -- overwriting with options.text
  local old_text = self:get_text()
  if old_text ~= "" then
    core.warn("Using deprecated function CommandView:set_text")
  end
  if options.text or options.select_text then
    local text = options.text or old_text
    self:set_text(text, self.state.select_text)
  end
  -- Replace with a simple
  -- self:set_text(self.state.text, self.state.select_text)
  -- once old usage is removed

  core.set_active_view(self)
  self:update_suggestions()
  self.gutter_text_brightness = 100
  self.label = label .. ": "
end


function CommandView:exit(submitted, inexplicit)
  if is_find_command_view(self) then
    append_find_debug_log(
      "commandview.exit label=%q submitted=%s inexplicit=%s active_is_self=%s keep_open=%s last_active=%s",
      tostring(self.label),
      tostring(submitted),
      tostring(inexplicit),
      tostring(core.active_view == self),
      tostring(self.state and self.state.keep_open_on_focus_loss),
      tostring(core.last_active_view)
    )
  end
  if core.active_view == self then
    core.set_active_view(core.last_active_view)
  end
  local cancel = self.state.cancel
  self.state = default_state
  self.doc:reset()
  self.suggestions = {}
  if not submitted then cancel(not inexplicit) end
  self.save_suggestion = nil
  self.last_text = ""
end


function CommandView:get_line_height()
  return math.floor(self:get_font():get_height() * 1.2)
end


function CommandView:get_gutter_width()
  return self.gutter_width
end


function CommandView:get_suggestion_line_height()
  return self:get_font():get_height() + style.padding.y
end


function CommandView:update_suggestions()
  local text = self:get_text()
  local t = self.state.suggest(self.last_change == "suggestion" and self.user_supplied_text or text) or {}
  local res = {}
  for i, item in ipairs(t) do
    if type(item) == "string" then
      item = { text = item }
    end
    res[i] = item
  end
  if self.suggestions and self.last_change == "suggestion" then
    local new_suggestion_idx
    for i, v in ipairs(res) do
      if v.text == self.suggestions[self.suggestion_idx].text then
        new_suggestion_idx = i
        break
      end
    end
    self.suggestion_idx = new_suggestion_idx
    -- This preserves the suggestion_offset and realigns it with the new table.
    self:move_suggestion_idx(0)
  else
    self.suggestion_idx = 1
    self.suggestions_offset = 1
  end
  self.suggestions = res
end


function CommandView:update()
  CommandView.super.update(self)

  if self.button_pressed and self.button_pressed.repeat_while_pressed then
    local now = system.get_time()
    local delay = self.button_pressed.repeat_delay or 0.35
    if self.button_repeat_start and now - self.button_repeat_start >= delay then
      local interval = self:get_button_repeat_interval(self.button_pressed, now)
      if not self.button_repeat_last or now - self.button_repeat_last >= interval then
        self.button_repeat_last = now
        self:trigger_button_action(self.button_pressed)
      end
    end
  end

  if core.active_view ~= self
    and self.state ~= default_state
    and not self.state.keep_open_on_focus_loss then
    if is_find_command_view(self) then
      append_find_debug_log(
        "commandview.update_inexplicit_exit label=%q active_view=%s keep_open=%s",
        tostring(self.label),
        tostring(core.active_view),
        tostring(self.state and self.state.keep_open_on_focus_loss)
      )
    end
    self:exit(false, true)
  end

  -- update suggestions if text has changed
  if self.last_change_id ~= self.doc:get_change_id() then
    self.last_change = "text"
    self.user_supplied_text = self:get_text()
    self:update_suggestions()
    if self.state.typeahead and self.suggestions[self.suggestion_idx] then
      local current_text = self:get_text()
      local suggested_text = self.suggestions[self.suggestion_idx].text or ""
      if #self.last_text < #current_text and
         string.find(suggested_text, current_text, 1, true) == 1 then
        self:set_text(suggested_text)
        self.doc:set_selection(1, #current_text + 1, 1, math.huge)
      end
      self.last_text = current_text
    end
    self.last_change_id = self.doc:get_change_id()
  end

  -- update gutter text color brightness
  self:move_towards("gutter_text_brightness", 0, 0.1, "commandview")

  -- update gutter width
  local dest = self:get_font():get_width(self.label) + style.padding.x
  if self.size.y <= 0 then
    self.gutter_width = dest
  else
    self:move_towards("gutter_width", dest, nil, "commandview")
  end
  self:update_button_layout()

  -- update suggestions box height
  local lh = self:get_suggestion_line_height()
  local dest = self.state.show_suggestions and math.min(#self.suggestions, config.max_visible_commands) * lh or 0
  self:move_towards("suggestions_height", dest, nil, "commandview")

  -- update suggestion cursor offset
  local dest = (self.suggestion_idx - self.suggestions_offset + 1) * self:get_suggestion_line_height()
  self:move_towards("selection_offset", dest, nil, "commandview")

  -- update size based on whether this is the active_view
  local dest = 0
  if self == core.active_view or self:is_persistent_open() then
    dest = style.font:get_height() + style.padding.y * 2
  end
  self:move_towards(self.size, "y", dest, nil, "commandview")
end


function CommandView:draw_line_highlight()
  -- no-op function to disable this functionality
end


function CommandView:draw_line_gutter(idx, x, y)
  local yoffset = self:get_line_text_y_offset()
  local pos = self.position
  local color = common.lerp(style.text, style.accent, self.gutter_text_brightness / 100)
  core.push_clip_rect(pos.x, pos.y, self:get_gutter_width(), self.size.y)
  x = x + style.padding.x
  renderer.draw_text(self:get_font(), self.label, x, y + yoffset, color)
  core.pop_clip_rect()
  return self:get_line_height()
end


local function draw_suggestions_box(self)
  local lh = self:get_suggestion_line_height()
  local dh = style.divider_size
  local x, _ = self:get_line_screen_position()
  local h = math.ceil(self.suggestions_height)
  local rx, ry, rw, rh = self.position.x, self.position.y - h - dh, self.size.x, h

  core.push_clip_rect(rx, ry, rw, rh)
  -- draw suggestions background
  if #self.suggestions > 0 then
    renderer.draw_rect(rx, ry, rw, rh, style.background3)
    renderer.draw_rect(rx, ry - dh, rw, dh, style.divider)
    local y = self.position.y - self.selection_offset - dh
    renderer.draw_rect(rx, y, rw, lh, style.line_highlight)
  end

  -- draw suggestion text
  local first = math.max(self.suggestions_offset, 1)
  local last = math.min(self.suggestions_offset + config.max_visible_commands, #self.suggestions)
  for i=first, last do
    local item = self.suggestions[i]
    local color = (i == self.suggestion_idx) and style.accent or style.text
    local y = self.position.y - (i - first + 1) * lh - dh
    common.draw_text(self:get_font(), color, item.text, nil, x, y, 0, lh)

    if item.info then
      local w = self.size.x - x - style.padding.x
      common.draw_text(self:get_font(), style.dim, item.info, "right", x, y, w, lh)
    end
  end
  core.pop_clip_rect()
end


function CommandView:draw()
  self:draw_background(style.background2)
  local lh = self:get_line_height()
  local minline, maxline = 1, 1
  local x, y = self:get_line_screen_position(minline)
  local text_clip_w = math.max(
    0,
    self.size.x - self:get_gutter_width() - self:get_buttons_width() - style.padding.x
  )
  self:draw_line_gutter(1, self.position.x, y, self:get_gutter_width())
  core.push_clip_rect(self.position.x + self:get_gutter_width(), self.position.y, text_clip_w, self.size.y)
  self:draw_line_body(1, x, y)
  self:draw_overlay()
  core.pop_clip_rect()

  for i, rect in ipairs(self.button_rects or {}) do
    local hovered = self.button_hovered == i
    local bg = hovered and style.line_highlight or style.background3
    local fg = hovered and (style.accent or style.text) or style.text
    renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, bg)
    common.draw_text(self:get_font(), fg, self:get_button_text(rect.button), "center", rect.x, rect.y, rect.w, rect.h)
  end
  if self.state.show_suggestions then
    core.root_view:defer_draw(draw_suggestions_box, self)
  end
end

function CommandView:on_mouse_moved(x, y, dx, dy)
  local rect = self:get_button_rect_at(x, y)
  self.button_hovered = rect and select(2, self:get_button_rect_at(x, y)) or nil
  if self.button_pressed and (not rect or rect.button ~= self.button_pressed) then
    self:clear_button_press()
  end
  if self.button_hovered then
    self.cursor = "hand"
    return true
  end
  return CommandView.super.on_mouse_moved(self, x, y, dx, dy)
end

function CommandView:on_mouse_left()
  self.button_hovered = nil
  self:clear_button_press()
  return CommandView.super.on_mouse_left(self)
end

function CommandView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    local rect = self:get_button_rect_at(x, y)
    if rect then
      self.button_pressed = rect.button
      self.button_repeat_start = system.get_time()
      self.button_repeat_last = nil
      self:trigger_button_action(rect.button)
      return true
    end
  end
  return CommandView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function CommandView:on_mouse_released(button, x, y, clicks)
  if button == "left" and self.button_pressed then
    self:clear_button_press()
    return true
  end
  return CommandView.super.on_mouse_released(self, button, x, y, clicks)
end

return CommandView
