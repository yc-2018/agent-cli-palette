# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Windows 侧边栏命令面板：把 AI 编程 CLI 的命令渲染成一列中文按钮，点击后把真实命令输入到用户绑定的那个终端窗口里。

整个项目只有两类文件：

- `AgentCliPalette.ps1` —— 唯一的代码文件（约 1380 行，WPF + user32 互操作）。
- `commands-*.json` —— 命令表，每个 CLI 一张。所有面向用户的文字都在这里。

没有构建系统、没有包管理、没有依赖。运行环境是 Windows 10/11 自带的 Windows PowerShell 5.1，`#Requires -Version 5.1`。WPF 需要单线程单元，所以启动必须带 `-STA`。

## 开发与验证命令

改完代码后唯一的验证手段是脚本内置的自检，先跑它：

```powershell
# 建完整个界面并跑内部检查，不显示主窗口
powershell -NoProfile -STA -File AgentCliPalette.ps1 -SelfTest

# 额外真开一个终端，把两种输入模式端到端跑通一次
powershell -NoProfile -STA -File AgentCliPalette.ps1 -SelfTest -Live

# 指定用哪张命令表启动
powershell -NoProfile -STA -File AgentCliPalette.ps1 -Config "commands-pi.json"

# 保留 powershell.exe 自己的控制台窗口（排错用）
powershell -NoProfile -STA -File AgentCliPalette.ps1 -KeepConsole
```

`-SelfTest`（`AgentCliPalette.ps1:1176` 起）会逐行报告：发现了哪些命令表、渲染出多少分组和按钮、切换命令表能否干净地来回、提示框的实测坐标是否避开按钮列表、贴到屏幕右边时是否会翻转、每个按键组合解析成什么虚拟键码、剪贴板读写是否匹配、搜索命中与空结果占位符是否正常。

`-Live` 会**真的抢走输入焦点**：它启动 `cmd.exe` 和一个新终端，用 SendInput 往里面敲命令、写标记文件再校验，最后输入 `exit` 收尾。跑的时候不要同时在键盘上做别的事。

没有单元测试框架，也没有 lint 配置。

## 架构

### 数据与代码分离是这个项目的核心设计

脚本不认识任何一条具体命令。它只做两件事：把条目的 `cmd` 文本输入到目标终端，或者把条目的 `keys` 解析成虚拟键码发出去。因此**支持一个新 CLI = 往脚本旁边丢一张 `commands-<名字>.json`，不改一行代码、不用重启**。

推论：新增或修改命令时，改 JSON，不要动 `.ps1`。只有输入机制、窗口管理、界面结构需要变时才改脚本。

### 一次点击的完整链路

`Invoke-PaletteItem`（`AgentCliPalette.ps1:662`）是整个程序的核心路径，顺序有讲究：

1. `Test-Target` 确认绑定的窗口还活着。
2. 如果走粘贴模式，**先**备份并写入剪贴板，**再**抢焦点 —— 这样 Ctrl+V 能紧跟着焦点切换发出去。
3. `Enable-TargetFocus` → `Nx::FocusWindow`。这一步失败就**直接放弃并报错**，绝不继续。因为 SendInput 发给的是当前持有键盘焦点的窗口，焦点没切过去的话命令会被敲进面板自己的搜索框。
4. 发送：`keys` 走 `SendCombo`（按下全部、再反序释放，构成真正的组合键），**发完立刻 `return`**（`:689`）；文本走 `SendText`（逐字符 Unicode 键事件）或剪贴板 Ctrl+V。
5. 粘贴模式结束后恢复用户原来的剪贴板内容 —— 只有文本路径会走到这里。
6. 勾了自动回车才补一个 Enter —— 同样只有文本路径，因为这段代码（`:706`）位于第 4 步那个 `return` 之后。带 `keys` 的条目永远不补 Enter，不管复选框勾没勾。这对纯按键条目是对的（发完 Ctrl+J 再敲个 Enter 会把换行废掉）。

两种输入模式的取舍：逐字输入不碰剪贴板但长命令慢；粘贴快但会短暂占用剪贴板。由复选框 `ChkType` 控制，默认逐字。

### 命令表的加载与切换

