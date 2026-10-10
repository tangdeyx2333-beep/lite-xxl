-- 用户配置文件
-- 此文件在 Lite XL 启动时自动加载
-- 只需保存此文件即可热更新配置（无需重启）

local core = require "core"
local config = require "core.config"
local style = require "core.style"

------------------------------ Themes ----------------------------------------

-- 切换到亮色主题
-- core.reload_module("colors.summer")
-- 中文说明：下面这些值都是当前内建支持的主题名，四选一即可。
-- config.theme = "default"
-- config.theme = "fall"
config.theme = "sublime_dark"
-- config.theme = "summer"
-- config.theme = "textadept"
--------------------------- Key bindings -------------------------------------

-- 键位绑定
-- keymap.add { ["ctrl+escape"] = "core:quit" }

----------------------------- Font Settings ----------------------------------

-- 字体大小设置 (修改后保存即可热更新)
local font_size = 15
-- 编辑框字体大小
local code_font_size = 21

-- 字体列表
local font_path = DATADIR .. "/fonts"
local fonts = {
    --阿里巴巴普惠体
    ui = "AlibabaPuHuiTi-3-85-Bold.ttf",
    code = "AlibabaPuHuiTi-3-85-Bold.ttf",
    -- 其他可选字体
    -- ui = "FiraSans-Regular.ttf",
    -- code = "JetBrainsMono-Regular.ttf",
    -- code = "NotoSerifSC-VariableFont_wght.ttf",
}

-- 加载界面字体
style.font = renderer.font.load(
    font_path .. "/" .. fonts.ui,
    font_size * SCALE,
    {antialiasing="grayscale", hinting="full"}
)

-- 加载代码字体
style.code_font = renderer.font.load(
    font_path .. "/" .. fonts.code,
    code_font_size * SCALE,
    {antialiasing="grayscale", hinting="full"}
)

-- 加载图标字体
style.icon_font = renderer.font.load(
    font_path .. "/icons.ttf",
    16 * SCALE
)

-- 加载大号图标字体 (用于工具栏)
style.icon_big_font = renderer.font.load(
    font_path .. "/icons.ttf",
    24 * SCALE
)

-- 欢迎页大标题字体
style.big_font = renderer.font.load(
    font_path .. "/" .. fonts.ui,
    24 * SCALE
)
  

----------------------------- Plugins Settings -------------------------------

-- 禁用插件
-- config.plugins.detectindent = false
-- config.plugins.trimwitespace = false

-- 设置文件树大小
config.plugins.treeview.size = 0
config.plugins.treeview.open_file_size = 256
config.plugins.treeview.open_project_size = 256
config.plugins.treeview.visible = true
config.plugins.treeview.highlight_focused_file = true
config.plugins.treeview.expand_dirs_to_focused_file = true
config.plugins.treeview.scroll_to_focused_file = true
config.plugins.treeview.animate_scroll_to_focused_file = true

-- 自动补全弹窗触发所需最少输入字符数；值越小越容易触发弹窗
config.plugins.autocomplete.min_len = 2

-- 大文件/WLPT 停滚多久后才恢复高亮，单位秒；值越大越保滚动性能
config.large_file_highlight_scroll_idle_delay = 0.18

-- WLPT 大文件阈值，单位 MiB；超过这个大小会走 WLPT 大文件链路
config.wlpt_file_size_limit = 2

-- 全局无痕状态在多窗口之间同步的轮询间隔，单位秒；值越大越省性能，但其他窗口同步会更慢
config.clean_exit_global_sync_interval = 1

-- 临时保存检查间隔，单位秒；负责定期检查是否到了可保存时机
config.instance_snapshot_autosave_interval = 5

-- 输入停止后等待多久才执行临时保存，单位秒
config.instance_snapshot_autosave_after_idle = 10

-- 是否在 WLPT 模式下禁用 Markdown 渲染预览；true 表示禁用，false 表示允许
-- 注意这个如果文件过大渲染会有明显卡顿，并且有几率无响应，无响应强制退出会有丢失数据的风险
config.wlpt_disable_markdown_render = false 

-- 注意：此功能仅为性能优化；true 表示开启大文件语法高亮，false 表示关闭高亮。
-- 建议：在大文件场景下如需更高流畅度，可将它设为 false。
config.large_file_enable_highlight = true

-------------------------- Miscellaneous -------------------------------------

-- 修改要忽略的文件列表（用于项目索引）
-- config.ignore_files = {
--   "^%.git/",
--   "^node_modules/",
--   "%.pyc$",
--   "%.o$",
-- }
