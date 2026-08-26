-- mod-version:4

local syntax = require "core.syntax"
local style = require "core.style"
local common = require "core.common"

-- 准备阶段：为 ignore 文件单独补充包含/排除规则的颜色，方便后续语法规则直接复用。
style.syntax["ignore"] = { common.color "#72B886" }
style.syntax["exclude"] = { common.color "#F36161" }

syntax.add {
  name = ".ignore file",
  files = { PATHSEP .. "%..*ignore$" },
  comment = "#",
  patterns = {
    -- 解析阶段：先识别注释行，避免注释内容被误判成包含或排除规则。
    { regex = "^ *#.*$",            type = "comment" },
    -- 解析阶段：以 `!` 开头的规则表示重新包含，单独用 ignore 类型突出显示。
    { regex = { "(?=^ *!.)", "$" }, type = "ignore"  },
    -- 收尾阶段：剩余非空规则按排除项处理，这是 ignore 文件的默认语义。
    { regex = { "(?=.)", "$" },     type = "exclude" },
  },
  symbols = {}
}
