# 编辑器命令清单

## 说明

- 这份清单按当前项目源码里的命令注册链路整理，来源主要是 [data/core/commands](/F:/.a.github/final/data/core/commands) 和 [data/plugins](/F:/.a.github/final/data/plugins)。
- 作用说明是按命令实现归纳出来的中文说明，不是界面里的原始英文文案。
- 当前统计到 **256 个命令**，其中一部分是源码里显式注册，另一部分是循环批量生成。
- 你截图里的 `Doc: Indent`、`Doc: Delete`、`Root: Grow` 这种显示名，实际命令名分别对应 `doc:indent`、`doc:delete`、`root:grow`。

## `command:*` 命令面板输入框命令

- `command:submit`：提交当前命令面板输入内容。
- `command:select-previous`：在命令面板候选列表里上移一项。
- `command:select-next`：在命令面板候选列表里下移一项。
- `command:complete`：用当前候选项补全输入内容。
- `command:escape`：退出或取消当前命令面板。

## `core:*` 编辑器级命令

- `core:quit`：正常退出编辑器。
- `core:restart`：重启编辑器进程。
- `core:force-quit`：强制退出编辑器。
- `core:toggle-clean-exit`：切换是否按“干净退出”模式离开编辑器。
- `core:toggle-fullscreen`：切换全屏显示。
- `core:reload-module`：重新加载已加载的 Lua 模块。
- `core:change-theme`：切换当前主题。
- `core:find-command`：打开命令面板并搜索可执行命令。
- `core:new-doc`：新建空白文档。
- `core:new-named-doc`：按输入文件名新建文档。
- `core:open-file`：打开文件，具体入口由当前平台实现决定。
- `core:open-file-picker`：通过系统文件选择器打开文件。
- `core:open-file-commandview`：通过命令输入框路径方式打开文件。
- `core:open-log`：打开日志视图。
- `core:open-user-module`：打开用户目录模块文件。
- `core:open-project-module`：打开项目目录模块文件。
- `core:change-project-folder`：切换当前项目目录。
- `core:change-project-folder-picker`：通过目录选择器切换项目目录。
- `core:change-project-folder-commandview`：通过命令输入框路径方式切换项目目录。
- `core:open-project-folder`：在新窗口打开另一个项目目录。
- `core:open-project-folder-picker`：通过目录选择器打开项目目录。
- `core:open-project-folder-commandview`：通过命令输入框路径方式打开项目目录。
- `core:add-directory`：把目录追加到当前项目工作区。
- `core:add-directory-picker`：通过目录选择器把目录追加到当前项目工作区。
- `core:add-directory-commandview`：通过命令输入框路径方式把目录追加到当前项目工作区。
- `core:remove-directory`：从当前项目工作区移除目录。
- `core:find-file`：在项目文件列表里做模糊查找并打开文件。

## `dialog:*` 对话框命令

- `dialog:previous-entry`：切换到上一个对话框选项。
- `dialog:next-entry`：切换到下一个对话框选项。
- `dialog:select-yes`：在确认对话框里选择“是”。
- `dialog:select-no`：在确认对话框里选择“否”。
- `dialog:select`：确认当前对话框选项。

## `doc:*` 文档基础编辑命令

