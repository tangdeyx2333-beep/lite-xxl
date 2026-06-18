local core = require "core"
local command = require "core.command"
local CommandView = require "core.commandview"

local function resolve_escape_target()
  if core.active_view and core.active_view:is(CommandView) then
    return true, core.active_view
  end

  local cv = core.command_view
  if cv and cv:is_persistent_open() then
    return true, cv
  end

  return false
end

command.add("core.commandview", {
  ["command:submit"] = function(active_view)
    active_view:submit()
  end,

  ["command:complete"] = function(active_view)
    active_view:complete()
  end,

  ["command:select-previous"] = function(active_view)
    active_view:move_suggestion_idx(1)
  end,

  ["command:select-next"] = function(active_view)
    active_view:move_suggestion_idx(-1)
  end,
})

command.add(resolve_escape_target, {
  ["command:escape"] = function(command_view)
    -- 中文说明：Esc 优先关闭当前 CommandView；
    -- 如果 find 以持久显示方式挂在底部，即使焦点回到文档也仍然能关闭它。
    command_view:exit(false)
  end,
})
