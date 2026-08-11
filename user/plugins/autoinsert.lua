-- mod-version:4

-- ============================================================================
-- autoinsert：成对符号自动补全插件
-- 文件位置：user/plugins/autoinsert.lua（用户级插件，加载优先级高于 data/plugins 同名插件）
-- 功能范围（经用户确认）：
--   1. 文档识别出编程语言语法（如 Java、Python）后，输入 ( [ { " ' ` 自动补出对应右符号，
--      并把光标移回两个符号中间；纯文本（Plain Text）不启用
--   2. 输入右符号且光标后已是同一右符号时，不重复插入，光标直接右移跳过
--   3. 选中文本时输入左符号，用一对符号把选区包起来
--   4. 光标位于成对符号中间时按退格，成对删除左右符号
-- 与现有链路的关系：
--   本插件挂载在 DocView:on_text_input 文本输入入口（data/core/docview.lua）上，
--   在原输入逻辑之前先做补全判断，最终仍调用原始入口完成真正的文本写入，不改变
--   Doc / LargeFileDoc 的既有编辑链路；大文件（WLPT）材质化前不启用，材质化完成后
--   文档已转成普通 Doc，补全自然生效。
-- ============================================================================

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local DocView = require "core.docview"

-- 成对符号映射表：左符号 -> 右符号
-- 括号与引号都纳入（用户要求引号也自动补全）
-- common.merge 的作用：若用户已自定义过 config.plugins.autoinsert，则以用户配置为准
config.plugins.autoinsert = common.merge({ map = {
  ["["] = "]",
  ["{"] = "}",
  ["("] = ")",
  ['"'] = '"',
  ["'"] = "'",
  ["`"] = "`",
} }, config.plugins.autoinsert)


-- 判断给定字符是否为某个左符号对应的右符号
-- 用途：输入右符号时，若光标后已是同一右符号则跳过插入，避免出现重复右符号
local function is_closer(chr)
  for _, v in pairs(config.plugins.autoinsert.map) do
    if v == chr then
      return true
    end
  end
  return false
end


-- 统计一行文本中某个字符出现的次数
-- 用途：引号补全的奇偶判断。一行内引号数为奇数时说明用户正在书写普通文本内容
-- （例如 isn't），此时只正常输入、不自动补右引号
local function count_char(text, chr)
  local count = 0
  for _ in text:gmatch(chr) do
    count = count + 1
  end
  return count
end


-- 判断当前文档是否启用成对符号自动补全
-- 规则（逐条说明为什么）：
--   1. is_large_file 为 true 表示仍处在大文件（WLPT）预览态：此时编辑会先弹确认框，
--      行内容是分块占位数据，直接做补全判断会读到错误内容，因此先跳过；
--      用户确认编辑后文档会整体转成普通 Doc，补全随后自然生效
--   2. binary_mode 为 true 表示二进制十六进制只读视图，不允许编辑
--   3. loading / loading_error 期间行内容不完整，做补全判断没有意义且可能误判
--   4. 没有语法或语法是 Plain Text 时不启用（用户要求只对编程语言语法生效）
local function should_autopair(doc)
  if doc.is_large_file then
    return false
  end
  if doc.binary_mode then
    return false
  end
  if doc.loading or doc.loading_error then
    return false
  end
  local syn = doc.syntax
  if not syn or syn.name == "Plain Text" then
    return false
  end
  return true
end


-- 保存原始文本输入入口，补全逻辑处理完毕后仍需调用它完成真正的文本写入，
-- 以保证本插件不破坏 Doc.text_input 原有的编辑、撤销等行为
local on_text_input = DocView.on_text_input

-- 挂载点：DocView:on_text_input 是 Lite XL 接收键盘文本输入的入口（data/core/docview.lua），
-- 在这里先做补全判断与补全写入；不满足补全条件时原样走原始入口
function DocView:on_text_input(text)
  -- 多光标（selections 为扁平的“每光标 4 个数”，超过 4 即多于 1 个光标）时不补全，
  -- 避免多光标编辑场景下插入位置错乱
  if #self.doc.selections > 4 then
    return on_text_input(self, text)
  end
  -- CommandView 同样继承自 DocView，但命令栏输入不应触发补全，
  -- 因此严格匹配 DocView 本身（getmetatable 为子类时返回 false）
  if getmetatable(self) ~= DocView then
    return on_text_input(self, text)
  end
  -- 大文件/二进制/加载中/纯文本文档不启用补全，原样走原始输入链路
  if not should_autopair(self.doc) then
    return on_text_input(self, text)
  end

  -- 准备数据：根据本次输入文本 text 查映射表，得到对应右符号（普通字符查不到则为 nil）
  local mapping = config.plugins.autoinsert.map[text]

  -- 场景一：存在选区且输入的是左符号 -> 用一对符号包裹选区
  -- 准备数据：取选区两端位置与是否交换标记
  if mapping and self.doc:has_selection() then
    local l1, c1, l2, c2, swap = self.doc:get_selection(true)
    -- 使用数据：先在后端插入右符号、再在前端插入左符号，最后重设选区把内容包住
    self.doc:insert(l2, c2, mapping)
    self.doc:insert(l1, c1, text)
    self.doc:set_selection(l1, c1, l2, c2 + 2, swap)
    return
  end

  -- 准备数据：取光标处的字符，用于后续判断“光标后是否已是同款右符号”“光标前是否空白”
  local chr = self.doc:get_char(self.doc:get_selection())

  -- 场景二：输入的是右符号，且光标后已经是同一右符号 -> 不重复插入，光标右移一位跳过
  -- 例如光标位于 {} 中间时输入 }，直接跳到 } 之后，避免出现 }}}
  if text == chr and is_closer(chr) then
    self.doc:move_to(1)
    return
  end

  -- 场景三：引号类符号的奇偶判断
  -- 引号在映射表中映射到自身（text == mapping），此时若当前行该符号数量为奇数，
  -- 说明正在输入的是行内第 2/4/... 个引号（闭合已有引号或书写普通文本），只正常输入
  if text == mapping and count_char(self.doc.lines[self.doc:get_selection()], text) % 2 == 1 then
    return on_text_input(self, text)
  end

  -- 场景四：常规自动补全
  -- 满足条件（光标后是空白，或光标后是右符号且本次输入不是双引号）时：
  -- 先写入左符号，再写入右符号，最后把光标移回两个符号中间
  if mapping and (chr:find("%s") or is_closer(chr) and chr ~= '"') then
    on_text_input(self, text)
    on_text_input(self, mapping)
    self.doc:move_to(-1)
    return
  end

  -- 其余情况（例如在单词中间输入括号）：不做补全，原样输入
  on_text_input(self, text)
