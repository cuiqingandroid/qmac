# QuickKit

常驻 macOS 菜单栏的快捷小工具。Swift + AppKit/SwiftUI 写的，**打包后 600KB 出头，dmg 不到 600KB**。

| 功能 | 默认快捷键 |
| --- | --- |
| 快速搜索（应用 + 计算器） | `⌥Space` |
| 剪贴板历史 | `⌘⇧V` |
| 菜单栏图标（找回被折叠的图标） | `⌘⇧M` |
| 锁屏 | `⌘⌥L` |

快捷键都能在设置里重新录制，被系统或别的 App 占用会当场提示。

## 安装

到 [Releases](https://github.com/cuiqingandroid/QuickKit/releases) 下载 dmg，拖进「应用程序」。

App 用的是 ad-hoc 临时签名（没有 Apple 开发者账号），首次打开若被 Gatekeeper 拦住：右键 → 打开，或者

```bash
xattr -dr com.apple.quarantine /Applications/QuickKit.app
```

自己编译：

```bash
./scripts/bundle.sh     # 产物在 dist/：.app / .zip / .dmg
```

只跑不打包：`swift build -c release && .build/release/QuickKit`

## 四个功能

### 1. 快速搜索（`⌥Space`）

一个输入框同时干两件事：

- **搜应用**：扫描 `/Applications`、`/System/Applications` 等目录，支持前缀、词首、首字母缩写（`vsc` → Visual Studio Code），回车打开。
- **算数**：输入框里直接写算式，第一行实时出结果。回车 = 结果**存进历史 + 复制到剪贴板**，输入框清空但结果留在 `ans` 里；接着**直接输入 `+ 15%` 这样以运算符开头的内容，会自动接着上一步算**（多步计算）。`⌘↵` 只复制不记历史。

计算器支持：

```
1280*0.6 + 15%      百分号相对左值：200+10% = 220，200*10% = 20
2^10   2**10        幂      5!  阶乘      10 mod 3  取模
1.2w  3万  1.5亿  2k  1m     数量后缀
0xff + 0b1010       进制字面量      1,234,567 + 1     千分位
sqrt abs round ceil floor sign trunc exp
sin cos tan asin acos atan sinh cosh tanh  ln log log2 log10
min(1,5,3) max sum(1000,2000) avg(1,2,3) pow(2,10)
pi  e  tau  ans     2(3+4)  3pi  隐式乘法
```

结果附带十六进制、二进制和「万」的换算。引擎是手写词法 + 递归下降（`Sources/QuickKit/Calculator.swift`），**不用 eval**，32 条用例自测。

### 2. 剪贴板历史（`⌘⇧V`）

- 轮询 `NSPasteboard.changeCount`，文本和图片都记，重复内容自动去重并提到最前。
- 数据在 `~/Library/Application Support/QuickKit/`，默认留 300 条，置顶的不受限制。
- `↑↓` 选择，`↵` 粘贴回刚才那个应用，`⌘↵` 只复制，`⌘1`–`⌘9` 快速选取，`⌘P` 置顶，`⌘⌫` 删除。
- 密码管理器写剪贴板时会打 `org.nspasteboard.ConcealedType` 标记，这类内容自动跳过；也可以在设置里加正则忽略规则。

### 3. 菜单栏图标（`⌘⇧M`）

菜单栏放不下时，macOS 会把图标默默挤出屏幕，看不见也点不着。按下快捷键，**刘海正下方**弹出一条横条，只列**被折叠**的那些图标，点一下就能展开它原本的菜单。菜单栏图标的托盘菜单里也有同样的子菜单。

关于 macOS 26（Tahoe）的实现说明：

- 所有状态栏图标的**窗口**现在都归 ControlCenter 所有，`CGWindowList` 拿不到图标属于哪个 App，只能知道哪些窗口真的画在屏幕上。
- 但每个 App 仍然持有自己的 `AXExtrasMenuBar` **辅助功能层级**，从那里能拿到真实应用名，`AXPress` 也能直接给元素发动作——**不要求图标可见**。
- 所以这里把两边对起来：AX 提供名字与可触发的元素，`CGWindowList` 按 x 坐标判断哪些真的可见。
- 好处是不需要 [Ice](https://github.com/jordanbaird/Ice) 那套「合成 ⌘ 拖拽 + 多层事件 tap 投递」的机制（它依赖每个图标各自的 `ownerPID`/`windowID`，在 macOS 26 上正好塌了），也**不需要屏幕录制权限**。
- 做不到的事：没法像 Bartender/Ice 那样把图标收进折叠区、按原样渲染图标像素——那需要屏幕录制逐个截图 + 模拟拖拽移动图标。

⚠️ 这个功能**必须开启辅助功能权限**。

### 4. 锁屏（`⌘⌥L`）

设置里可选，默认「自动」按顺序尝试：

1. `CGSession -suspend` 切到登录窗口——**不需要任何额外权限，最可靠**
2. 模拟系统的 `⌃⌘Q`（需要辅助功能权限）
3. `pmset displaysleepnow` 立即息屏（是否上锁取决于系统「睡眠后要求输入密码」设置）

## 权限

- **辅助功能**：菜单栏图标功能必需；剪贴板的「自动粘贴」和 `⌃⌘Q` 锁屏方式也需要。没授权时自动粘贴退化成「已复制，自己按 ⌘V」。
- 全局快捷键走 Carbon `RegisterEventHotKey`，**不需要**权限。
- 默认锁屏方式**不需要**权限。
- 完全不需要屏幕录制权限。

⚠️ ad-hoc 签名的代价：**每次重新编译安装，辅助功能权限都要重新勾一次**（签名摘要变了，系统认不出是同一个程序）。

## 已知限制

- **自己的图标也可能被折叠**。macOS 没有公开 API 能让某个状态项固定不被挤掉，位置完全由系统和用户的 ⌘ 拖拽决定（代码里设了 `autosaveName`，只能保证重启后回到原位）。菜单栏太挤时，用快捷键就好。
- 应用搜索不支持拼音首字母。

## 目录结构

```
Sources/QuickKit/
  main.swift              入口（accessory 模式，不进 Dock）
  AppDelegate.swift       菜单栏、快捷键注册、面板与窗口调度
  Settings.swift          UserDefaults 配置 + 开机自启
  HotKey.swift            Carbon 全局快捷键注册与占用探测
  AppIndex.swift          本机应用索引（快速搜索用）
  Calculator.swift        计算引擎
  ClipboardStore.swift    剪贴板历史存储（JSON + 图片文件）
  ClipboardWatcher.swift  changeCount 轮询、写回剪贴板
  MenuBarItems.swift      通过 AX 枚举/触发菜单栏状态项
  LockScreen.swift        三种锁屏方式
  Paster.swift            CGEvent 模拟 ⌘V + 辅助功能权限
  Panel.swift             无边框浮动面板：定位、焦点回归、键盘转发
  Diagnostics.swift       启动时写 diagnostics.txt
  Views/                  四个界面（SwiftUI）
scripts/
  bundle.sh               编译 → 组装 .app → 图标 → 签名 → zip/dmg
  make-icon.py            生成图标（纯标准库，不装 Pillow）
  calc-test.swift         计算引擎自测
```

排查问题先看 `~/Library/Application Support/QuickKit/diagnostics.txt`——每次启动会写一份，含权限状态、四个快捷键各自的注册结果、菜单栏状态项枚举。

⚠️ 从终端直接跑 `QuickKit.app/Contents/MacOS/QuickKit` 时，TCC 会把**终端**当成责任进程，读到的权限状态是错的。要看真实状态必须用 `open` 正常启动再读该文件。

调试参数：`--show-search`、`--show-clipboard`、`--show-menubar`、`--selftest`、`--menubar-probe`。

## 打赏

免费开源，觉得顺手可以请我喝杯咖啡，完全自愿。App 内菜单栏图标 → 「请作者喝杯咖啡…」也能打开。

| 微信支付 | 支付宝 |
| --- | --- |
| <img src="assets/donate-wechat.png" width="220"> | <img src="assets/donate-alipay.png" width="220"> |

## License

MIT