- `doc:select-none`：取消选区，只保留光标。
- `doc:cut`：剪切选中内容；无选区时按整行处理。
- `doc:copy`：复制选中内容；无选区时按整行处理。
- `doc:undo`：撤销上一步修改。
- `doc:redo`：重做被撤销的修改。
- `doc:paste`：粘贴剪贴板内容。
- `doc:paste-primary-selection`：粘贴主选区内容。
- `doc:newline`：在当前位置插入新行并继承缩进。
- `doc:newline-below`：在当前行下方插入新行。
- `doc:newline-above`：在当前行上方插入新行。
- `doc:delete`：向后删除字符或删除当前选区。
- `doc:backspace`：向前删除字符，必要时按缩进宽度回删。
- `doc:select-all`：全选当前文档。
- `doc:select-lines`：按整行扩展当前选区。
- `doc:select-word`：按单词扩展当前选区。
- `doc:join-lines`：把多行合并成一行，并按规则补空格。
- `doc:indent`：给当前行或选区整体增加缩进。
- `doc:unindent`：给当前行或选区整体减少缩进。
- `doc:duplicate-lines`：复制当前行或选中的多行。
- `doc:delete-lines`：删除当前行或选中的多行。
- `doc:move-lines-up`：把当前行或选中的多行上移。
- `doc:move-lines-down`：把当前行或选中的多行下移。
- `doc:toggle-block-comments`：切换块注释状态。
- `doc:toggle-line-comments`：切换行注释状态。
- `doc:upper-case`：把选中内容转成大写。
- `doc:lower-case`：把选中内容转成小写。
- `doc:go-to-line`：跳转到指定行号。
- `doc:toggle-line-ending`：切换换行格式，通常是在 `LF` 和 `CRLF` 之间切换。
- `doc:toggle-overwrite`：切换插入模式和覆盖模式。
- `doc:save-as`：另存为新文件。
- `doc:save`：保存当前文档。
- `doc:reload`：从磁盘重新加载当前文档。
- `doc:select-to-cursor`：从已有锚点扩展选区到鼠标位置。
- `doc:create-cursor-previous-line`：在上一行创建额外光标。
- `doc:create-cursor-next-line`：在下一行创建额外光标。
- `doc:set-cursor`：把光标设置到鼠标点击位置。
- `doc:set-cursor-word`：把点击位置扩展成按单词选择。
- `doc:set-cursor-line`：把点击位置扩展成按整行选择。
- `doc:split-cursor`：在点击位置增加或移除一个多光标。

## `doc:*` 文档移动命令

- `doc:move-to-previous-char`：把光标移动到前一个字符。
- `doc:move-to-next-char`：把光标移动到后一个字符。
- `doc:move-to-previous-word-start`：把光标移动到前一个单词开头。
- `doc:move-to-next-word-end`：把光标移动到后一个单词结尾。
- `doc:move-to-previous-block-start`：把光标移动到前一个代码块或段落起点。
- `doc:move-to-next-block-end`：把光标移动到后一个代码块或段落终点。
- `doc:move-to-start-of-doc`：把光标移动到文档开头。
- `doc:move-to-end-of-doc`：把光标移动到文档结尾。
- `doc:move-to-start-of-line`：把光标移动到当前行开头。
- `doc:move-to-end-of-line`：把光标移动到当前行结尾。
- `doc:move-to-start-of-word`：把光标移动到当前单词开头。
- `doc:move-to-start-of-indentation`：把光标移动到当前行缩进结束处。
- `doc:move-to-end-of-word`：把光标移动到当前单词结尾。
- `doc:move-to-previous-line`：把光标移动到上一行对应列位置。
- `doc:move-to-next-line`：把光标移动到下一行对应列位置。
- `doc:move-to-previous-page`：把光标按页向上移动。
- `doc:move-to-next-page`：把光标按页向下移动。

## `doc:*` 文档选择命令

- `doc:select-to-previous-char`：把选区向前扩展一个字符。
- `doc:select-to-next-char`：把选区向后扩展一个字符。
- `doc:select-to-previous-word-start`：把选区扩展到前一个单词开头。
- `doc:select-to-next-word-end`：把选区扩展到后一个单词结尾。
- `doc:select-to-previous-block-start`：把选区扩展到前一个代码块或段落起点。
- `doc:select-to-next-block-end`：把选区扩展到后一个代码块或段落终点。
- `doc:select-to-start-of-doc`：把选区扩展到文档开头。
- `doc:select-to-end-of-doc`：把选区扩展到文档结尾。
- `doc:select-to-start-of-line`：把选区扩展到当前行开头。
- `doc:select-to-end-of-line`：把选区扩展到当前行结尾。
- `doc:select-to-start-of-word`：把选区扩展到当前单词开头。
- `doc:select-to-start-of-indentation`：把选区扩展到当前行缩进结束处。
- `doc:select-to-end-of-word`：把选区扩展到当前单词结尾。
- `doc:select-to-previous-line`：把选区向上一行扩展。
- `doc:select-to-next-line`：把选区向下一行扩展。
- `doc:select-to-previous-page`：把选区按页向上扩展。
- `doc:select-to-next-page`：把选区按页向下扩展。

