-- mod-version:4
local syntax = require "core.syntax"

syntax.add {
  name = "Less",
  files = { "%.less$" },
  block_comment = { "/*", "*/" },
  patterns = {
    -- 解析阶段：先处理行注释和块注释，避免 Less 的变量和 mixin 语法被注释打断。
    { pattern = "//.*",                type = "comment"  },
    { pattern = { "/%*", "%*/" },      type = "comment"  },
    { pattern = { '"', '"', '\\' },    type = "string"   },
    { pattern = { "'", "'", '\\' },    type = "string"   },
    -- 解析阶段：变量、函数式混入和 `&` 连接符是 Less 的核心扩展点，优先突出。
    { pattern = "@[%a_][%w_%-]*",      type = "keyword2" },
    { pattern = "&",                   type = "keyword2" },
    { pattern = "[%a_][%w_%-]*%s*%f[:{]", type = "keyword" },
    -- 值阶段：颜色、单位和数值优先匹配，减少普通文本对样式值的干扰。
    { pattern = "#%x%x%x%x%x%x%f[%W]", type = "string"   },
    { pattern = "#%x%x%x%f[%W]",      type = "string"   },
    { pattern = "-?%d+[%d%.]*p[xt]",  type = "number"   },
    { pattern = "-?%d+[%d%.]*deg",    type = "number"   },
    { pattern = "-?%d+[%d%.]*[s%%]",  type = "number"   },
    { pattern = "-?%d+[%d%.]*",       type = "number"   },
    -- 收尾阶段：大括号、分号和冒号按结构符号处理，剩余内容作为普通符号。
    { pattern = "[{}:;,]",            type = "operator" },
    { pattern = "[%a_][%w_%-]*",      type = "symbol"   },
  },
  symbols = {
    ["true"] = "literal",
    ["false"] = "literal",
    ["none"] = "literal",
  }
}
