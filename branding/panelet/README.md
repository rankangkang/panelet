# Panelet · Interlock

用户已选定方向 02「Interlock」。本目录为选定方向的正式素材，替代先前的 Split P 推荐稿。

图形由两个互补形体组成一个整体，表达独立空间与分合关系，不限定上下或左右布局。

- 主色：石墨黑 `#171717`，白色 `#FFFFFF`。
- 主标：`logo.svg` / `.png`，透明底。
- 反白主标：`logo-white.svg` / `.png`。
- 默认 App 图标：`app-icon.svg` / `.png`，黑底白标。
- 浅色 App 图标：`app-icon-light.svg` / `.png`。
- macOS：`Panelet.icns`、`Panelet.iconset/`，16–1024px。
- 菜单栏：`menu-template.svg` / `.png` / `@2x.png`；18pt，已对齐小尺寸像素，使用 `NSImage.isTemplate = true`。
- 横向字标：`wordmark.svg` / `.png`。字标使用 Helvetica Neue，保留可编辑文本；图形及 App 图标不依赖字体。
- 预览：`preview.png`。
- 重建：`python3 branding/panelet/finalize.py`，需要 rsvg-convert 和 macOS iconutil。

最小建议尺寸：主标 18px；菜单栏使用专门的模板素材。不要拉伸、改变中央留白或单独旋转其中一个形体。主标周围建议保留至少主体高度 1/4 的净空。

已接入 Panelet 的应用图标和菜单栏模板。运行时资源位于 `Panelet/Resources/`，此处保留品牌源文件。
