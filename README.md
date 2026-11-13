# Panelet

<img src="branding/panelet/app-icon.png" width="144" alt="Panelet Interlock logo">

**One screen. More room.**

一块屏幕，多个独立工作空间。支持竖屏上下两分、横屏左右两分。

根据显示器方向拆成两个独立全屏空间。多块横屏、竖屏可以同时分屏。每半屏都有自己的桌面、菜单栏和全屏空间。

拆分时，两个虚拟屏占用竖屏原来的桌面位置，macOS 直接处理光标、拖拽和键盘焦点。物理竖屏临时移到排列边缘，用来显示两路画面。合并时恢复物理显示器的排列。

实现沿用 [Telas](https://github.com/eduardoworrel/telas) 的做法：`CGVirtualDisplay`（私有 API）加 ScreenCaptureKit。`CGVirtualDisplay` 没有公开文档，系统更新后可能失效。

## 运行

需要 macOS 14 或更高，以及 Xcode 或 Command Line Tools。

```sh
git clone https://github.com/rankangkang/panelet.git
cd panelet
./build.sh --install
```

查看当前显示器可以直接运行已构建的 App 二进制。

```sh
/Applications/Panelet.app/Contents/MacOS/Panelet --list
```

日常启动、授权和后续更新统一使用 `/Applications/Panelet.app`。`build/Panelet.app` 仅作为构建产物，不作为第二个运行或授权入口。保持 Bundle Identifier 和签名身份不变，以沿用已有授权。

装到“应用程序”并打开：

```sh
./build.sh --install
```

## 两种模式

每块显示器可以独立使用以下模式；竖屏上下等分，横屏（含方屏）左右等分。

### 拆分桌面

从菜单栏进入「拆分桌面」，直接选择显示器拆分或合并。不需要选择应用。上下半屏作为两个独立桌面长期使用，可以打开多个窗口、拖动窗口、各自进入或退出原生全屏。退出全屏、关闭窗口都不会合并桌面。

点击「还原桌面…」会结束该屏幕上的快捷组合并合并桌面。合并时保留当前窗口布局，迁回拆分期间新打开的窗口；已主动移动到其他显示器的普通窗口不再被拉回。

### 快捷窗口分屏

默认按 **⌃⇧S** 呼出面板，选择目标显示器和两个分区的具体窗口。可拖放窗口卡片，也可搜索、按 ↑↓ 和回车选择；支持同一应用的两个不同窗口。两个窗口都选好后自动开始，只有两边都成功进入原生全屏才算完成。

- 任一所选窗口退出原生全屏、关闭或应用退出，会在连续确认后自动结束整个组合。
- 切换桌面、切换焦点和短暂查询失败不会被当作退出；睡眠、屏幕休眠和用户会话切换期间暂停检测，恢复后重新确认。
- 如果进入前屏幕没有拆分，结束组合时合并屏幕并恢复窗口。
- 如果进入前已拆分桌面，结束组合只恢复这两个窗口，保留两个桌面。
- 两个窗口仍打开时，再次呼出面板可按回车复用最近组合；最近组合仅在本次 App 运行期间保留。

按 **⌃⇧J** 还原鼠标所在的分屏；只有一块分屏时直接还原它。结束快捷组合会保留进入前已有的桌面拆分。多块分屏且无法定位目标时打开选择框。菜单栏和面板也提供「还原…」入口。退出 App 或重新启动会先确认，再依次合并所有分屏。恢复失败或等待超过 15 秒时，可选择「仍然退出」，保留恢复记录后退出；恢复期间再次点击退出也可立即选择此选项。

准备过程中可按 Esc 或点击「取消」。任何窗口无法全屏时会撤销本次操作。恢复失败时保留可用桌面及恢复信息，可从菜单选择「重试恢复窗口…」；完成恢复前暂停新的分屏操作。

拆分完成后，每个区域会显示三秒编号（如 `1.1`、`1.2`），与选窗面板对应。分屏期间每秒检查被画面覆盖的物理桌面，将落在其上的可移动普通窗口补回对应分区；最小化、隐藏应用和全屏窗口不主动搬动。睡眠、布局变化、准备和合并期间暂停补位。

### 异常退出恢复

App 在改变显示器布局前，原子保存物理显示器排列及可识别的组合窗口状态。下次启动时，显示器配置相同则恢复原排列，并尝试恢复仍存在的组合窗口。窗口匹配同时检查窗口 ID、进程 ID 和应用启动时间，避免操作后来重启的应用。

恢复记录保存在 `~/Library/Application Support/dev.cmkk.panelet/recovery.json`，不记录窗口标题或画面。正常恢复完成后删除。强制退出无法保存正在进行的所有系统动画和 Space 状态，也不会重建已经关闭的窗口；异常恢复仍需真机验证。没有 WindowServer ID 的少数窗口只能在本次运行中还原。

## 设置

设置窗口按「桌面分屏」「快捷键」「权限」「诊断」分类。桌面页可预览目标屏幕的分区方向；权限页查看授权状态；运行日志、复制日志及重试恢复窗口位于诊断页。

## 第一次授权

屏幕录制用于读取两路画面和生成窗口预览，辅助功能用于迁移窗口和防止鼠标进入临时停放的物理屏桌面。

1. 从快捷面板进入设置，点“授权屏幕录制”和“授权辅助功能”，在弹窗里允许。
2. 如果系统设置的列表里没有这个 App，点 **+**，选 `/Applications/Panelet.app`，勾上。
3. 点控制窗口里的 **重新启动**，确认两项权限都显示「已授权」。

`./build.sh` 默认沿用已有 Panelet 或旧版 VerticalSplitDemo 的证书，并在替换前验证新包符合原签名要求。首次构建会使用钥匙串里唯一有效的 Apple Development 证书。如果有多个证书，可用 `PANELET_SIGN_IDENTITY` 指定名称或指纹，之后的构建会沿用该身份。请从固定的 App 路径启动，首次授权后，常规重编译可沿用授权。`--install` 更新时优先沿用「应用程序」里那份 App 的签名。

在 **系统设置 → 桌面与程序坞** 打开 **显示器使用不同的空间**。修改后按系统提示重新登录。

## 怎么确认链路是通的

- 「显示器」设置中会出现「上半屏」和「下半屏」，日志会列出两路首帧的像素尺寸。对于当前 `1296×2304` 点、2× 的竖屏，每半屏应收到 `2592×2304` 像素。
- 把鼠标移过中线、拖拽窗口，再分别点进两边输入文字。两个半屏可以分别保持原生全屏。
- 拆分时，原竖屏上的普通窗口放在对应上半屏的普通桌面，可以通过调度中心切回。合并时，选来分屏的两个窗口回原桌面；若原屏仍在分屏，则回到它的上半屏。其他普通窗口会在虚拟屏移开前迁回对应物理屏；目标物理屏不可用时迁往可用显示器。

快速分屏会在两个所选窗口均进入原生全屏后完成。若其中一个窗口无法全屏，App 会撤销此次拆分。合并时也会恢复所选窗口原来的最小化、隐藏或全屏状态。开启台前调度时，macOS 可能会把原先最小化到程序坞的窗口收进台前调度侧栏。App 会在合并结果和日志中提示。

## Xcode

打开 `Panelet.xcodeproj`，直接 Run。工程里已经设好这些项：

| 项 | 值 |
| --- | --- |
| Deployment Target | macOS 14.0 |
| Swift Language Version | Swift 5 |
| Bridging Header | `Panelet/VirtualDisplay.h` |
| Info.plist | `Panelet/Info.plist`（关闭 Generate Info.plist File） |
| Bundle Identifier | `dev.cmkk.panelet` |
| Code Signing | Manual，Sign to Run Locally（identity `-`） |
| Hardened Runtime | 打开 |
| App Sandbox | **关闭** |
| Entitlements | `Panelet/Panelet.entitlements`，里面是空的 |

不要在 Signing & Capabilities 里加上 App Sandbox。`CGVirtualDisplay` 在沙盒里创建会失败。屏幕录制和辅助功能不是 entitlement，它们是系统隐私权限。

`VirtualDisplay.h` 只作为 Bridging Header，不要把它加进 Compile Sources。

链接的系统框架包括 AppKit、ScreenCaptureKit、CoreMedia、CoreVideo、IOSurface、ApplicationServices、Carbon 和 QuartzCore。

## 排错

**编译报 `CGVirtualDisplay` 找不到。** Bridging Header 没有指到 `Panelet/VirtualDisplay.h`，或者这个头文件被当成源文件编译了。

**一点拆分，日志说创建失败或 displayID 为 0。** 多半开了沙盒，或者不是从 `.app` 启动的。私有 API 从裸二进制里经常直接失败。用 `open /Applications/Panelet.app`。

**拆分按钮灰色。** 查看控制窗口的屏幕录制、辅助功能和独立空间状态。通过系统设置完成授权或重新登录，再启动 App。

**创建或采集失败后已恢复。** 查看日志里的具体阶段。2× 竖屏需要两个虚拟屏都启用相应的 HiDPI 模式并收到对应尺寸的画面。

**拆分或合并时，画面短暂停顿。** macOS 重排显示器时可能短暂跳帧。单独合并会保留另一组分屏；最后一组结束时才释放闲置的虚拟屏。

**鼠标丢了。** 按合并快捷键（默认 **⌃⇧J**），选择竖屏并确认。也可以从菜单栏打开合并确认框。

**权限列表里怎么也找不到 App。** 用 **+** 手动选 `.app`。不要选 `Contents/MacOS` 里的二进制。

## 开发验证

不操作桌面的检测逻辑测试：

```sh
./tests/run.sh
```

`./build.sh` 编译并签名本地 App，不替换 `/Applications` 中正在运行的版本。`./build.sh --install` 要求先正常退出旧版本。

解锁后的真机验收清单：

- 普通竖屏开始快捷组合，分别测试上方和下方退出全屏，确认另一边退出、窗口回原处、显示器排列恢复。
- 先拆分桌面，再开始快捷组合；结束后上下桌面必须保留，两个窗口回到各自原来的半屏或物理屏。
- 桌面模式单独退出应用全屏或关闭窗口，不得合并。
- 两个同应用窗口、原先最小化/隐藏/全屏的窗口、关闭所选窗口、应用退出。
- 无法全屏、准备中取消、AX 暂时无响应、恢复失败后重试。
- 双竖屏分别运行，结束其中一组不得打断另一组；普通窗口主动移出后不得被拉回。
- 锁屏/解锁、睡眠/唤醒、显示器拔插与分辨率改变；期间不得把短暂状态当作退出。
- 使用测试窗口进行异常退出及下次启动恢复测试，不用有未保存内容的工作窗口。

2026-11-13 已完成退出全屏自动还原、保留已有桌面拆分和双竖屏隔离的真机复测，详见 [验收记录](tests/acceptance-2026-11-13.md)。测试快照可用 `python3 tests/check-acceptance.py build/acceptance` 复核。

## 品牌与兼容性

Panelet 使用 Interlock 黑白标志，Dock 图标与菜单栏模板随 App 打包。定稿源文件位于 [branding/panelet](branding/panelet)。

Bundle Identifier 已改为 `dev.cmkk.panelet`。从旧标识首次升级后，需要重新授权辅助功能和屏幕录制；之后固定使用此标识、安装路径及签名身份。首次安装 Panelet 时会把旧的 `/Applications/VerticalSplitDemo.app` 移到本地 `build/previous-install/`，保留回退副本。也继续兼容旧的 `VERTICAL_SPLIT_SIGN_IDENTITY` 环境变量。
