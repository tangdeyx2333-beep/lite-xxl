local common = require "core.common"

local config = {}

---The frame rate of Lite XL.
---Note that setting this value to the screen's refresh rate
---does not eliminate screen tearing.
---
---Defaults to 60.
---@type number
config.fps = 60

---Maximum number of log items that will be stored.
---When the number of log items exceed this value, old items will be discarded.
---
---Defaults to 800.
---@type number
config.max_log_items = 800

---The timeout, in seconds, before a message dissapears from StatusView.
---
---Defaults to 5.
---@type number
config.message_timeout = 5

---The number of pixels scrolled per-step.
---
---Defaults to 50 * SCALE.
---@type number
config.mouse_wheel_scroll = 50 * SCALE

---Enables/disables transitions when scrolling with the scrollbar.
---When enabled, the scrollbar will have inertia and slowly move towards the cursor.
---Otherwise, the scrollbar will immediately follow the cursor.
---
---Defaults to false.
---@type boolean
config.animate_drag_scroll = false

---Enables/disables scrolling past the end of a document.
---
---Defaults to true.
---@type boolean
config.scroll_past_end = true

---@alias config.scrollbartype
---| "expanded" # A thicker scrollbar is shown at all times.
---| "contracted" # A thinner scrollbar is shown at all times.
---| false # The scrollbar expands when the cursor hovers over it.

---Controls whether the DocView scrollbar is always shown or hidden.
---This option does not affect other View's scrollbars.
---
---Defaults to false.
---@type config.scrollbartype
config.force_scrollbar_status = false

---The file size limit, in megabytes.
---Files larger than this size will not be shown in the file picker.
---
---Defaults to 10.
---@type number
config.file_size_limit = 10

---The large file threshold, in megabytes.
---Files larger than this size will be loaded on a coroutine with strict time slicing.
---
---Defaults to 32.
---@type number
config.large_file_size_limit = 32

---The wlpt file threshold, in mebibytes.
---Files larger than this size will default to the `wlpt` document path.
---
---Defaults to 1.
---@type number
config.wlpt_file_size_limit = 1

---Maximum amount of time, in seconds, that large-file loading work may use
---before yielding back to the main loop.
---
---Defaults to 0.001.
---@type number
config.large_file_load_time_budget = 0.001

---Chunk size, in bytes, read from disk for large-file loading.
---
---Defaults to 16384.
---@type integer
config.large_file_read_chunk_size = 16 * 1024

---Automatically disable syntax highlighting for large files.
---
---Defaults to false.
---@type boolean
config.large_file_disable_highlight = false

---Automatically disable undo/redo tracking for large files.
---
---Defaults to true.
---@type boolean
config.large_file_disable_undo = true

---是否为 wl/wlpt 大文件模式启用“停稳后快速窗口高亮”。
---
---开启后，大文件在滚动过程中仍然按纯文本绘制；
---只有当视图停止滚动一小段时间后，才会尝试对当前可视窗口做一次轻量语法高亮。
---
---是否为 wl/wlpt 大文件模式启用“真实语法轻量功能通道”。
---
---开启后，大文件模式仍然保持纯文本或局部高亮绘制策略，
---不会恢复全文语法高亮；
---但命令层可以继续读取文件的真实 syntax 信息，用于注释切换等轻量语法功能。
---
---这个开关的目标是尽量恢复“大文件下与文件格式相关、但不依赖全文高亮”的行为；
---如果你怀疑它导致卡顿或兼容性问题，可以随时关闭。
---
---默认值：false
---@type boolean
config.large_file_enable_syntax_features = false

---Fixed line count for each large-file chunk transferred from the native backend.
---
---Defaults to 256.
---@type integer
config.large_file_window_chunk_lines = 256

---Number of neighbor chunks to prefetch on each side of the visible viewport.
---
---Defaults to 1.
---@type integer
config.large_file_window_buffer_chunks = 1

