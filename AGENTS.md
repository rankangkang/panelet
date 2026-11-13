# Panelet 本机安装约定

- 日常运行、UI 验收、授权引导和交付链接统一指向 `/Applications/Panelet.app`。
- `build/Panelet.app` 仅作构建产物，不并行启动或引导用户为它重复授权。
- 更新前正常退出现有 App；有分屏时通过应用自身恢复流程退出，不强杀。
- 沿用已安装版本的签名身份及 Bundle Identifier `dev.cmkk.panelet`；安装前验证新包满足旧包 designated requirement。使用 `./build.sh --install` 执行后续更新。
- 不重置 TCC 或更换签名来处理常规更新。
