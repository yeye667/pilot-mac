# 安装说明（Mac 版）

这是一个 DeepSeek Harness 的插件。装好之后，AI 就能看到你的屏幕、移动鼠标、点击和打字。

全程四步，大约 5 分钟。**需要 macOS 11 或更新**（Intel 或 Apple 芯片都行）。

---

## 第 1 步：下载

打开「终端」（访达 → 实用工具 → 终端），粘贴这一行并回车：

```bash
curl -L -o pilot.tgz https://github.com/yeye667/pilot-mac/releases/download/v0.7.0-mac.4/yeye667-dsh-pilot-mac-0.7.0-mac.4.tgz
```

不想用终端也可以：把上面那个 `https://...` 地址粘到浏览器地址栏，下载完成后把文件名改成 `pilot.tgz`。

文件只有 100 KB，几秒钟就下完。

---

## 第 2 步：安装

在终端里进入下载文件所在的文件夹（比如下载在「下载」文件夹）：

```bash
cd ~/Downloads
dsh plugin add ./pilot.tgz
```

看到类似 `application: applied` 就是装好了。

> **如果提示 `dsh: command not found`**：这台 Mac 还没装 DeepSeek Harness，先去装它，装完再回来做这一步。
>
> **如果之前装过别人的 dsh-pilot**（那个是 Windows 专用的），先执行一次
> `dsh plugin remove @momasiku/dsh-pilot`，再执行上面的安装命令。

---

## 第 3 步：授权（必须做，否则点了没反应）

打开「系统设置」→「隐私与安全性」，找到下面两项，分别把 **DeepSeek Harness** 打开：

| 位置 | 要打开什么 |
|---|---|
| 隐私与安全性 → **屏幕录制** | DeepSeek Harness |
| 隐私与安全性 → **辅助功能** | DeepSeek Harness |

打开之后**完全退出 Harness 再重新打开**（⌘Q 退出，不是关窗口）。这一步不做，前面都白装。

---

## 第 4 步：验收（1 分钟）

重新打开 Harness，跟它说一句：

> 看一下我的屏幕

三种结果：

- **它返回了一张截图** → 装好了，可以直接用。
- **它说没有屏幕录制权限** → 回到第 3 步，确认是给 DeepSeek Harness 打开的，并且真的重启过。
- **它说缺少 Swift 编译器** → 在终端执行 `xcode-select --install`，按提示装完（约 2 GB），再试一次。

---

## 常见问题

**第一次截图要等几秒？**
正常。它会在后台编译一个小辅助程序，只发生一次，之后都是毫秒级。

**提示 `pilot: this process may not record the screen`**
屏幕录制没开，或者开了但没重启 App。

**提示 `pilot: this process is not trusted for Accessibility`**
辅助功能没开，处理方式同上。

**点得不准 / 位置偏？**
让 AI 先「截图看一下」再点。它能从截图里读坐标，比凭记忆点靠谱。

**想卸载**
```bash
dsh plugin remove @yeye667/dsh-pilot-mac
```

---

需要技术细节（坐标系、CI、Swift 源码结构）的，看同一个仓库里的 `README-macOS.md`；这份文件只讲怎么装。
