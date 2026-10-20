# App 图标设计稿 v1

- 文件：[app-icon-graphite-coral-v1.png](app-icon-graphite-coral-v1.png)
- 方向：已确认的 B，白瓷餐盘 + 珊瑚橘相机取景框，石墨色背景，简化的煎蛋、绿叶与三文鱼。
- 生成方式：内置 `image_gen`，初版生成后进行一次风格简化编辑。
- 状态：用户已选定简化版，已接入 Android 启动图标资源，包含在当前0.1.16 APK中并已保留数据安装到MuMu；构建和设备范围见[实现状态](../10-implementation-status.md)。

## Android 资源

保留 Manifest 的 `@drawable/journal_icon` 入口。Android 7 使用对应密度的 `mipmap-*/ic_launcher.png`，尺寸为 48 / 72 / 96 / 144 / 192px；Android 8 及以上由 `drawable-anydpi-v26/journal_icon.xml` 使用自适应图标。

自适应图层使用 432px（xxxhdpi 下为 108dp）画布，原稿居中导出为 280px（70dp），四角取景框和餐盘位于内部，外围延续石墨背景，为系统裁切留出空间。实现依据见 [Android 自适应图标规范](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)。没有另行生成或改变已确认的图案。

在项目根目录通过 Windows PowerShell 重新导出这些 PNG：

```powershell
& .\app\tool\export_launcher_icon.ps1
```

脚本仅使用系统自带的 `System.Drawing` 缩放和补齐画布，不安装依赖，不构建或启动 App。

已查看 [静态裁切与尺寸预览](app-icon-launcher-preview.png)，包含圆形、圆角方形和 48px 旧版资源；该图为资源预览，不是设备截图。

## 最终编辑提示词

```text
Edit the supplied icon. Change its rendering language from realistic food photography to a beautifully simplified sculptural Apple-style app icon. Preserve the approved concept, centered top-down composition, white circular plate, graphite edge-to-edge background, four coral camera viewfinder corners, and the three food categories. Keep all elements centered and crop-safe.

The essential change is strong visual simplification and restrained shallow 3D: smooth, deliberately designed geometric silhouettes with almost no surface texture. This must look like a premium designed app symbol, NOT a food photograph. The egg becomes one smooth, broad ivory-white silhouette with a single golden dome yolk: no fried bubbles, brown crispy edges, oil, or pepper. Replace the realistic spinach bunch with exactly TWO broad, simple muted-green leaf shapes, just one gentle center fold on each: no stems, fine veins, speckles, or photographic detail. The salmon becomes one softly rounded coral-orange wedge with only two broad shallow diagonal grooves: no fish-muscle striations, grilled crust, seasoning, or wet shine. Keep the plate a clean shallow porcelain disc with a subtle rim, not a deep bowl. Use soft satin material, delicate controlled edge highlights and short subtle shadows. Crisp refined geometry, no outlines around food, no plastic toy gloss. Keep dimensionality understated and recognizable at 48px.

Keep the background neutral graphite, the four rounded viewfinder brackets soft coral, and the plate ivory. Calm, sophisticated, clean, friendly, modern health-app identity. Full square opaque icon artwork; no rounded outer tile baked in, no extra props, no text or symbols, no phone, no sparkles, no mockup or border canvas.
```
