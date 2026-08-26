-- mod-version:4
local syntax = require "core.syntax"

local yaml_flow_value = {
  patterns = {
    -- 这一阶段处理行内集合里的注释，避免集合后半段内容继续被当成普通值高亮。
    { pattern = "#.*",                         type = "comment"  },
    -- 这一阶段处理行内集合里的字符串，保证带空格或特殊字符的值优先作为整体消费。
    { pattern = { '"', '"', '\\' },             type = "string"   },
    { pattern = { "'", "'", '\\' },             type = "string"   },
    -- 这一阶段处理行内集合里的键名，服务于 `{ key: value }` 这种 YAML 流式结构。
    { pattern = "[%a_][%w_%-%.]*%s*()%:",       type = { "keyword2", "operator" } },
    -- 这一阶段处理行内集合里的数字和字面量，和主 YAML 语法保持同一套值识别规则。
    { pattern = "[%+%-]?0x%x+",                 type = "number"   },
    { pattern = "[%+%-]?%d+[%d%.eE_]*",         type = "number"   },
    { pattern = "%f[%w]true%f[^%w]",            type = "literal"  },
    { pattern = "%f[%w]false%f[^%w]",           type = "literal"  },
    { pattern = "%f[%w]null%f[^%w]",            type = "literal"  },
    -- 这一阶段处理 YAML 流式结构符号，放在具体值之后作为结构兜底。
    { pattern = "[%[%]{}:,]",                   type = "operator" },
    { pattern = "[%a_][%w_%-%.]*",              type = "string"   },
  },
  symbols = {}
}

syntax.add {
  name = "YAML",
  files = { "%.yml$", "%.yaml$" },
  comment = "#",
  space_handling = false,
  patterns = {
    -- 准备阶段：先处理行首空白，避免后续锚点规则反复扫描缩进字符影响高亮性能。
    { pattern = "%s+",                          type = "normal"   },

    -- 结构阶段：优先识别文档边界和列表前缀，这些符号决定 YAML 当前行的结构角色。
    { pattern = "^%-%-%-%s*$",                  type = "operator" },
    { pattern = "^%.%.%.%s*$",                  type = "operator" },
    { pattern = "^%s*%-",                       type = "operator" },

    -- 键名阶段：识别普通键和列表项里的键，这是 YAML 最主要的配置阅读入口。
    { pattern = "^%s*[%a_][%w_%-%.]*%s*()%:",   type = { "keyword", "operator" } },
    { pattern = "^%s*%-%s*[%a_][%w_%-%.]*%s*()%:", type = { "keyword2", "operator" } },

    -- 复合值阶段：把行内数组和对象交给子语法处理，避免主语法把内部键值对拆散。
    { pattern = { "%[", "%]" },                 type = "operator", syntax = yaml_flow_value },
    { pattern = { "{", "}" },                   type = "operator", syntax = yaml_flow_value },

    -- 值阶段：先消费字符串，再消费数字和字面量，避免特殊字符误判成结构符号。
    { pattern = { '"', '"', '\\' },              type = "string"   },
    { pattern = { "'", "'", '\\' },              type = "string"   },
    { pattern = "[%+%-]?0x%x+",                  type = "number"   },
    { pattern = "[%+%-]?%d+[%d%.eE_]*",          type = "number"   },
    { pattern = "%f[%w]true%f[^%w]",             type = "literal"  },
    { pattern = "%f[%w]false%f[^%w]",            type = "literal"  },
    { pattern = "%f[%w]null%f[^%w]",             type = "literal"  },

    -- 引用阶段：识别锚点、别名、合并键和显式类型，帮助阅读复杂 YAML 配置的引用关系。
    { pattern = "%&[%w_%-]+",                    type = "keyword2" },
    { pattern = "%*[%w_%-]+",                    type = "keyword2" },
    { pattern = "<<",                            type = "keyword"  },
    { pattern = "!![%w_%-%.]+",                  type = "keyword"  },

    -- 收尾阶段：最后处理注释和剩余结构符号，避免它们抢先破坏前面的键值识别。
    { pattern = "#.*",                           type = "comment"  },
    { pattern = "[:|>!%%]",                      type = "operator" },
    { pattern = "[%a_][%w_%-%.]*",               type = "string"   },
  },
  symbols = {}
}
