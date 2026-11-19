# 分屏输入路由实测

2026-11-17 在 macOS 26.6.2 上验证。PixPin 版本为 3.6.6.0。

- **交互镜像的限制。** AppKit 测试窗口收到了点击、键盘输入和控件内拖动。真实应用对照中，镜像转发了 TextEdit 菜单的悬停，但子菜单未展开。Finder 文件拖入镜像时，原型只收到了开始拖入的通知。两项操作在真实虚拟屏窗口上均成功。这组结果支持保留真实光标和原生输入会话。[真实应用对照](data/projection-real-app-2026-11-17.json)
- **PixPin 首拖。** 选区窗口可见时，物理屏上的输入命中可能仍指向桌面。历史几何识别组的完整首拖通过 4/8，有界等待 60 ms 的常规组通过 6/6，极早组通过 1/3。历史安装版用 100 ms 等待预算，15/15 次首按命中物理选区，完整拖动终点通过 14/15。探针在松手前用 Esc 结束选区，结果覆盖首按和拖动投递。[逐次记录](data/pixpin-first-press-2026-11-17.json)

## 复现

从仓库根目录执行。保持 `/Applications/Panelet.app` 的分屏开启，在解锁且空闲的桌面上使用临时测试文稿。两个探针都需要发送测试输入的权限。镜像还需要屏幕录制权限，PixPin 探针需要观察鼠标事件的权限。

### 交互镜像

```sh
research=tests/capture-routing-research
probe_dir=$(mktemp -d /tmp/panelet-routing.XXXXXXXX)
clang -fobjc-arc -O2 -Wno-deprecated-declarations \
  -framework Cocoa -framework ApplicationServices \
  "$research/ProjectionProbe.m" -o "$probe_dir/projection"
python3 "$research/run-projection.py" "$probe_dir/projection"
```

默认运行会创建两个夹具窗口，验证点击、键盘、控件拖动和物理浮层首击，并在临时目录写出事件日志。

真实应用复测时，在虚拟半屏内放一扇标题唯一的 TextEdit 临时纯文本文稿，将下方标题换成窗口显示的准确文字。

```sh
python3 "$research/run-projection.py" "$probe_dir/projection" \
  --textedit-window 'Panelet Routing Repro'
```

分别在镜像和真实窗口上右击并悬停「字体」，比较子菜单是否展开。再从 Finder 将同一个临时文件拖到两处，比较文稿内容。在终端按 Ctrl+C 结束镜像。

### PixPin 首拖

使用上下分屏，将 PixPin 的捕捉快捷键设为 Ctrl+1，运行前关闭已有选区。先列出显示器 ID，再把下方变量设为同一组分屏的物理屏、上半屏和下半屏 ID。

```sh
clang -fobjc-arc -O2 -framework Cocoa -framework ApplicationServices \
  "$research/PixPinPressProbe.m" -o "$probe_dir/pixpin-first-press"
"$probe_dir/pixpin-first-press" --displays
"$probe_dir/pixpin-first-press" "$physical_id" "$upper_id" "$lower_id"
```

探针只跑一次跨接缝的快速起拖，输出可见到按下的间隔、按下前物理点是否已可命中，以及实际投递和拖动结果。最后按 Esc 取消并恢复鼠标位置。历史数据来自多轮探针，`first_delivery_ms` 还包含发送输入与采样回调的时间。路由状态的独立回归用例见 [CaptureRoutingTests.swift](../CaptureRoutingTests.swift)。

数据里的 `source` 和 `source_key` 对应本机原始归档 `2026-11-17-originals.zip` 内的文件和记录分组。