## `doc:*` 文档删除命令

- `doc:delete-to-previous-char`：向前删除一个字符。
- `doc:delete-to-next-char`：向后删除一个字符。
- `doc:delete-to-previous-word-start`：向前删除到前一个单词开头。
- `doc:delete-to-next-word-end`：向后删除到后一个单词结尾。
- `doc:delete-to-previous-block-start`：向前删除到前一个代码块或段落起点。
- `doc:delete-to-next-block-end`：向后删除到后一个代码块或段落终点。
- `doc:delete-to-start-of-doc`：向前删除到文档开头。
- `doc:delete-to-end-of-doc`：向后删除到文档结尾。
- `doc:delete-to-start-of-line`：向前删除到当前行开头。
- `doc:delete-to-end-of-line`：向后删除到当前行结尾。
- `doc:delete-to-start-of-word`：向前删除到当前单词开头。
- `doc:delete-to-start-of-indentation`：向前删除到当前行缩进结束处。
- `doc:delete-to-end-of-word`：向后删除到当前单词结尾。
- `doc:delete-to-previous-line`：向上按行删除到对应位置。
- `doc:delete-to-next-line`：向下按行删除到对应位置。
- `doc:delete-to-previous-page`：向上按页删除。
- `doc:delete-to-next-page`：向下按页删除。

## `file:*` 文件命令

- `file:rename`：重命名当前文件，并在需要时保存为新名字。
- `file:delete`：删除当前文件，并关闭相关视图。

## `files:*` 文件系统命令

- `files:create-directory`：创建目录。

## `find-replace:*` 查找替换命令

- `find-replace:select-next`：把当前选区切换到下一个相同文本。
- `find-replace:select-previous`：把当前选区切换到上一个相同文本。
- `find-replace:select-add-next`：把下一个相同文本加入多选区。
- `find-replace:select-add-all`：把所有相同文本一次性加入多选区。
- `find-replace:find`：打开查找栏并执行查找。
- `find-replace:replace`：在当前文档中查找并替换。
- `find-replace:replace-in-selection`：只在当前选区范围内查找并替换。
- `find-replace:replace-symbol`：按“符号”范围做查找替换。
- `find-replace:repeat-find`：继续执行上一次向下查找。
- `find-replace:previous-find`：继续执行上一次向上查找。
- `find-replace:large-file-prev-chunk`：大文件模式下切到上一个搜索分块继续查找。
- `find-replace:large-file-next-chunk`：大文件模式下切到下一个搜索分块继续查找。
- `find-replace:commandview-next-find`：当查找栏处于激活状态时，直接在查找栏里执行“下一个”。
- `find-replace:commandview-previous-find`：当查找栏处于激活状态时，直接在查找栏里执行“上一个”。
- `find-replace:commandview-prev-chunk`：当查找栏处于激活状态时，切到上一个大文件搜索分块。
- `find-replace:commandview-next-chunk`：当查找栏处于激活状态时，切到下一个大文件搜索分块。
- `find-replace:toggle-sensitivity`：切换大小写敏感查找。
- `find-replace:toggle-regex`：切换正则查找模式。

## `log:*` 日志命令

- `log:open-as-doc`：把日志内容作为文档打开。
- `log:copy-to-clipboard`：把日志内容复制到剪贴板。

## `root:*` 视图布局与标签页命令

