# QuickKit（macOS 原生版）

常驻菜单栏的快捷小工具。Swift + AppKit/SwiftUI 写的，**打包后 536KB，dmg 480KB**。

| 功能 | 默认快捷键 |
| --- | --- |
| 剪贴板历史 | `⌘⇧V` |
| 快速计算 | `⌥Space` |
| 菜单栏图标 | `⌘⇧M` |
| 锁屏 | `⌘⌥L` |

快捷键都能在设置里重新录制，被占用会当场提示。

## 编译与打包

```bash
./scripts/bundle.sh
```

产物在 `dist/`：`QuickKit.app`、`QuickKit-1.0.0.zip`、`QuickKit-1.0.0.dmg`。
只想跑一下不打包：`swift build -c release && .build/release/QuickKit`。

装到「应用程序」里：

```bash
cp -R dist/QuickKit.app /Applications/
```

App 用的是 ad-hoc 签名（没有 Apple 开发者账号）。首次打开如果被 Gatekeeper 拦住，右键 → 打开，或者：

```bash
xattr -dr com.apple.quarantine /Applications/QuickKit.app
```

## 三个功能

### 1. 剪贴板历史

- 轮询 `NSPasteboard.changeCount`（默认 0.7 秒），文本和图片都记，重复内容自动去重并提到最前。
- 数据在 `~/Library/Application Support/QuickKit/`：`history.json` + `images/`（原图 + 缩略图）。默认留 300 条，置顶的不受条数限制。
- 面板里直接搜；`↑` `↓` 选择，`↵` 粘贴回刚才那个应用，`⌘↵` 只复制，`⌘1`–`⌘9` 快速选取，`⌘P` 置顶，`⌘⌫` 删除，`esc` 关闭。
- 密码管理器写剪贴板时会打 `org.nspasteboard.ConcealedType` 标记，这类内容自动跳过；另外可以在设置里加正则忽略规则。

### 2. 菜单栏图标（找回被折叠的图标）

菜单栏放不下时，macOS 会把图标默默挤出屏幕，看不见也点不着。这个面板把**所有**状态栏图标列出来，
被折叠的标成橙色，`↵` 直接触发它的菜单——不需要图标显示在屏幕上。

实现说明（macOS 26 的现状）：

- 所有状态栏图标的**窗口**都归 ControlCenter 所有，`CGWindowList` 拿不到图标属于哪个 App，
  只能知道每个窗口在不在屏幕上。
- 但每个 App 仍然持有自己的 `AXExtrasMenuBar` **辅助功能层级**，从这里能拿到真实应用名，
  `AXPress` 也能直接给元素发点击动作，**不要求图标可见**。
- 所以这里把两边对起来用：AX 提供名字与元素，CGWindowList 按 x 坐标判断哪些真的画在了屏幕上。

做不到的事（老实说）：没法像 Bartender 那样把图标收进折叠区、在自己的条上按原样渲染图标——
那需要屏幕录制权限逐个截取图标像素，外加模拟 ⌘ 拖拽移动图标的位置。

**必须开启辅助功能权限**，否则这个面板读不到任何东西。

### 3. 锁屏

设置里可选，默认「自动」按顺序尝试：

1. `CGSession -suspend` 切到登录窗口——**不需要任何额外权限，最可靠**
2. 模拟系统的 `⌃⌘Q`（需要辅助功能权限）
3. `pmset displaysleepnow` 立即息屏（是否上锁取决于系统「睡眠后要求输入密码」设置）

### 4. 快速计算

Spotlight 风格输入框，边打边算。`↵` 复制结果并粘贴回原应用，`⌘↵` 只复制，`↑` `↓` 翻历史。

```
1280*0.6 + 15%      百分号相对左值：200+10% = 220，200*10% = 20
2^10   2**10        幂            5!         阶乘        10 mod 3   取模
1.2w  3万  1.5亿  2k  1m           数量后缀
0xff + 0b1010       进制字面量     1,234,567 + 1          千分位
sqrt abs round ceil floor sign trunc exp  sin cos tan asin acos atan sinh cosh tanh
ln log log2 log10   min(1,5,3) max sum(1000,2000) avg(1,2,3) pow(2,10)
pi  e  tau  ans     ans 是上一次的结果
2(3+4)  3pi         隐式乘法（数字紧跟数字不算，1..2 会报错）
```

结果附带十六进制、二进制和「万」的换算。引擎是手写词法 + 递归下降（`Sources/QuickKit/Calculator.swift`），不依赖任何表达式库。

跑引擎自测：

```bash
mkdir -p /tmp/qk && cp scripts/calc-test.swift /tmp/qk/main.swift && swiftc -O Sources/QuickKit/Calculator.swift /tmp/qk/main.swift -o /tmp/qk/calctest && /tmp/qk/calctest
```

## 权限

- **自动粘贴**需要「系统设置 → 隐私与安全性 → 辅助功能」勾选 QuickKit。没授权也能用，只是变成「已复制，自己按 ⌘V」。
- 全局快捷键走 Carbon `RegisterEventHotKey`，**不需要**辅助功能权限。
- 默认锁屏方式也不需要权限。
- 开机自启用 `SMAppService`，要求 App 在固定位置（建议放「应用程序」）。

## 目录结构

```
Sources/QuickKit/
  main.swift              入口（accessory 模式，不进 Dock）
  AppDelegate.swift       菜单栏、快捷键注册、面板与设置窗口调度
  Settings.swift          UserDefaults 配置 + 开机自启
  HotKey.swift            HotKeyCombo 与 Carbon 全局快捷键注册/占用探测
  ClipboardStore.swift    历史存储（JSON + 图片文件）
  ClipboardWatcher.swift  changeCount 轮询、写回剪贴板
  MenuBarItems.swift      通过 AX 枚举/触发菜单栏状态项
  Diagnostics.swift       把 App 自己视角的状态写到 diagnostics.txt
  LockScreen.swift        三种锁屏方式
  Paster.swift            CGEvent 模拟 ⌘V + 辅助功能权限
  Panel.swift             无边框浮动面板：定位、焦点回归、键盘转发
  Calculator.swift        计算引擎
  Views/                  四个界面（SwiftUI）
scripts/
  bundle.sh               编译 → 组装 .app → 图标 → 签名 → zip/dmg
  make-icon.py            生成图标（纯标准库，不装 Pillow）
  calc-test.swift         计算引擎自测
```

调试用启动参数：`--show-clipboard`、`--show-calc`、`--show-menubar`、`--selftest`、`--menubar-probe`。

排查问题时优先看 `~/Library/Application Support/QuickKit/diagnostics.txt`——App 每次启动会写一份，
内容包括辅助功能授权状态、四个快捷键各自的注册结果、以及菜单栏状态项的完整枚举。

⚠️ 从终端直接跑 `QuickKit.app/Contents/MacOS/QuickKit` 时，TCC 会把**终端**当成责任进程，
读到的权限状态是错的。要看真实状态，必须用 `open` 正常启动，然后读 diagnostics.txt。

⚠️ App 是 ad-hoc 临时签名，**每次重新编译安装，辅助功能权限都要重新勾一次**
（签名摘要变了，系统认不出是同一个程序）。有 Apple 开发者账号的话用固定签名身份可以避免。