end


-- ---------------------------------------------------------------------------
-- 退格成对删除
-- 使用严格谓词限定：仅当当前活动视图就是 DocView（排除 CommandView）、文档满足启用
-- 条件、且没有选区时才执行成对删除；其余场景下命令不可用，按键会自动回退到原有绑定
-- ---------------------------------------------------------------------------
local function docview_predicate()
  local view = core.active_view
  if not (view and view:is(DocView)) then
    return false
  end
  if not should_autopair(view.doc) then
    return false
  end
  return #view.doc.selections <= 4 and not view.doc:has_selection(), view
end

command.add(docview_predicate, {
  -- 成对删除：光标位于成对符号之间（如 {} 中间）时，先删掉光标处的右符号，
  -- 再调用 doc:backspace 删掉左符号，实现一次退格删除一对
  -- 不在成对符号中间时，行为与普通退格完全一致
  ["autoinsert:backspace"] = function(view)
    local doc = view.doc
    local l, c = doc:get_selection()
    if c > 1 then
      -- 准备数据：取光标处字符与光标前一个字符，判断是否构成成对符号
      local chr = doc:get_char(l, c)
      local mapped = config.plugins.autoinsert.map[doc:get_char(l, c - 1)]
      -- 使用数据：光标前是左符号且光标处是对应右符号时，先删掉右符号
      if mapped and mapped == chr then
        doc:delete_to(1)
      end
    end
    -- 再走原始删除命令删掉左符号（或普通字符）
    command.perform "doc:backspace"
  end,

  -- ctrl+backspace：从光标位置开始，把前方连续的成对符号逐个成对删除
  ["autoinsert:delete-to-previous-word-start"] = function(view)
    local doc = view.doc
    -- 准备数据：计算光标前一个词起始位置，作为成对删除的终点
    local le, ce = translate.previous_word_start(doc, doc:get_selection())
    -- 使用数据：循环执行成对删除，直到光标到达终点位置
    while true do
      local l, c = doc:get_selection()
      if l == le and c == ce then
        break
      end
      command.perform "autoinsert:backspace"
    end
  end,
})

-- 绑定退格键：keymap.add 默认把新命令追加到原绑定之前（优先级更高）；
-- 若 autoinsert 命令不可用（命令栏、纯文本等场景），按键会自动回退到原有删除行为
keymap.add {
  ["backspace"]            = "autoinsert:backspace",
  ["ctrl+backspace"]       = "autoinsert:delete-to-previous-word-start",
  ["ctrl+shift+backspace"] = "autoinsert:delete-to-previous-word-start",
}
