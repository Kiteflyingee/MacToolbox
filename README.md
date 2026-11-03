# MacToolbox

MacToolbox 是一款 macOS 菜单栏工具，提供 Finder 文件剪切、剪贴板历史、截图标注及翻译。项目仍处于预览阶段。

## 下载与安装

从 [v0.2.15 Release](https://github.com/Kiteflyingee/MacToolbox/releases/tag/v0.2.15) 下载 DMG，打开后将 **MacToolbox.app 拖到 Applications**。更新时先退出旧版并选择替换，再从“应用程序”打开。支持 macOS 14 及以上，提供 Intel 和 Apple 芯片通用版本。Apple 芯片版本已交叉编译，尚未在 Apple 芯片 Mac 上实机验证。

**0.2.15 已通过 Apple 公证**，DMG 已装订票据。带下载隔离标记的 DMG 和从中复制出的 App 均通过本机 Gatekeeper，来源为 `Notarized Developer ID`。应用与 DMG 使用富途网络科技（盐城）有限公司的 Developer ID 签名。使用前需按功能授权辅助功能和屏幕采集权限。请使用本次新 DMG；旧的 PKG 形式发行包未公证。

Release 同时提供 `.sha256` 校验文件，可在下载目录运行：

```sh
shasum -a 256 -c MacToolbox-0.2.15-universal.dmg.sha256
```

## 功能

- Finder 中用 ⌘X 标记文件或文件夹，再用 ⌘V 移动。
- 在菜单栏查看最近 20 条剪贴板历史。
- 截图框选、标注、取色、保存或复制，以及 OCR 翻译。
- 划词或复制文字后翻译，支持配置兼容 Chat Completions 的 API、模型和 Key。WPS 中如划词无响应，可手动复制文字或使用截图翻译；应用不会为 WPS 自动复制选区。
- “偏好设置 → 通用”提供开机自启动开关和截图快捷键设置。截图快捷键点击录入、立即保存，支持清除、冲突提示和重启恢复；默认未绑定，组合键需包含 ⌘ 或 ⌃。

截图多屏编辑等能力仍未完成。翻译内容会发送到用户选择的服务；API Key 存入系统钥匙串，剪贴板历史存储在本机。请了解所选服务的隐私政策。

## 构建与测试

需要 Swift 6.2 或更新工具链（例如 Xcode 26）和 macOS 14 或以上：

```sh
swift build
sh tools/test_core.sh
MACTOOLBOX_ADHOC_SIGN=1 sh tools/build_app.sh
```

最后一条适用于没有本机正式签名配置的开发环境，生成 `build/MacToolbox.zip`；临时签名构建与发行版不同。完整原生测试需要正常登录的 macOS 桌面会话。正式签名可通过构建脚本的环境变量配置；不要将证书私钥、API Key 或本机签名配置提交到仓库。

公证及分发流程见 [分发与公证](docs/分发与公证.md)。当前是直接分发版本，Mac App Store 所需沙箱适配尚未完成；上架步骤与已知限制见 [Mac App Store 上架说明](docs/Mac-App-Store上架说明.md)。

第三方图标许可及来源见 [Resources/Licenses/NOTICE.txt](Resources/Licenses/NOTICE.txt)。

© 富途网络科技（盐城）有限公司 · [www.fortumap.com](https://www.fortumap.com)
