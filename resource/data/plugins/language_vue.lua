-- mod-version:4

local syntax = require "core.syntax"

local function clone(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do
    if type(v) == "table" then
      out[k] = clone(v)
    else
      out[k] = v
    end
  end
  return out
end

local function build_template_syntax()
  -- 准备阶段：先复用 HTML 语法，再叠加 Vue 模板特有的插值规则。
  local template = clone(syntax.get("file.html"))

  -- 使用阶段：`{{ ... }}` 里的表达式按 JS 处理，模板层只负责分出边界。
  table.insert(template.patterns, 1, {
    pattern = { "{{", "}}" },
    syntax = ".js",
    type = "keyword2",
  })

  -- 使用阶段：Vue 指令和绑定属性单独提亮，避免它们在模板里只剩普通属性名。
  table.insert(template.patterns, 1, {
    pattern = "[:@#]?v[%w_:-]+",
    type = "keyword"
  })

  return template
end

local function block(start_pattern, end_pattern, block_syntax)
  return {
    pattern = { start_pattern, end_pattern },
    syntax = block_syntax,
    type = "function"
  }
end

local template_syntax = build_template_syntax()

syntax.add {
  name = "Vue",
  files = { "%.vue$" },
  block_comment = { "<!--", "-->" },
  patterns = {
    -- 解析阶段：先吃掉注释，避免单文件组件的结构标签被注释内容干扰。
    { pattern = { "<!%-%-", "%-%->" }, type = "comment" },

    -- 结构阶段：template 是模板语法入口，内部继续沿用 HTML + Vue 插值。
    block("<%s*[tT][eE][mM][pP][lL][aA][tT][eE]%f[%s>].->", "<%s*/%s*[tT][eE][mM][pP][lL][aA][tT][eE]%s*>", template_syntax),

    -- 结构阶段：script 按 lang 分流到现有 JS/TS/TSX 语法。
    block("<%s*[sS][cC][rR][iI][pP][tT]%f[%s>].-[lL][aA][nN][gG]%s*=%s*['\"][tT][sS][xX]?['\"][^>]*>", "<%s*/%s*[sS][cC][rR][iI][pP][tT]%s*>", ".tsx"),
    block("<%s*[sS][cC][rR][iI][pP][tT]%f[%s>].-[lL][aA][nN][gG]%s*=%s*['\"][tT][sS]['\"][^>]*>", "<%s*/%s*[sS][cC][rR][iI][pP][tT]%s*>", ".ts"),
    block("<%s*[sS][cC][rR][iI][pP][tT]%f[%s>].-[lL][aA][nN][gG]%s*=%s*['\"][jJ][sS][xX]?['\"][^>]*>", "<%s*/%s*[sS][cC][rR][iI][pP][tT]%s*>", ".js"),
    block("<%s*[sS][cC][rR][iI][pP][tT]%f[%s>].->", "<%s*/%s*[sS][cC][rR][iI][pP][tT]%s*>", ".js"),

    -- 结构阶段：style 按 lang 分流到现有 CSS/Sass 语法，less 暂时降级到 CSS 处理。
    block("<%s*[sS][tT][yY][lL][eE]%f[%s>].-[lL][aA][nN][gG]%s*=%s*['\"][sS][cC][sS][sS]['\"][^>]*>", "<%s*/%s*[sS][tT][yY][lL][eE]%s*>", ".scss"),
    block("<%s*[sS][tT][yY][lL][eE]%f[%s>].-[lL][aA][nN][gG]%s*=%s*['\"][sS][aA][sS][sS]['\"][^>]*>", "<%s*/%s*[sS][tT][yY][lL][eE]%s*>", ".sass"),
    block("<%s*[sS][tT][yY][lL][eE]%f[%s>].-[lL][aA][nN][gG]%s*=%s*['\"][lL][eE][sS][sS]['\"][^>]*>", "<%s*/%s*[sS][tT][yY][lL][eE]%s*>", ".css"),
    block("<%s*[sS][tT][yY][lL][eE]%f[%s>].-[lL][aA][nN][gG]%s*=%s*['\"][cC][sS][sS]['\"][^>]*>", "<%s*/%s*[sS][tT][yY][lL][eE]%s*>", ".css"),
    block("<%s*[sS][tT][yY][lL][eE]%f[%s>].->", "<%s*/%s*[sS][tT][yY][lL][eE]%s*>", ".css"),

    -- 收尾阶段：其余部分按 HTML 语法阅读，这样根标签和普通属性仍然保留基础高亮。
    { pattern = { '%f[^>][^<]', '%f[<]' }, type = "normal"   },
    { pattern = { '"', '"', '\\' },        type = "string"   },
    { pattern = { "'", "'", '\\' },        type = "string"   },
    { pattern = "0x[%da-fA-F]+",           type = "number"   },
    { pattern = "-?%d+[%d%.]*f?",          type = "number"   },
    { pattern = "-?%.?%d+f?",              type = "number"   },
    { pattern = "%f[^<]![%a_][%w_]*",      type = "keyword2" },
    { pattern = "%f[^<][%a_][%w_]*",       type = "function" },
    { pattern = "%f[^<]/[%a_][%w_]*",      type = "function" },
    { pattern = "[%a_][%w_]*",             type = "keyword"  },
    { pattern = "[/<>=]",                  type = "operator" },
  },
  symbols = {},
}
