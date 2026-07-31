local style = require "core.style"
local common = require "core.common"

-- 中文说明：这一步是在 default 深色主题的基础上，往 Sublime 那种“背景偏暗、正文更亮、层级更柔和”的方向调整；
-- 目标不是做更黑的主题，而是把正文、行号、标签和选中态的对比度拉到更耐看的区间。
style.background = { common.color "#2D333B" }  -- 编辑区主背景，保持深色但比 default 更通透
style.background2 = { common.color "#252B32" } -- 侧边栏 / 标签栏背景，和编辑区拉开轻微层次
style.background3 = { common.color "#252B32" } -- 命令面板 / 浮层背景，沿用同一层级避免界面碎
style.text = { common.color "#D8DEE7" }        -- 主文本颜色，明显提亮，优先解决“看着费劲”
style.caret = { common.color "#78A9FF" }       -- 光标颜色保持冷色，便于在大段文本里快速定位
style.find_match = { 0xE8, 0xA6, 0x4B, 0xFF }
style.find_match_text = { 0xFF, 0xFF, 0xFF, 0xFF }
style.accent = { common.color "#EDF3FB" }      -- 当前标签 / 强调态更亮，靠近 Sublime 的清爽观感
style.dim = { common.color "#7F8A97" }         -- 非激活信息提亮一些，避免侧栏和标签字发灰发糊
style.divider = { common.color "#20252B" }     -- 分隔线压暗，减少界面噪声
style.selection = { common.color "#3A4654" }   -- 选中区提高可见性，但避免过蓝刺眼
style.line_number = { common.color "#55606D" }
style.line_number2 = { common.color "#A8B2BF" } -- 当前行号提亮，方便视线跟踪
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
style.syntax["keyword"] = { common.color "#C792EA" }  -- 关键字用柔和紫色，靠近 Sublime 常见观感
style.syntax["keyword2"] = { common.color "#F07178" } -- 类型 / 次关键字改成暖红，和 keyword 拉开职责
style.syntax["number"] = { common.color "#F2AE49" }
style.syntax["literal"] = { common.color "#F2AE49" }
style.syntax["string"] = { common.color "#C3E88D" }
style.syntax["operator"] = { common.color "#89DDFF" }
style.syntax["function"] = { common.color "#82AAFF" }

style.log["INFO"]  = { icon = "i", color = style.text }
style.log["WARN"]  = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