---Maximum number of large-file chunks kept in Lua cache at once.
---
---Defaults to 8.
---@type integer
config.large_file_window_max_cached_chunks = 8

---Delay, in seconds, before large-file/WLPT chunk highlighting resumes after scrolling stops.
---Higher values favor scroll smoothness over highlight responsiveness.
---
---Defaults to 0.18.
---@type number
config.large_file_highlight_scroll_idle_delay = 0.18

---Enable scheduler/thread debug logging to `scheduler.log` in USERDIR.
---
---Defaults to false.
---@type boolean
config.scheduler_log = false

---Log a scheduler entry when a single thread resume takes at least this many seconds.
---
---Defaults to 0.002.
---@type number
config.scheduler_slow_resume_threshold = 0.002

---Freeze non-active document background work on the main thread.
---
---Defaults to true.
---@type boolean
config.inactive_freeze_policy = true

---A list of files and directories to ignore.
---Each element is a Lua pattern, where patterns ending with a forward slash
---are recognized as directories while patterns ending with an anchor ("$") are
---recognized as files.
---@type string[]
config.ignore_files = {
  -- folders
  "^%.svn/",        "^%.git/",   "^%.hg/",        "^CVS/", "^%.Trash/", "^%.Trash%-.*/",
  "^node_modules/", "^%.cache/", "^__pycache__/",
  -- files
  "%.pyc$",         "%.pyo$",       "%.exe$",        "%.dll$",   "%.obj$", "%.o$",
  "%.a$",           "%.lib$",       "%.so$",         "%.dylib$", "%.ncb$", "%.sdf$",
  "%.suo$",         "%.pdb$",       "%.idb$",        "%.class$", "%.psd$", "%.db$",
  "^desktop%.ini$", "^%.DS_Store$", "^%.directory$",
}

---Lua pattern used to find symbols when advanced syntax highlighting
---is not available.
---This pattern is also used for navigation, e.g. move to next word.
---
---The default pattern matches all letters, followed by any number
---of letters and digits.
---@type string
config.symbol_pattern = "[%a_][%w_]*"

---A list of characters that delimits a word.
---
---The default is ``" \t\n/\\()\"':,.;<>~!@#$%^&*|+=[]{}`?-"``
---@type string
config.non_word_chars = " \t\n/\\()\"':,.;<>~!@#$%^&*|+=[]{}`?-"

---The timeout, in seconds, before several consecutive actions
---are merged as a single undo step.
---
---The default is 0.3 seconds.
---@type number
config.undo_merge_timeout = 0.3

---The maximum number of undo steps per-document.
---
---The default is 10000.
---@type number
config.max_undos = 10000

---The maximum number of tabs shown at a time.
---
---The default is 8.
---@type number
config.max_tabs = 8

---The maximum number of entries shown at a time in the command palette.
---
---The default is 10.
---@type integer
config.max_visible_commands = 10

---Shows/hides the tab bar when there is only one tab open.
---
---The tab bar is always shown by default.
---@type boolean
config.always_show_tabs = true

---@alias config.highlightlinetype
---| true # Always highlight the current line.
---| false # Never highlight the current line.
---| "no_selection" # Highlight the current line if no text is selected.

---Highlights the current line.
---
---The default is true.
---@type config.highlightlinetype
config.highlight_current_line = true

---The spacing between each line of text.
---
---The default is 120% of the height of the text (1.2).
---@type number
config.line_height = 1.2

---The number of spaces each level of indentation represents.
---
---The default is 2.
---@type number
config.indent_size = 2

---The type of indentation.
---
---The default is "soft" (spaces).
---@type "soft" | "hard"
config.tab_type = "soft"

---Do not remove whitespaces when advancing to the next line.
---
---Defaults to false.
---@type boolean
config.keep_newline_whitespace = false

---Default line endings for new files.
---
---Defaults to `crlf` (`\r\n`) on Windows and `lf` (`\n`) on everything else.
---@type "crlf" | "lf"
config.line_endings = PLATFORM == "Windows" and "crlf" or "lf"

