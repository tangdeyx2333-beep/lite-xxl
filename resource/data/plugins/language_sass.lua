-- mod-version:4
local syntax = require "core.syntax"

syntax.add {
  name = "Sass",
  files = { "%.sass$" ,"%.scss$"},
  comment = "//",
  patterns = {
    -- 解析阶段：先吃掉行内或块注释，避免后面的变量、选择器和函数名被误判。
    { pattern = "/[/%*].-\n",             type = "comment"  },
    { pattern = { '"', '"', '\\' },       type = "string"   },
    { pattern = { "'", "'", '\\' },       type = "string"   },
    -- 解析阶段：Sass/SCSS 的变量和注解语法先单独识别，保持和上游插件一致的阅读方式。
    { pattern = "$%w+",                   type = "keyword"  },
    { pattern = "@%w+",                   type = "literal"  },
    { pattern = "[#,]%w+",                type = "function" },
    { pattern = "&",                      type = "keyword2" },
    -- 解析阶段：结构符号优先处理，保证嵌套规则和属性分隔符可读。
    { pattern = "[:%/%*%-]",              type = "operator" },
    { pattern = "[%a][%w-]*%s*%f[:]",     type = "keyword2" },
    -- 值阶段：尺寸、角度和时间单位沿用现成的匹配方式，避免数字被拆散。
    { pattern = "-?%d+[%d%.]*p[xt]",      type = "number"   },
    { pattern = "-?%d+[%d%.]*deg",        type = "number"   },
    { pattern = "-?%d+[%d%.]*[s%%]",      type = "number"   },
    { pattern = "-?%d+[%d%.]*",           type = "number"   },
    -- 收尾阶段：其余标识符作为普通符号，便于继续区分变量、函数和选择器。
    { pattern = "[%a_][%w_]*",            type = "symbol"   },
  },
  symbols = {
    ["transparent"] = "literal",
    ["none"]        = "literal",
    ["absolute"]    = "literal",
    ["relative"]    = "literal",
    ["solid"]       = "literal",
    ["flex"]        = "literal",
    ["flex-start"]  = "literal",
    ["flex-end"]    = "literal",
    ["row"]         = "literal",
    ["center"]      = "literal",
    ["column"]      = "literal",
    ["pointer"]     = "literal",
    ["ease"]        = "literal",
    ["white"]      = "function",
    ["black"]      = "function",
    ["gray"]       = "function",
    ["blue"]       = "function",
    ["red"]        = "function",
    ["purple"]     = "function",
    ["green"]      = "function",
    ["yellow"]     = "function"
  }
}