- `Get-Profiles`（`:338`）扫描脚本目录下的 `commands-*.json`，文件名后缀就是切换菜单里显示的 profile 名；另外兼容一个无后缀的 `commands.json`（显示为 `default`）。不传 `-Config` 时取排序后的第一张。
- `Read-Config`（`:370`）用 `[System.IO.File]::ReadAllText` 读，**不能换成 `Get-Content`** —— 后者会用 ANSI 代码页解码，中文全废。
- `Set-Profile`（`:1081`）先解析成功再提交，坏文件不会把运行中的面板搞崩。切换 profile **故意不动已绑定的终端**：语义是「同一个窗口，换一套命令」。
- `New-ProfileMenu`（`:1102`）每次点击都重新扫描目录，所以面板开着的时候丢进一张新表立刻可见。
- `Merge-UiText`（`:1069`）把新 profile 的 `ui` 块叠加在当前正在用的文字上，缺的键沿用旧值，这样一张只写了 `title` 和命令的新表也能跑。**注意不对称**：Set-Profile 走 merge，而底部的【重载命令表】按钮（`:1127`）是直接赋值 `$script:Cfg.ui`，不 merge —— 一张 `ui` 不完整的表在重载后会把按钮文字清空。

### 终端绑定与窗口布局

- 绑定有两条路：`New-Terminal`（`:588`）优先用 `wt.exe -w -1` 开一个全新的 Windows Terminal 窗口，然后靠「前后窗口快照对比 + 类名白名单」认出它；或者 `Show-TargetPicker`（`:526`）列出所有可见窗口让用户挑。
- 三份白名单各有用途，别混用：`$script:TermClasses` / `$script:TermProcs`（`:394`、`:404`）用来给选择器里的终端打 `[终端]` 前缀并排到前面，宽松无妨；`$script:SpawnClasses`（`:403`）用来自动识别刚启动的终端，**必须保持严格**，放进 `Chrome_WidgetWin_1` 这种泛类名会认错窗口。
- `Set-DockLayout`（`:631`）里两套坐标系不能串：面板是 WPF 窗口，用设备无关像素（DIP）；目标终端走 `SetWindowPos`，用原始像素。转换靠 `HwndSource.CompositionTarget` 的两个变换矩阵，高 DPI 下写错就会错位。
- 一个 `DispatcherTimer`（`:1168`）每 1.5 秒探一次绑定窗口是否还存在，让状态栏不说谎。

### 搜索

`Test-ItemMatch`（`:996`）只是把 `label + desc + tags + cmd + keys` 拼起来做一次小写子串匹配，**没有拼音引擎**。README 里说的「输入 `ys` 能搜到压缩上下文」完全来自 JSON 里 `tags` 字段的人工约定 —— 写新条目时按惯例同时放英文关键词和拼音首字母，否则搜不到。

## 不可违反的硬约束

这几处都是踩过坑之后固定下来的，改之前先读一遍：

- **`AgentCliPalette.ps1` 必须保持纯 ASCII。** Windows PowerShell 5.1 读不带 BOM 的 `.ps1` 时用系统 ANSI 代码页解码，脚本里写中文会直接变成乱码。所有用户可见文字都必须住在 JSON 里。脚本里唯一硬编码的字符串是配置加载失败时那个 MessageBox 的标题（`:384`），因为此时 `ui.title` 还没读进来。
- **`.cmd` 必须是 CRLF 换行。** LF 的批处理文件 `cmd.exe` 会解析错。已用 `.gitattributes` 钉死。
- **启动器 `启动命令面板.cmd` 不要加 `-ExecutionPolicy Bypass` 或 `-WindowStyle Hidden`。** 这对组合是杀毒软件识别 PowerShell 加载器的典型特征，会导致 `.cmd` 被直接删除。现在的做法是先正常显示控制台，等界面建好后由脚本自己调 `Nx::HideOwnConsole()` 隐藏（`:1374`）—— 启动失败时报错还留在屏幕上。
- **不要给需要写 `$script:` 变量的事件处理器加 `.GetNewClosure()`。** 闭包会被托管在自己的动态模块里，里面对 `$script:` 的赋值传不回外层作用域，绑定窗口的功能就曾因此静悄悄失灵。现存两处写法是刻意的：`Show-TargetPicker` 里确实用了闭包（需要捕获局部的 `$dlg`、`$lb`），但结果是通过 `$dlg.Tag` 传出来的，不靠 `$script:` 赋值（`:558`）；profile 菜单的点击处理器则是普通 scriptblock（`:1113`）。
- **`IntPtr` 是结构体，判空要写 `-ne [IntPtr]::Zero`。** `if ($h)` 对取消掉的对话框也会成立（`:1058`）。
- **`Get-Profiles` 返回 `.ToArray()` 而不是 `, $x`。** 用逗号包裹的那个惯用法会让调用方的 `$known[0]` 拿到整个数组。

