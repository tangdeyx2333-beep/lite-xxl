-- 用户配置文件
-- 此文件在 Lite XL 启动时自动加载
-- 只需保存此文件即可热更新配置（无需重启）

local core = require "core"
local config = require "core.config"
local style = require "core.style"

------------------------------ Themes ----------------------------------------

-- 切换到亮色主题
-- core.reload_module("colors.summer")

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


-- 大文件/WLPT 停滚多久后才恢复高亮，单位秒；值越大越保滚动性能
config.large_file_highlight_scroll_idle_delay = 0.18

-- 注意：此功能仅为性能优化，开启后将关闭语法高亮，显示效果仅供参考，不保证准确性。
-- 建议：在大文件场景下关闭高亮，可获得更佳的编辑性能与流畅度体验。
config.large_file_disable_highlight = false

-------------------------- Miscellaneous -------------------------------------

-- 修改要忽略的文件列表（用于项目索引）
-- config.ignore_files = {
--   "^%.git/",
--   "^node_modules/",
--   "%.pyc$",
--   "%.o$",
-- }
