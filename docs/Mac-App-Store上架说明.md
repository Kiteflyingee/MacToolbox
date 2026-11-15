# MacToolbox 的 Mac App Store 上架路径

当前开源发行版通过 GitHub Releases 提供双架构 DMG 直接安装，并非 Mac App Store 商店上传格式。

## 当前版本的主要阻碍

Mac App Store 要求开启 App Sandbox。当前构建脚本未开启 App Sandbox；Finder 文件剪切通过辅助功能读取选区并拦截 Finder 按键，跨应用划词也使用 `AXUIElement` API。Apple 将辅助应用跨进程使用 Accessibility API 列为沙箱不兼容行为，因此现有实现需要裁剪或替换为支持沙箱的方案，不能仅勾选沙箱直接提交。[Apple 沙箱说明](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)、[审核指南 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)

较可行的路径是单独维护商店构建：保留截图、标注、本地 OCR、用户主动复制或输入文字后的翻译等兼容能力，并逐项验证剪贴板、文件导出、全局热键与开机自启动。完整功能版继续以 DMG 直接分发。

## 上架步骤概览

1. 建立适用于商店分发的 macOS App target 或归档流程，配置独立的 Bundle ID、版本号、图标、分类、最低系统版本、App Sandbox 及所需 entitlements。
2. 在开发者账号下配置 Mac App Store 分发签名和 provisioning profile。[分发 profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)
3. 在 App Store Connect 创建 macOS App 记录，填写名称、语言、Bundle ID 和 SKU。[创建 App](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
4. 使用 Xcode Archive 或 Apple Transporter 上传构建，并通过 TestFlight 验证安装、首次权限与后台运行。[上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
5. 准备应用截图、功能说明、支持网址、隐私政策与 App Privacy 数据流披露，并提交审核。[提交审核](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)