- `root:close`：关闭当前视图。
- `root:close-or-quit`：有可关视图时关闭视图，否则退出编辑器。
- `root:close-all`：关闭所有文档视图。
- `root:close-all-others`：关闭除当前文档外的其他文档视图。
- `root:move-tab-left`：把当前标签页向左移动。
- `root:move-tab-right`：把当前标签页向右移动。
- `root:shrink`：缩小当前分栏区域占比。
- `root:grow`：放大当前分栏区域占比。
- `root:scroll`：对当前可滚动视图做纵向滚动。
- `root:horizontal-scroll`：对当前可滚动视图做横向滚动。
- `root:switch-to-previous-tab`：切换到上一个标签页。
- `root:switch-to-next-tab`：切换到下一个标签页。
- `root:scroll-tabs-backward`：把标签栏向后滚动。
- `root:scroll-tabs-forward`：把标签栏向前滚动。
- `root:switch-to-hovered-previous-tab`：在鼠标悬停的标签栏区域切到上一个标签。
- `root:switch-to-hovered-next-tab`：在鼠标悬停的标签栏区域切到下一个标签。
- `root:scroll-hovered-tabs-backward`：滚动鼠标悬停位置对应的标签栏，方向向后。
- `root:scroll-hovered-tabs-forward`：滚动鼠标悬停位置对应的标签栏，方向向前。
- `root:switch-to-tab-1`：切换到当前标签组的第 1 个标签页。
- `root:switch-to-tab-2`：切换到当前标签组的第 2 个标签页。
- `root:switch-to-tab-3`：切换到当前标签组的第 3 个标签页。
- `root:switch-to-tab-4`：切换到当前标签组的第 4 个标签页。
- `root:switch-to-tab-5`：切换到当前标签组的第 5 个标签页。
- `root:switch-to-tab-6`：切换到当前标签组的第 6 个标签页。
- `root:switch-to-tab-7`：切换到当前标签组的第 7 个标签页。
- `root:switch-to-tab-8`：切换到当前标签组的第 8 个标签页。
- `root:switch-to-tab-9`：切换到当前标签组的第 9 个标签页。
- `root:split-left`：把当前视图向左拆分成新分栏。
- `root:split-right`：把当前视图向右拆分成新分栏。
- `root:split-up`：把当前视图向上拆分成新分栏。
- `root:split-down`：把当前视图向下拆分成新分栏。
- `root:switch-to-left`：把焦点切到左侧分栏。
- `root:switch-to-right`：把焦点切到右侧分栏。
- `root:switch-to-up`：把焦点切到上侧分栏。
- `root:switch-to-down`：把焦点切到下侧分栏。

## `status-bar:*` 状态栏命令

- `status-bar:toggle`：切换状态栏显示状态。
- `status-bar:show`：显示状态栏。
- `status-bar:hide`：隐藏状态栏。
- `status-bar:disable-messages`：关闭状态栏消息显示。
- `status-bar:enable-messages`：开启状态栏消息显示。
- `status-bar:hide-item`：隐藏指定状态栏条目。
- `status-bar:show-item`：显示指定状态栏条目。
- `status-bar:reset-items`：重置状态栏条目显示设置。

## `tabbar:*` 和 `emptyview:*` 命令

- `tabbar:new-doc`：在标签栏区域新建文档。
- `emptyview:new-doc`：在空视图区域新建文档。

## 插件命令

### `autocomplete:*` 自动补全

- `autocomplete:complete`：接受当前补全候选。
- `autocomplete:previous`：切到上一个补全候选。
- `autocomplete:next`：切到下一个补全候选。
- `autocomplete:cycle`：在补全候选之间循环切换。
- `autocomplete:cancel`：取消当前补全。

### `draw-whitespace:*` 空白字符显示

- `draw-whitespace:toggle`：切换是否显示空白字符。
- `draw-whitespace:disable`：关闭空白字符显示。
- `draw-whitespace:enable`：开启空白字符显示。

### `ghmarkdown:*` Markdown 预览

- `ghmarkdown:show-preview`：打开 GitHub 风格 Markdown 预览。

### `indent:*` 缩进检测与转换

- `indent:set-file-indent-type`：设置当前文件使用 Tab 还是空格缩进。
- `indent:set-file-indent-size`：设置当前文件的缩进宽度。
- `indent:switch-file-to-tabs-indentation`：把当前文件缩进转换为 Tab。
- `indent:switch-file-to-spaces-indentation`：把当前文件缩进转换为空格。

