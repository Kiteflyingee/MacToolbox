# 应用图标与矢量资源

- `AppIcon.png`：1024×1024 透明背景主图标资源。`tools/build_icon.sh` 使用系统 `sips` 与 `iconutil` 打包 16–1024 像素的 10 个规格，`tools/build_app.sh` 将生成的 `AppIcon.icns` 放入应用资源并写入 `CFBundleIconFile`。
- `CaptureGlyphs.json`：截图工具栏矢量路径资源，第三方图标许可详见 `Licenses/NOTICE.txt`。
