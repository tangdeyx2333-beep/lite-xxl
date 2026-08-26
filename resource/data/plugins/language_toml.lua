-- mod-version:4

local syntax = require "core.syntax"

syntax.add {
  name = "TOML",
  files = { "%.toml$" },
  comment = "#",

  patterns = {
    -- 解析阶段：先处理注释，避免注释里的等号、日期或数组符号干扰后续规则。
    { pattern = "#.*",                                type = "comment"  },

    -- 值阶段：字符串规则放在前面，保证多行字符串和普通字符串优先被整体消费。
    { pattern = { '"""', '"""', '\\' },               type = "string"   },
    { pattern = { "'''", "'''"       },               type = "string"   },
    { pattern = { '"',   '"',   '\\' },               type = "string"   },
    { pattern = { "'",   "'"         },               type = "string"   },

    -- 键阶段：等号左侧字段是 TOML 配置项名称，作为主要索引用 function 类型显示。
    { pattern = "[%w_%.%-]+%s*%f[=]",                 type = "function" },

    -- 结构阶段：表头和数组表头决定当前配置分组，需要优先突出显示。
    { pattern = {"^%s*%[", "%]"},                     type = "keyword"  },

    -- 值阶段：按 TOML 数字格式从特殊进制到普通浮点依次识别，避免前缀数字被截断。
    { pattern = "0x[%x_]+",                           type = "number"   },
    { pattern = "0o[0-7_]+",                          type = "number"   },
    { pattern = "0b[01_]+",                           type = "number"   },
    { pattern = "%d[%d_]*%.?[%d_]*[eE][%-+]?[%d_]+",  type = "number"   },
    { pattern = "%d[%d_]*%.?[%d_]*",                  type = "number"   },
    { pattern = "%f[-+%w_][-+]%f[%w%.]",              type = "number"   },

    -- 收尾阶段：日期时间分隔符和普通单词最后处理，避免抢占更精确的键和值。
    { pattern = "[%+%-:TZ]",                          type = "operator" },
    { pattern = "%a+",                                type = "symbol"   },
  },

  symbols = {
    ["true"] = "literal",
    ["false"] = "literal",

    ["nan"]  = "number",
    ["inf"]  = "number"
  },
}
