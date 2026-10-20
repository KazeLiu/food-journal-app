# App 图标（透明底）

- 文件：[app-icon-transparent-v2.png](app-icon-transparent-v2.png)，带 Alpha 通道的 PNG。
- 方向：已确认的 B，白瓷餐盘 + 珊瑚橘相机取景框，简化的煎蛋、绿叶与三文鱼；盘外和取景框间隙透明。
- 生成方式：内置 `image_gen`，对已选定的简化图案移除背景。
- 状态：已接入 Android 启动图标资源并构建 0.1.17 APK，未自动安装，手机实际显示由用户安装后验收；构建和设备范围见[实现状态](../10-implementation-status.md)。

## Android 资源

保留 Manifest 的 `@drawable/journal_icon` 入口。Android 7 使用对应密度的 `mipmap-*/ic_launcher.png`，尺寸为 48 / 72 / 96 / 144 / 192px；Android 8 及以上由 `drawable-anydpi-v26/journal_icon.xml` 使用自适应图标。

自适应图层使用透明的 432px（xxxhdpi 下为 108dp）画布，原稿居中导出为 224px（56dp），为四角取景框预留裁切空间；背景层同样透明，不添加黑色底板。实现依据见 [Android 自适应图标规范](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)。

在项目根目录通过 Windows PowerShell 重新导出这些 PNG：

```powershell
& .\app\tool\export_launcher_icon.ps1
```

脚本仅使用系统自带的 `System.Drawing` 缩放和补齐画布，不安装依赖，不构建或启动 App。

已查看 [静态裁切与尺寸预览](app-icon-launcher-preview.png)，包含圆形、圆角方形和 48px 旧版资源；该图为资源预览，不是设备截图。

## 最终编辑提示词

```text
Edit this exact approved app icon by removing ONLY its graphite / charcoal background. Produce a genuine RGBA PNG with a fully transparent background, including the entire outside canvas, the gaps between the plate and the four coral viewfinder brackets, and the space inside the four separated brackets outside the plate. Do not put the icon on a black, white, gray, colored, or checkerboard background. The background must be actual alpha transparency, not a painted checkerboard.

Preserve the original icon artwork faithfully: the white porcelain plate, the simplified smooth fried egg and golden yolk, exactly two green leaves, the simplified coral-orange salmon wedge, and the four separate rounded coral camera-viewfinder corner brackets. Keep their original positions, scale, colors, materials, shape, top-down perspective, and understated dimensional highlights. Do not redesign or add anything. Keep plate interior shading and the food contact shadows, but remove the charcoal backdrop and any broad black drop shadow or dark halo outside the plate or brackets. Edges must be clean and antialiased, with no black fringe when placed on a white or light background. Preserve the original square composition and crop-safe spacing. No text, no added outline, no phone, no new objects. This is background extraction, not a new illustration.
```