## 命令表内容的来源约定

命令表里的每一条都是对着本机装的那个版本核过的：先读 CLI 自己的 `--help`，斜杠命令和快捷键则从安装好的可执行文件/bundle 里把注册表 grep 出来。**不要凭记忆往 JSON 里加命令。**

同样的原因，有些内容是**故意留空**的，补之前先确认：Codex 的 `/approvals`、`/limits`、`/undo` 在二进制里查不到；OpenCode 没有快捷键分组（能 grep 到的那批属于它的 Web/桌面界面，不是 TUI）；pi 的快捷键取的是 Windows 分支（它源码里有 `windowsKeybindings ? "alt+v" : "ctrl+v"` 这类判断，所以本机上是 Alt+V / Ctrl+Q / Alt+P，和其他平台不同）。

这个约定的由来：面板早期写着 Claude Code 的换行是 Shift+Enter，而它实际提示的是 `ctrl+j for newline` —— Shift+Enter 得先跑 `/terminal-setup` 写入绑定，有些终端还根本不支持。

## 命令表格式

```json
{
  "settings": { "sidebarWidth": 300, "insertMode": "type", "autoEnter": false,
                "topMost": false, "shell": "auto", "workDir": "" },
  "ui": { "title": "...", "btnBind": "绑定窗口" },
  "groups": [
    { "name": "启动 / 会话", "items": [
      { "label": "启动交互模式", "cmd": "mycli", "desc": "最常用的一条", "tags": "start qd" },
      { "label": "换行（按键）", "keys": ["Ctrl+J"], "desc": "只发按键", "tags": "newline hh" }
    ]}
  ]
}
```

条目里 `cmd` 和 `keys` 按约定二选一。`label` 写人话（按钮上显示），`cmd` 是真实命令（只在悬停提示里出现，想让光标停在引号中间就写 `mycli ""`），`desc` 一句解释，`tags` 放英文关键词和拼音首字母。

**两个都填时 `keys` 优先，`cmd` 被静默丢弃** —— 不报错，界面上也留不下任何痕迹：发送走按键分支（`:689`），右键复制（`:714`）复制出来的是 `Ctrl+J` 这种字面量，悬停提示显示的也是按键，所以那条 `cmd` 在界面上完全不可见；自动回车也一并跳过（见上面「一次点击的完整链路」第 6 步）。但反直觉的一处是 `Test-ItemMatch` 把两个字段**并列**收进了搜索索引，于是这种条目会「搜得到、悬停看不见、点了发别的」。两个都空则在 `:672` 静默 return，什么都不做。四张内置表目前这两种条目都是 0 个。

`keys` 的可用键名见 `$script:VkNames`（`:412`）：`Ctrl`/`Shift`/`Alt`/`Win` 修饰符，`Enter`、`Tab`、`Esc`、`Space`、`Backspace`、`Del`、`Ins`、`Home`、`End`、`PgUp`、`PgDn`、方向键、`F1`-`F12`，以及任意单个字符。方向键和 Ins/Del/Home/End/PgUp/PgDn 属于扩展键，`Nx::IsExtended`（`:262`）会给它们补 `KEYEVENTF_EXTENDEDKEY` 标志，否则控制台收到的是小键盘上的孪生键。

四张内置表的 `settings` 和 `ui` 键集完全一致，新增表时照抄一份最省事。文件必须是 UTF-8（可以不带 BOM）。

`commands-local*.json` 已被 `.gitignore` 排除，用它放不想进仓库的本地命令表 —— 面板照样能发现它。

## 已知限制

- **管理员权限的终端收不到按键。** 普通权限进程无法向高权限窗口发送输入，这是 Windows 的 UIPI 隔离，绕不过去。面板会明确报错（`ui.errFocus`）而不是把命令误输入到自己身上。这种情况用右键复制。
- **仅支持 Windows**，整个实现建立在 WPF 和 user32 的 `SendInput` / `AttachThreadInput` 上。
- 一个面板窗口一次只能绑一个终端。
