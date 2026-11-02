# 应用图标

`AppIcon.png` 来源于用户在 2026-10-31 提供的蓝青色玻璃卡片图案。使用内置 ImageGen 编辑，保留图案并移除外围白色背景。原图不进入应用包；最终透明 PNG 随项目保存。

最终修订提示词：

> Precise background-extraction correction for this app icon. Keep all interior artwork, shapes and colors unchanged. The supplied cutout has unwanted blue/cyan speckles and fuzzy fragments OUTSIDE the large outer rounded-square silhouette. Remove every such exterior speckle, halo, detached fleck and exterior shadow. Deliver one immaculate rounded-square icon silhouette with smooth clean antialiased edges, opaque interior pixels, genuine 0-alpha background everywhere outside, no jagged fringe. No new details, no redesign. Preserve composition and margin. Mac application icon production asset.

`tools/build_icon.sh` 使用系统 sips 和 iconutil 打包16–1024像素的10个规格，`tools/build_app.sh` 将 ICNS 放入应用资源并写入 `CFBundleIconFile`。128像素图已人工查看；透明四角已检查。菜单栏继续使用单色系统符号，彩色图标用于应用本身。
