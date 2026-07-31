local style = require "core.style"
local common = require "core.common"

-- 中文说明：这一步是在 default 深色主题的基础上，往 Sublime 那种“背景偏暗、正文更亮、层级更柔和”的方向调整；
-- 目标不是做更黑的主题，而是把正文、行号、标签和选中态的对比度拉到更耐看的区间。
style.background = { common.color "#2D333B" }
style.background2 = { common.color "#252B32" }
style.background3 = { common.color "#252B32" }
style.text = { common.color "#D8DEE7" }
style.caret = { common.color "#78A9FF" }
style.find_match = { 0xE8, 0xA6, 0x4B, 0xFF }
style.find_match_text = { 0xFF, 0xFF, 0xFF, 0xFF }
style.accent = { common.color "#EDF3FB" }
style.dim = { common.color "#7F8A97" }
style.divider = { common.color "#20252B" }
style.selection = { common.color "#3A4654" }
style.line_number = { common.color "#55606D" }
style.line_number2 = { common.color "#A8B2BF" }
style.line_highlight = { common.color "#313840" }
style.scrollbar = { common.color "#46515D" }
style.scrollbar2 = { common.color "#5A6674" }
style.scrollbar_track = { common.color "#252B32" }
style.nagbar = { common.color "#D84F4F" }
style.nagbar_text = { common.color "#FFFFFF" }
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.45)" }
style.drag_overlay = { common.color "rgba(255,255,255,0.08)" }
style.drag_overlay_tab = { common.color "#78A9FF" }
style.good = { common.color "#73B580" }
style.warn = { common.color "#E0A458" }
style.error = { common.color "#D96C6C" }
style.modified = { common.color "#D7C06F" }

-- 中文说明：上面是在组装界面层配色；下面开始组装语法高亮层配色，核心目标是“正文亮、注释柔和、关键 token 有区分但不过分跳”。
style.syntax["normal"] = { common.color "#D8DEE7" }
style.syntax["symbol"] = { common.color "#D8DEE7" }
style.syntax["comment"] = { common.color "#7B8794" }
style.syntax["keyword"] = { common.color "#C792EA" }
style.syntax["keyword2"] = { common.color "#F07178" }
style.syntax["number"] = { common.color "#F2AE49" }
style.syntax["literal"] = { common.color "#F2AE49" }
style.syntax["string"] = { common.color "#C3E88D" }
style.syntax["operator"] = { common.color "#89DDFF" }
style.syntax["function"] = { common.color "#82AAFF" }

style.log["INFO"]  = { icon = "i", color = style.text }
style.log["WARN"]  = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
