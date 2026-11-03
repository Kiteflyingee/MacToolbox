# MacToolbox 的 Mac App Store 上架路径

截至 2026-11-03，0.2.16 是 Developer ID 签名、公证后通过 GitHub 分发的版本。Apple 公证不是 App Store 审核，通过公证的 DMG 也不是商店上传格式。

## 当前版本的主要阻碍

Mac App Store 要求开启 App Sandbox。当前构建脚本没有开启 App Sandbox；Finder 文件剪切通过辅助功能读取选区并拦截 Finder 按键，跨应用划词也使用 `AXUIElement` API。Apple 明确把辅助应用使用 Accessibility API 列为沙箱不兼容行为，因此这些现有实现需要移除或找到支持沙箱的替代方案，不能只勾选沙箱就提交。[Apple 沙箱说明](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)、[审核指南 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)

较实际的起点是另做商店构建：先验证截图、标注、本地 OCR、用户主动复制或输入文字后的翻译；分别验证剪贴板、文件访问、全局热键和开机启动。完整版本继续按已公证的 DMG 分发。该建议是基于当前代码的实现评估，尚未完成沙箱原型或获得 App Review 批准。

## 上架步骤

1. 在 Xcode 建立适用于商店分发的 macOS App target 或等效归档流程，配置明确的 Bundle ID、版本号、图标、分类、最低系统版本、App Sandbox 和所需 entitlements。为文件导出、网络请求等使用相应的沙箱能力，并验证数据容器和升级迁移。
2. 在公司团队下配置 Mac App Store 分发签名和 provisioning profile；可使用 Xcode 自动管理签名。当前 Developer ID 发行签名用途不同，需要单独的商店构建配置。[分发 profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)
3. 由有权限的成员在 App Store Connect 创建 macOS App 记录，填写名称、语言、Bundle ID 和 SKU。[创建 App](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
4. 在 Xcode Archive 后选择 Distribute App → App Store Connect 上传；也可使用 Apple Transporter 上传符合要求的构建。通过 TestFlight 验证实际安装、首次权限、后台运行和数据升级。[上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
5. 准备截图、介绍、支持网址、隐私政策、App Privacy、年龄分级、价格与地区，以及系统要求的合规信息。隐私说明应覆盖截图、剪贴板、选中文字及翻译请求的实际数据流；提供能让审核人员测试翻译功能的清晰说明。
6. 选择处理完成的构建，添加到审核并提交。通过后按所选方式发布；商店版本的更新也经 App Store 分发。[提交审核](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)

## Developer 角色能做什么

- Developer 可以上传构建；必须有该 App 和对应开发资源的访问权限。
- 创建 App 记录和最终提交 App Review，需要 Account Holder、Admin 或 App Manager。
- 接受公司最新协议等步骤仍可能需要 Account Holder 本人完成。

因此你可以负责开发、沙箱验证和上传，再请 Admin 或 App Manager 创建记录和提交审核，无需为了普通上传而共享账户持有人的密码。
