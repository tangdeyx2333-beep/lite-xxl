-- mod-version:4

local syntax = require "core.syntax"

syntax.add {
  name = "INI",
  files = { "%.ini$", "%.inf$", "%.cfg$", PATHSEP .. "%.editorconfig$", "%.theme$", "%.dockitem$", "%.desktop$" },
  comment = ";",
  patterns = {
    -- 解析阶段：INI 兼容 `;` 和 `#` 两种注释，先处理注释避免后续键值规则误消费。
    { pattern = ";.*", type = "comment" },
    { pattern = "#.*", type = "comment" },
    -- 结构阶段：方括号段落是 INI 的分组边界，优先按关键结构突出显示。
    { pattern = { "%[", "%]" }, type = "keyword" },

    -- 值阶段：先处理引号字符串，保证包含等号或空格的值不会被拆成多个语法片段。
    { pattern = { '"""', '"""', '\\' }, type = "string" },
    { pattern = { '"', '"', '\\' }, type = "string" },
    { pattern = { "'''", "'''" }, type = "string" },
    { pattern = { "'", "'" }, type = "string" },
    -- 键阶段：等号前的字段是配置项名称，作为主要阅读入口用 function 类型显示。
    { pattern = "[A-Za-z0-9_%.%-]+%s*%f[=]", type = "function" },
    -- 值阶段：数字在普通符号前识别，避免版本号、端口号等配置值被当成普通文本。
    { pattern = "[%-+]?[0-9_]+%.[0-9_]+", type = "number" },
    { pattern = "[%-+]?[0-9_]+", type = "number" },
    -- 收尾阶段：剩余小写词作为普通符号，保留布尔值交给 symbols 做更精确分类。
    { pattern = "[a-z]+", type = "symbol" },
  },
  symbols = {
    ["true"] = "literal",
    ["false"] = "literal",
  },
}
