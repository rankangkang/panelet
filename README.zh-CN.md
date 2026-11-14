<p align="center">
  <img src="branding/panelet/app-icon.png" width="112" alt="Panelet 应用图标">
</p>

<h1 align="center">Panelet</h1>

<p align="center"><strong>One screen. More room.</strong></p>

<p align="center">把一块 Mac 显示器分成两个独立桌面，各自拥有菜单栏和原生全屏空间。</p>

<p align="center"><a href="README.md">English</a> · <strong>简体中文</strong></p>

<p align="center">
  <a href="#安装">安装</a> ·
  <a href="#快速上手">快速上手</a> ·
  <a href="#遇到问题">问题反馈</a> ·
  <a href="#参与贡献">参与贡献</a> ·
  <a href="#许可证">许可证</a>
</p>

## 功能

- **拆分桌面**适合长期保留两个工作区。可以在每个分区打开多个窗口，在分区之间拖动窗口，并分别使用 macOS 原生全屏。
- **快捷窗口分屏**在两个分区各放一个全屏窗口，适合临时配合使用两个窗口。可以搜索、拖放和交换窗口，也可以收藏常用组合。
- **多显示器布局**支持同时拆分多块显示器，并分别保存方向、比例和画面模式。默认竖屏上下拆分、横屏左右拆分，比例可选 1:1、2:1 或 1:2。
- **恢复桌面**在结束分屏时还原显示器排列，并尝试迁回窗口。异常退出后，下次启动也会在显示器配置匹配时尝试恢复。

## 安装

- macOS 14 或更新版本。
- Xcode 或 Xcode Command Line Tools，以及 Python 3。
- 首次构建默认使用钥匙串中有效的 Apple Development 签名身份。

运行以下命令从源码构建、安装并打开 Panelet。

```sh
git clone https://github.com/rankangkang/panelet.git
cd panelet
./build.sh --install
```

后续启动和权限授权都使用「应用程序」中的 `/Applications/Panelet.app`。如果首次安装时钥匙串中有多个有效证书，可用 `PANELET_SIGN_IDENTITY` 指定证书名称或指纹。

获取新版本源码后，从菜单栏选择「退出 Panelet」。有活动分屏时，按提示恢复后退出，再运行 `./build.sh --install`。更新会沿用已安装版本的签名身份和 Bundle Identifier `dev.cmkk.panelet`，以保留已有授权。

### 首次设置

1. 在「系统设置 → 桌面与程序坞」开启「显示器使用不同的空间」。如果刚修改此项，请按系统提示重新登录。
2. 打开 Panelet，按「使用导引」开启「屏幕录制」和「辅助功能」。如果权限列表里找不到 Panelet，可用 **+** 选择 `/Applications/Panelet.app`。
3. 返回导引，如果看到「重新启动并继续」，按提示操作。权限就绪后点「完成设置」。想立即体验时，可以点「试一次分屏…」并选择显示器和布局。之后可从菜单栏「使用导引…」重新打开。

## 快速上手

### 拆分桌面

从 Panelet 菜单栏图标打开「拆分桌面」，选择要拆分的显示器。桌面会保留到主动合并为止。要调整布局，先合并该屏，再到「设置… → 桌面分屏」调整方向和比例，预览会同步更新。

### 快捷窗口分屏

按 **⌃⇧S**（Control–Shift–S）打开选窗面板。选定显示器和两个窗口后，点击「开始分屏」或按回车。两个分区会分别显示所选窗口的原生全屏空间。

任一窗口退出全屏、关闭或所属应用退出时，组合会自动结束。如果该显示器此前已经拆成两个桌面，结束组合时会保留这两个桌面。

| 默认快捷键 | 操作 |
| --- | --- |
| **⌃⇧S** | 打开快捷窗口分屏面板 |
| **⌃⇧J** | 还原鼠标所在的分屏，或结束该屏上的快捷组合 |
| **Esc** | 在选窗面板中取消正在准备的分屏 |

两个全局快捷键可在「设置… → 快捷键」修改。要一次恢复所有显示器，可从菜单栏选择「恢复所有显示器…」。界面语言可在「设置… → 通用」选择简体中文、English 或跟随系统。

## 兼容性与隐私

Panelet 通过 macOS 私有接口 `CGVirtualDisplay` 创建两块虚拟屏，再用 ScreenCaptureKit 在物理屏上呈现两路画面。系统更新可能影响虚拟显示器的兼容性。受保护视频或限制采集的窗口可能显示黑屏。高刷新率、HDR 和广色域需在目标设备上验证。

屏幕录制权限用于合成分区和预览窗口。采集范围限于屏幕画面，画面在本机处理。辅助功能权限用于移动和恢复窗口，以及处理跨分区鼠标操作。偏好及收藏保存在本机，收藏包含应用标识与用于匹配的窗口标题。诊断报告仅包含经筛选的运行环境和性能数据，可预览后自行导出或分享。

## 遇到问题

| 现象 | 处理方式 |
| --- | --- |
| 分屏按钮不可用 | 到「设置… → 权限」检查屏幕录制、辅助功能和「显示器使用不同的空间」的状态。 |
| 分屏无法启动或画面异常 | 从菜单栏运行「检查运行环境…」，查看系统所需的接口是否可用。 |
| 窗口或显示器未恢复 | 从菜单栏选择「恢复所有显示器…」。如有窗口仍未归位，可选择「重试恢复窗口…」。 |

欢迎提交问题或功能建议。报告问题时，请附上 Panelet 版本或构建所用的 Git 提交、macOS 版本、显示器配置、复现步骤，以及预期和实际结果。也可以在「设置… → 诊断」点击「预览诊断报告…」并导出报告作为附件。[GitHub Issues](https://github.com/rankangkang/panelet/issues)

## 参与贡献

Panelet 使用 Swift 和 AppKit。欢迎通过 Pull Request 修复问题、改进文档或补充翻译。请说明改动解决的问题和验证方式。

```sh
./tests/run.sh
./build.sh
```

`./tests/run.sh` 运行逻辑测试和本地化检查。`./build.sh` 生成构建产物。也可打开 `Panelet.xcodeproj`，选择 Panelet scheme 进行编译。工程保持 App Sandbox 关闭，以便创建虚拟显示器。需要验证界面或权限时，通过 `./build.sh --install` 更新，再从「应用程序」打开 Panelet。

<details>
<summary>显示器检查与真机验收</summary>

以下命令列出当前显示器的方向、缩放、刷新率和位置。

```sh
/Applications/Panelet.app/Contents/MacOS/Panelet --list
```

修改分屏或恢复逻辑时，建议在真机验证上下和左右布局、退出任一窗口的全屏、在已有桌面上开始并结束快捷组合，以及多屏分屏时单独恢复一块屏。涉及恢复失败的检查请使用测试窗口。

- [分屏、恢复与诊断验收](tests/acceptance-2026-11-14.md)
- [首次使用导引验收](tests/onboarding-acceptance-2026-11-14.md)
- [双竖屏与快捷组合验收](tests/acceptance-2026-11-13.md)

</details>

## 许可证

本项目采用 GNU Affero General Public License v3.0，仅限第 3 版（`AGPL-3.0-only`）。[许可证正文](LICENSE)

虚拟显示器实现参考 Telas。[Telas](https://github.com/eduardoworrel/telas) · [第三方许可与版权声明](THIRD_PARTY_NOTICES) · [Panelet 品牌素材](branding/panelet/README.md)
