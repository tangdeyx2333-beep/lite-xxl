local style = require "core.style"
local common = require "core.common"

-- Sublime Text inspired dark theme (subdued)
style.background = { common.color "#22262D" }  -- Docview
style.background2 = { common.color "#181C21" } -- Treeview / Tab bar
style.background3 = { common.color "#181C21" } -- Command view
style.text = { common.color "#9098A4" }
style.caret = { common.color "#4A7FCF" }
style.find_match = { 0xFF, 0x8C, 0x00, 0xFF }
style.find_match_text = { 0xFF, 0xFF, 0xFF, 0xFF }
style.accent = { common.color "#B0B8C4" }
-- style.dim - text color for nonactive tabs, tabs divider, prefix in log and
-- search result, hotkeys for context menu and command view
style.dim = { common.color "#4A5059" }
style.divider = { common.color "#111418" } -- Line between nodes
style.selection = { common.color "#2A323D" }
style.line_number = { common.color "#333A42" }
style.line_number2 = { common.color "#5A6570" } -- With cursor
style.line_highlight = { common.color "#252A31" }
style.scrollbar = { common.color "#353C44" }
style.scrollbar2 = { common.color "#414851" } -- Hovered
style.scrollbar_track = { common.color "#181C21" }
style.nagbar = { common.color "#FF0000" }
style.nagbar_text = { common.color "#FFFFFF" }
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.45)" }
style.drag_overlay = { common.color "rgba(255,255,255,0.1)" }
style.drag_overlay_tab = { common.color "#4A7FCF" }
style.good = { common.color "#5A9E6E" }
style.warn = { common.color "#D4883D" }
style.error = { common.color "#CC2A2A" }
style.modified = { common.color "#B8A858" }

style.syntax["normal"] = { common.color "#A0A8B4" }
style.syntax["symbol"] = { common.color "#A0A8B4" }
style.syntax["comment"] = { common.color "#4A4F54" }
style.syntax["keyword"] = { common.color "#B56A9C" }  -- local function end if case
style.syntax["keyword2"] = { common.color "#C05A66" } -- self int float
style.syntax["number"] = { common.color "#D4883D" }
style.syntax["literal"] = { common.color "#D4883D" }  -- true false nil
style.syntax["string"] = { common.color "#C4A046" }
style.syntax["operator"] = { common.color "#6AA8C4" } -- = + - / < >
style.syntax["function"] = { common.color "#6AA8C4" }

style.log["INFO"]  = { icon = "i", color = style.text }
style.log["WARN"]  = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