### `line-wrapping:*` 自动换行

- `line-wrapping:enable`：开启自动换行显示。
- `line-wrapping:disable`：关闭自动换行显示。
- `line-wrapping:toggle`：切换自动换行显示状态。

### `lineguide:*` 行参考线

- `lineguide:toggle`：切换列参考线显示。

### `macro:*` 宏录制

- `macro:toggle-record`：开始或停止录制宏。
- `macro:play`：回放最近一次录制的宏。

### `markdown:*` Markdown 渲染视图

- `markdown:toggle-render`：切换 Markdown 渲染模式。
- `markdown:preview-scroll-up`：向上滚动 Markdown 预览。
- `markdown:preview-scroll-down`：向下滚动 Markdown 预览。
- `markdown:preview-copy`：复制 Markdown 预览内容。
- `markdown:preview-select-all`：全选 Markdown 预览内容。

### `project-search:*` 项目搜索

- `project-search:find`：在项目里按普通文本搜索。
- `project-search:find-regex`：在项目里按正则表达式搜索。
- `project-search:fuzzy-find`：在项目里按模糊匹配搜索。
- `project-search:select-previous`：在搜索结果里选择上一项。
- `project-search:select-next`：在搜索结果里选择下一项。
- `project-search:open-selected`：打开当前选中的搜索结果。
- `project-search:refresh`：刷新项目搜索结果。
- `project-search:move-to-previous-page`：在搜索结果里向上翻页。
- `project-search:move-to-next-page`：在搜索结果里向下翻页。
- `project-search:move-to-start-of-doc`：跳到搜索结果开头。
- `project-search:move-to-end-of-doc`：跳到搜索结果结尾。

### `quote:*` 引号处理

- `quote:quote`：给选中内容加引号或做引号包装。

### `reflow:*` 文本重排

- `reflow:reflow`：按段落重新排版文本。

### `scale:*` 界面缩放

- `scale:decrease`：减小界面缩放比例。
- `scale:increase`：增大界面缩放比例。

### `tabularize:*` 表格对齐

- `tabularize:tabularize`：按分隔符对齐多列文本。

### `treeview:*` 目录树操作

- `treeview:search-in-directory`：在当前目录树节点下发起搜索。
- `treeview:delete`：删除目录树中当前选中的文件或目录。
- `treeview:rename`：重命名目录树中当前选中的文件或目录。
- `treeview:toggle`：展开或收起目录树面板。
- `treeview:toggle-focus`：在目录树和编辑区之间切换焦点。
- `treeview:toggle-hidden`：切换是否显示隐藏文件。
- `treeview:toggle-ignored`：切换是否显示被忽略文件。
- `treeview:next`：在目录树里选择下一项。
- `treeview:previous`：在目录树里选择上一项。
- `treeview:open`：打开当前目录树选中项。
- `treeview:deselect`：取消目录树当前选择。
- `treeview:select`：选中目录树当前项。
- `treeview:select-and-open`：选中并直接打开当前项。
- `treeview:collapse`：收起当前目录节点。
- `treeview:expand`：展开当前目录节点。
- `treeview:new-file`：在当前目录下新建文件。
- `treeview:new-folder`：在当前目录下新建文件夹。
- `treeview:open-in-system`：用系统文件管理器打开当前项。
- `treeview:remove-project-directory`：把当前目录从项目目录树中移除。

### `trim-whitespace:*` 清理空白

- `trim-whitespace:trim-trailing-whitespace`：删除行尾多余空白。
- `trim-whitespace:trim-empty-end-lines`：删除文件末尾多余空行。

## 备注

- 如果你下一步要的是“**命令名 + 默认快捷键**”版本，我可以继续基于 `keymap.add` / `keymap.add_direct` 再给你补一份单独的 Markdown。
- 如果你要的是“**只保留你当前最常用的命令**”版本，我也可以从这 256 个里再帮你筛一版常用清单。
