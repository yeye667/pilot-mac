# dsh-pilot-mac

DeepSeek Harness 的桌面自动化插件 —— **macOS 适配版**。

- 包名：`@yeye667/dsh-pilot-mac`
- 版本：`0.7.0-mac.4`
- 上游（Windows 原版）：[momasiku/dsh-pilot](https://github.com/momasiku/dsh-pilot)
- **给使用者的安装说明（可直接转发）**：[INSTALL.md](INSTALL.md)
- 技术说明：[README-macOS.md](README-macOS.md)；上游原文档：[README-upstream.md](README-upstream.md)

给模型装上眼睛和手：`screen_view` 截图、`desktop_control` 点/拖/滚/打字、`desktop_sequence` 批量执行。
Windows 上仍走 PowerShell + Win32/UIA；macOS 上换成随包编译的 Swift 助手（CoreGraphics + Accessibility API）。

## 当前状态（真机 SDK 实测）

| 门禁 | 结果 |
|---|---|
| 协议门禁（真实 `lib/index.js` + stub 助手） | **23/23** |
| `swiftc -typecheck`（GitHub macOS runner，真实 SDK） | **通过** |
| `swiftc -O` 编译出 `pilot-mac` | **通过** |
| 无头 `pilot-mac selftest` | **通过** |

CI 定义在 [`.github/workflows/macos.yml`](.github/workflows/macos.yml)，push 或手动触发。
真机 SDK 上抓出并已修复的三个问题（详见 README-macOS.md 第 6 节）：

1. `CGContext.height` 是 `Int`，与 `CGFloat` 行度量混算 → 显式转换；
2. macOS 26 SDK 把 `CGWindowListCreateImage` 标为 **unavailable** → 窗口截图改 `screencapture -l`；
3. 同一 SDK 把 `CGDisplayCreateImage` 也标为 **unavailable** → 整屏截图改 `screencapture -R`（坐标契约不变）。

## 安装（在 Mac 上）

```bash
# 1) 先停掉上游的 Windows 专用行
dsh plugin remove @momasiku/dsh-pilot

# 2) 从 tarball 安装（不要用目录，理由见 README-macOS.md）
dsh plugin add ./yeye667-dsh-pilot-mac-0.7.0-mac.4.tgz
```

然后到「系统设置 → 隐私与安全性」给**运行 Harness 的那个 App** 开
**屏幕录制** 与 **辅助功能**，重启该 App。

## 验收（Mac 上四步）

```bash
chmod +x tools/*.sh
./tools/build.sh                 # 编译 Swift 助手
./build/pilot-mac selftest       # 两个权限应为 true；captureScale 在 Retina 上为 2
./tools/verify.sh                # 真截一张带标尺和十字的图
```

`selftest` 两权限为 `true`、`verify.sh` 出的图坐标正确，即整条链路可用。

## 仓库结构

当前仓库把包体放在 `.github/` 下（CI 的「Locate the package」步骤已兼容这种布局）：

```
.github/workflows/macos.yml     CI：协议门禁 + typecheck + 编译 + selftest
.github/lib/index.js            平台无关：三个工具、像素契约、warm worker、接管环
.github/lib/darwin/*.swift      macOS 后端（坐标空间、窗口/AX、输入、采集、动作、运行时）
.github/lib/scripts/*.ps1       Windows 后端（原样保留）
.github/tools/                  构建、验收脚本与协议测试替身
.github/package.json            包元信息
.github/cordis.patch.yml        插件行定义
```

建议后续把 `lib/`、`tools/`、`package.json`、`cordis.patch.yml` 挪到仓库根，
让 `.github/` 只留 workflow —— CI 两种布局都能跑。

## 许可

MIT（继承上游）。
