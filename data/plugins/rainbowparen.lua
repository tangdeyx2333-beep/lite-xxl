-- mod-version:4
local core = require "core"
local style = require "core.style"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local tokenizer = require "core.tokenizer"
local Highlighter = require "core.doc.highlighter"

-- 准备阶段：先合并彩虹括号配置和默认颜色，后续 tokenizer 只消费这些状态。
config.plugins.rainbowparen = common.merge({
  enabled = true,
  parens = 5
}, config.plugins.rainbowparen)

style.syntax.paren_unbalanced = style.syntax.paren_unbalanced or { common.color "#DC0408" }
style.syntax.paren1 = style.syntax.paren1 or { common.color "#FC6F71" }
style.syntax.paren2 = style.syntax.paren2 or { common.color "#fcb053" }
style.syntax.paren3 = style.syntax.paren3 or { common.color "#fcd476" }
style.syntax.paren4 = style.syntax.paren4 or { common.color "#52dab2" }
style.syntax.paren5 = style.syntax.paren5 or { common.color "#5a98cf" }

local tokenize = tokenizer.tokenize
local extract_subsyntaxes = tokenizer.extract_subsyntaxes
local closers = {
  ["("] = ")",
  ["["] = "]",
  ["{"] = "}"
}

local function parenstyle(parenstack)
  return "paren" .. ((#parenstack % config.plugins.rainbowparen.parens) + 1)
end

function tokenizer.extract_subsyntaxes(base_syntax, state)
  -- 使用阶段：彩虹括号开启时，真实子语法状态放在 istate 里，避免括号栈污染原 tokenizer。
  if not config.plugins.rainbowparen.enabled then
    return extract_subsyntaxes(base_syntax, state)
  end
  state = state or {}
  return extract_subsyntaxes(base_syntax, state.istate)
end

function tokenizer.tokenize(syntax, text, state, resume)
  -- 处理阶段：先调用原 tokenizer，再只拆 normal/symbol 里的括号，避免字符串和注释里的括号被染色。
  if not config.plugins.rainbowparen.enabled then
    return tokenize(syntax, text, state, resume)
  end
  state = state or {}
  local res, istate, next_resume = tokenize(syntax, text, state.istate, resume)
  local parenstack = state.parenstack or ""
  local newres = {}

  for _, token_type, token_text in tokenizer.each_token(res) do
    if token_type == "normal" or token_type == "symbol" then
      for text_before, paren, text_after in token_text:gmatch("([^%(%[{}%]%)]*)([%(%[{}%]%)]?)([^%(%[{}%]%)]*)") do
        if #text_before > 0 then
          table.insert(newres, token_type)
          table.insert(newres, text_before)
        end
        if #paren > 0 then
          if paren == parenstack:sub(-1) then
            parenstack = parenstack:sub(1, -2)
            table.insert(newres, parenstyle(parenstack))
          elseif closers[paren] then
            table.insert(newres, parenstyle(parenstack))
            parenstack = parenstack .. closers[paren]
          else
            table.insert(newres, "paren_unbalanced")
          end
          table.insert(newres, paren)
        end
        if #text_after > 0 then
          table.insert(newres, token_type)
          table.insert(newres, text_after)
        end
      end
    else
      table.insert(newres, token_type)
      table.insert(newres, token_text)
    end
  end
  return newres, { parenstack = parenstack, istate = istate }, next_resume
end

local function toggle_rainbowparen(enabled)
  -- 使用阶段：切换开关后重建所有文档高亮器，让已打开文件立即刷新括号颜色。
  config.plugins.rainbowparen.enabled = enabled
  for _, doc in ipairs(core.docs) do
    doc.highlighter = Highlighter(doc)
    doc:reset_syntax()
  end
end

-- 设置阶段：暴露设置项，用户可以通过设置界面关闭彩虹括号。
config.plugins.rainbowparen.config_spec = {
  name = "Rainbow Parentheses",
  {
    label = "Enable",
    description = "Activates rainbow parenthesis coloring by default.",
    path = "enabled",
    type = "toggle",
    default = true,
    on_apply = function(enabled)
      toggle_rainbowparen(enabled)
    end
  }
}

command.add(nil, {
  ["rainbow-parentheses:toggle"] = function()
    toggle_rainbowparen(not config.plugins.rainbowparen.enabled)
  end
})
