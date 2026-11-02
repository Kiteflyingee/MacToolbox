# MacToolbox

MacToolbox 是一个面向 macOS 的菜单栏工具项目，整合 Finder 文件剪切、剪贴板历史、截图标注和翻译功能。项目仍在开发中，部分功能和平台兼容性尚未完成验收。

## 运行环境

- macOS 14 或更新版本
- Swift 6 和 Xcode 命令行开发工具
- 截图需要屏幕录制权限；Finder 快捷键和划词翻译需要辅助功能权限
- 翻译需要自行配置兼容的 API 地址、模型和密钥

## 构建与测试

```sh
swift build
sh tools/test_core.sh
```

打包本机预览应用：

```sh
MACTOOLBOX_ADHOC_SIGN=1 sh tools/build_app.sh
```

应用打包在 `build/MacToolbox.zip`。临时签名构建不等同于经过 Apple Developer ID 签名和公证的发行版；不同机器及系统版本的权限行为需要自行验证。完整测试需要正常登录的 macOS 桌面会话。

## 当前状态

截图提供框选、标注、取色、复制、保存和 OCR 翻译等功能；多屏编辑等功能仍在开发。剪贴板历史存储在本机，翻译请求会发送到用户配置的服务。请在启用权限和填写 API 配置前了解相应服务的隐私政策。

第三方图标许可和来源见 [Resources/Licenses/NOTICE.txt](Resources/Licenses/NOTICE.txt)。