---Maximum number of characters per-line for the line guide.
---
---Defaults to 80.
---@type number
config.line_limit = 80

---Enables/disables all transitions.
---
---Defaults to true.
---@type boolean
config.transitions = true

---Enable/disable individual transitions.
---These values are overriden by `config.transitions`.
config.disabled_transitions = {
  ---Disables scrolling transitions.
  scroll = false,
  ---Disables transitions for CommandView's suggestions list.
  commandview = false,
  ---Disables transitions for showing/hiding the context menu.
  contextmenu = false,
  ---Disables transitions when clicking on log items in LogView.
  logview = false,
  ---Disables transitions for showing/hiding the Nagbar.
  nagbar = false,
  ---Disables transitions when scrolling the tab bar.
  tabs = false,
  ---Disables transitions when a tab is being dragged.
  tab_drag = false,
  ---Disables transitions when a notification is shown.
  statusbar = false,
}

---The rate of all transitions.
---
---Defaults to 1.
---@type number
config.animation_rate = 1.0

---The caret's blinking period, in seconds.
---
---Defaults to 0.8.
---@type number
config.blink_period = 0.8

---Disables caret blinking.
---
---Defaults to false.
---@type boolean
config.disable_blink = false

---Draws whitespaces as dots.
---This option is deprecated.
---Please use the drawwhitespace plugin instead.
---@deprecated
config.draw_whitespace = false

---Disables system-drawn window borders.
---
---When set to true, Lite XL draws its own window decorations,
---which can be useful for certain setups.
---
---Defaults to false.
---@type boolean
config.borderless = false

---Shows/hides the close buttons on tabs.
---When hidden, users can close tabs via keyboard shortcuts or commands.
---
---Defaults to true.
---@type boolean
config.tab_close_button = true

---Maximum number of clicks recognized by Lite XL.
---
---Defaults to 3.
---@type number
config.max_clicks = 3

---Disables plugin version checking.
---Do not change this unless you know what you are doing.
---
---Defaults to false.
---@type boolean
config.skip_plugins_version = false

---Increases the performance of the editor and its user.
---Do not change this unless you know what you are doing.
---
---Defaults to true.
---@type boolean | { font: renderer.font, icon: string } | nil
config.stonks = true

---Use the system file picker instead of the command palette
---when opening files.
---
---Defaults to false if no sandbox is detected.
---@type boolean
config.use_system_file_picker = system.get_sandbox() ~= "none"

-- holds the plugins real config table
local plugins_config = {}

---A table containing configuration for all the plugins.
---
---This is a metatable that automaticaly creates a minimal
---configuration when a plugin is initially configured.
---Each plugins will then call `common.merge()` to get the finalized
---plugin config.
---Do not use raw operations on this table.
---@type table
config.plugins = {}

-- allows virtual access to the plugins config table
setmetatable(config.plugins, {
  __index = function(_, k)
    if not plugins_config[k] then
      plugins_config[k] = { enabled = true, config = {} }
    end
    if plugins_config[k].enabled ~= false then
      return plugins_config[k].config
    end
    return false
  end,
  __newindex = function(_, k, v)
    if not plugins_config[k] then
      plugins_config[k] = { enabled = nil, config = {} }
    end
    if v == false and package.loaded["plugins."..k] then
      local core = require "core"
      core.warn("[%s] is already enabled, restart the editor for the change to take effect", k)
      return
    elseif plugins_config[k].enabled == false and v ~= false then
      plugins_config[k].enabled = true
    end
    if v == false then
      plugins_config[k].enabled = false
    elseif type(v) == "table" then
      plugins_config[k].enabled = true
      plugins_config[k].config = common.merge(plugins_config[k].config, v)
    end
  end,
  __pairs = function()
    return coroutine.wrap(function()
      for name, status in pairs(plugins_config) do
        coroutine.yield(name, status.config)
      end
    end)
  end
})


return config
