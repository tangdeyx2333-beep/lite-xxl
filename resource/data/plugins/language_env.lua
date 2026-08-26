-- mod-version:4

local syntax = require "core.syntax"

local key_pattern = '[a-zA-Z_]+[a-zA-Z0-9_]*'
local unicode_sequence = "'?\\u%x%x%x%x'?"
local escaped_literals = "\\[nrtfb\\\"']"
local null_pattern = '%s*[Nn][Uu][Ll][Ll]%s*'
local true_pattern = '%s*[Tt][Rr][Uu][Ee]%s*'
local false_pattern = '%s*[Ff][Aa][Ll][Ss][Ee]%s*'

local synt_key = {
  symbols = {},
  patterns = {
    -- 使用阶段：变量插值里的内容只需要识别环境变量名，不进入完整 env 行解析。
    { type = "keyword2", pattern = key_pattern },
  },
}

local synt_dqs = {
  symbols = {},
  patterns = {
    -- 使用阶段：双引号字符串内部继续识别 `${VAR}`，保持 env 插值关系可读。
    { pattern = { "%${", "}" },     type = "keyword", syntax = synt_key },
    -- 使用阶段：字符串内部的数字、转义字符和普通字符分层处理，避免转义序列被当成普通文本。
    { pattern = "0[bB][%d]+",       type = "number"   },
    { pattern = "0[xX][%da-fA-F]+", type = "number"   },
    { pattern = "[-+]?%.?%d+",      type = "number"   },
    { pattern = escaped_literals,   type = "literal"  },
    { pattern = unicode_sequence,   type = "literal"  },
    { pattern = '[%w%p%s]',         type = "string"   },
  },
}

syntax.add {
  name = "language_env",
  files = { "%.env$" },
  comment = "#",
  symbols = {},
  patterns = {
    -- 解析阶段：注释先消费，避免注释里的等号和变量插值影响后续键值识别。
    { pattern = "#.*$",           type = "comment"  },
    -- 解析阶段：`export` 是 shell/env 交界处的声明前缀，单独显示便于阅读启动配置。
    { pattern = "export",         type = "function" },
    -- 值阶段：空值和布尔值支持大小写混写，放在普通字符串前提高识别精度。
    { pattern = null_pattern,     type = "literal"  },
    { pattern = true_pattern,     type = "literal"  },
    { pattern = false_pattern,    type = "literal"  },
    { pattern = escaped_literals, type = "literal"  },
    { pattern = unicode_sequence, type = "literal"  },
    -- 值阶段：变量插值交给子语法处理，当前阶段只标记插值边界。
    { pattern = { "%${", "}" },     type = "keyword", syntax = synt_key },
    -- 值阶段：数字按二进制、十六进制、普通数字依次识别，避免前缀格式被截断。
    { pattern = "0[bB][%d]+",       type = "number" },
    { pattern = "0[xX][%da-fA-F]+", type = "number" },
    { pattern = "[-+]?%.?%d+",      type = "number" },
    -- 准备阶段：被引号包住的键名容易和字符串冲突，这里先按普通文本兜底，避免误高亮。
    { pattern = '[\'"].*[\'"]%s*=.*',     type = "normal" },
    -- 键阶段：等号前的字段是环境变量名，等号本身作为操作符显示。
    { pattern = key_pattern..'%s*()=%s*', type = { "keyword2", "operator" }},
    -- 值阶段：双引号字符串启用插值子语法，其他引号字符串按整体值处理。
    { pattern = {'"', '"', '\\'},     type = "string",  syntax = synt_dqs},
    { pattern = {"'", "'", '\\'},     type = "string"   },
    { pattern = {'"""', '"""', '\\'}, type = "string"   },
    { pattern = {"'''", "'''", '\\'}, type = "string"   },
  },
}
