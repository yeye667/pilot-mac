# dsh-pilot on macOS

`@momasiku/dsh-pilot-mac` 是 [`@momasiku/dsh-pilot`](https://github.com/momasiku/dsh-pilot) 的 macOS 分支：
同一套工具名（`screen_view` / `desktop_control` / `desktop_sequence`）、同一套参数、同一套像素契约，
底下换成了 macOS 自己的东西。

| | Windows（上游） | macOS（本包） |
|---|---|---|
| 传感器 / 执行器 | PowerShell + C# 桥，P/Invoke Win32 | 一个 Swift 程序，CoreGraphics + Accessibility API |
| 截图 | `Graphics.CopyFromScreen`（BitBlt） | `CGDisplayCreateImage` / `CGWindowListCreateImage` |
| 输入 | `mouse_event` / `keybd_event` / `SendKeys` | `CGEvent`（含拖拽专用事件类型与 click-state） |
| 窗口枚举 | `EnumWindows` + `GetWindowText` | `CGWindowListCopyWindowInfo` |
| 控件树 | UI Automation + `CacheRequest` | `AXUIElement` 递归（自带上限与惰性树热机） |
| 粘贴 | 剪贴板 + `Ctrl+V` | `NSPasteboard` + `⌘V`（快照并还原全部类型） |
| 权限 | 无 | 系统设置里的「屏幕录制」+「辅助功能」 |
| 接管环 | 覆盖层窗口 + 全局 Esc 钩子 | 同协议，同 token 文件，同 Esc 语义 |

`scale` 的含义两边一致：截图像素 = 屏幕物理像素。Windows 靠 per-monitor DPI 感知做到，
所以 `scale` 恒为 1；macOS 靠「全机统一取最大 backing scale」做到，Retina 上 `scale` = 2。
模型从图里读到的坐标 + `originX/originY`，仍然就是可以直接交给 `desktop_control` 的坐标。

---

## 1. 安装

在 Mac 上：

```bash
# 1) 先把上游那个只支持 Windows 的行停掉（它不会报错，但每次调用都找不到 powershell.exe）
dsh plugin remove @momasiku/dsh-pilot        # 或在 GUI 插件面板里禁用 pilot 行

# 2) 安装本包：用 tarball，不要用目录
dsh plugin add /path/to/momasiku-dsh-pilot-mac-0.7.0-mac.1.tgz
```

**不要用目录安装（`dsh plugin add /path/to/dsh-pilot-mac`）。** 两条实测过的原因：

1. pnpm 把本地目录当 **link** 挂载，链接包不解析自己的 `dependencies`，激活时报
   `Cannot find package '@deepseek-ai/schemastery'`，这一行永远起不来；
2. 之后 `dsh plugin remove` 时 pnpm 会把那个**源目录清空**（实测：整个 `dsh-pilot-mac/`
   连同 `lib/` 一起没了）。

用 tarball（`npm pack` 的产物）安装时 pnpm 把包装进 store、依赖正常解析，实测
`application: applied`。改代码的流程因此是：改目录 → `npm pack` → 装新 tarball。

装完重启 Harness。插件行 id 是 `pilot-mac`，与上游的 `pilot` 不冲突，所以两个包可以同时存在，
但**同一时间只启用一个**：两者注册的工具名完全相同。

首次真正截图时，`lib/darwin/backend.js` 会用 `xcrun swiftc` 把 `lib/darwin/*.swift`
编译成 `~/Library/Caches/dsh-pilot/bin/pilot-mac-<hash>` 并缓存（几秒，只发生一次；
改源码后 hash 变了会自动重编）。二进制在本机编译，不带 quarantine 属性，Gatekeeper 不会拦。

需要 Xcode Command Line Tools：

```bash
xcode-select --install      # 已有则跳过
xcrun -f swiftc             # 应打印 swiftc 的绝对路径
```

## 2. 两个系统权限（必须手动给，程序无法代替）

| 权限 | 用在哪 | 不给会怎样 |
|---|---|---|
| 屏幕录制（Screen & System Audio Recording） | 截图、窗口标题 | 截图返回空/只有壁纸，窗口标题全空 |
| 辅助功能（Accessibility） | 点击、按键、读控件树、接管环的 Esc | 事件发不出去、`controls` 直接报错 |

给的对象是**运行 Harness 的那个 App**（DeepSeek Harness 本体；如果你从终端起服务，
那就是终端），不是 `pilot-mac` 这个二进制。改完权限**必须重启那个 App**，TCC 只在进程启动时读一次。

一次性自检：

```bash
~/Library/Caches/dsh-pilot/bin/pilot-mac-<hash> selftest
# 或直接跑源码编译出来的：
./tools/build.sh && ./build/pilot-mac selftest
```

输出是 JSON，关键字段：`screenRecording`、`accessibility`、`captureScale`、`pixelBounds`、
`displays[]`（每块屏的 points 与 pixels）、`hints[]`（缺什么、去哪里开）。

## 3. 验收（按顺序做，最快定位问题）

**在非 Mac 机器上**（改代码那台），先用配套的离线验证环境跑两道门禁——不需要 macOS、
不需要 Swift 工具链，专门拦「JavaScript 半边接错」和「Swift 结构坏了」：

```bash
cd ../verify-env && node run-all.mjs      # 首次需 npm install
# 期望：protocol gate 23/23 PASS，syntax gate 6 file(s) 0 error node(s)，退出码 0
```

**在 Mac 上**，按下面四步：

```bash
chmod +x tools/build.sh tools/verify.sh   # tarball 安装会丢 exec 位，目录安装一般不用

# 0) JavaScript 半边，任何机器都能跑（用 tools/stub-helper.mjs 顶替 Swift 助手）
node tools/test-protocol.mjs          # 期望 23/23 checks passed

# 1) Swift 半边能编译
./tools/build.sh                      # 产出 build/pilot-mac

# 2) 权限与几何
./build/pilot-mac selftest | python3 -m json.tool

# 3) 截一张图，看标尺和光标十字是否画在图上
./tools/verify.sh                     # 生成 build/probe.png + 打印采集结果 JSON
open build/probe.png
```

`tools/verify.sh` 之后，在 Harness 里按顺序问模型三件事，能覆盖住全部链路：

1. 「看一下屏幕」→ `screen_view`：返回图 + `<screen_capture>`，`scale` 与 `pixelBounds` 对得上。
2. 「把鼠标移到屏幕正中，然后截图」→ `desktop_control move` + `capture: true`。
3. 「列出窗口」/「列出前台窗口的控件」→ `windows` / `controls`。

## 4. 与 Windows 版的行为差异（都是有意为之）

1. **`scale` 是 2 而不是 1**（Retina）。凡是把图上的读数交给 `desktop_control` 的地方，
   都不要自己乘/除 2 — 助手内部按同一网格换算，`originX/originY` 也已经在那个网格上。
2. **窗口 `bounds` 略小**：Windows 的 `GetWindowRect` 含 DWM 不可见边框，macOS 的
   `kCGWindowBounds` 不含阴影与边框。
3. **窗口截图抓的是窗口本身**（`CGWindowListCreateImage(.optionIncludingWindow)`），
   所以被遮挡、被最小化到 Dock 的窗口也能抓到内容；Windows 抓的是那块屏幕像素。
4. **`focus` 是协作式的**：macOS 没有 `AttachThreadInput` 那类强抢前台的办法。
   拿不到前台就按 `tolerant` 决定「报错」还是「记一句 note 继续」，语义与 Windows 相同。
5. **控件是 macOS 角色**，映射到 Windows 的 ControlType 名字（`AXTextField` → `Edit`、
   `AXRow` → `DataItem`、`AXButton` → `Button`…），行格式逐字对齐：
   `<index> [<Role>] '<name>' @ <left>,<top> <w>x<h>  <disabled|offscreen|value=…>`
   索引同样是**未过滤遍历里的位置**，所以会跳号，也能跨 `controls` → `target` 往返。
6. **`offscreen` 是近似的**（AX 没有 `IsOffscreen`）：元素矩形与窗口矩形不相交即视为不可见。
7. **`controlTotal` 是「遍历到的元素数」**（上限 2000），与 Windows 的「过滤前真实后代数」
   在超过上限时会有差别；截断行会打印真实遍历总数（上游这一行恒为 0，是个 bug）。
8. **Esc 需要辅助功能权限**。没给权限时接管环照常显示，但 Esc 不会停；此时用 Harness 自己的
   取消（中断本轮）仍然有效，取消 token 是同一条路径。
9. **`type` 会还原剪贴板**（快照全部 pasteboard item 并在粘贴后写回）；Windows 只备份纯文本，
   富内容会被吃掉。这是修，不是退。

## 5. 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `pilot: the macOS helper needs a Swift compiler` | 没有 CLT | `xcode-select --install` |
| `swiftc exited with 1: …` | 源码/工具链版本问题 | 看 stderr 尾部；`swiftc --version` 应 ≥ 5.7 |
| `pilot: this process may not record the screen` | 屏幕录制没给 | 系统设置给 Harness 本体，重启它 |
| `pilot: this process is not trusted for Accessibility` | 辅助功能没给 | 同上 |
| 截图全黑/只有壁纸 | 权限给了但没重启 App | 退出并重开 Harness |
| `windows` 返回空数组 | 没有屏幕录制 → 标题全空被过滤 | 结果里会带一条 note 提示 |
| 点击位置差一倍 | 拿旧 `scale=1` 时代的坐标 | 用当前帧的 `originX/originY` + `scale` 重新算 |
| 编译产物想换位置 | — | `DSH_PILOT_MAC_BIN=/path/to/pilot-mac` 跳过编译直接用它 |
| 装完提示 `Could not find package '@deepseek-ai/schemastery'` | 用了目录安装（pnpm link，不解析 dependencies） | 改用 tarball 安装 |
| 激活报 `ENOENT ... \dsh-pilot-mac\lib\index.js`（路径是源码目录） | 这个 Harness 进程里先做过目录安装，dsh 按包名缓存了首次解析到的路径；仅重启前有效 | 重启 Harness 后再用 tarball 装；急着验证可临时换个包名 |

调试开关：

```bash
DSH_PILOT_MAC_BIN=/abs/path/pilot-mac      # 直接用预编译的助手
DSH_PILOT_MAC_BIN_PREFIX="…"               # 测试钩子：给帮助进程加前置参数（tools/stub-helper.mjs 用）
DSH_PILOT_FORCE_PLATFORM=darwin            # 在非 mac 上走 darwin 分支（只用于跑测试）
```

## 6. 代码地图

```
lib/index.js                 平台无关：三个工具、像素契约、warm worker、接管环、结果投影
lib/darwin/backend.js        darwin 派发层：找编译器、按 source hash 编译并缓存、拼参数
lib/darwin/Pilot.swift       坐标空间（点 ↔ 像素）、显示器枚举、权限、PNG、标尺、光标十字
lib/darwin/PilotWindows.swift窗口枚举（窗口服务器）+ 控件树（Accessibility）+ 行格式
lib/darwin/PilotInput.swift  鼠标 / 键盘 / 和弦解析 / 剪贴板粘贴
lib/darwin/PilotCapture.swift采集模式（window > region > screen）、合成、结果信封
lib/darwin/PilotAction.swift 12 个动作、settle 切片、取消点、结果信封
lib/darwin/PilotRuntime.swiftworker 线协议、接管环、selftest、入口
lib/scripts/*.ps1            Windows 那一半，原样保留（Windows 上仍然走它）
tools/stub-helper.mjs        协议替身，用来在任意平台测 JS 半边
tools/test-protocol.mjs      23 项协议/投影检查
tools/build.sh               只编译，不跑
tools/verify.sh              编译 + selftest + 一次真实截图
```
