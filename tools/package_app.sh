#!/bin/sh
# Builds a system-domain Installer package for /Applications/MacToolbox.app.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
if [ -f "$task_root/tools/signing.local.env" ]; then . "$task_root/tools/signing.local.env"; fi
if [ "${MACTOOLBOX_ADHOC_SIGN:-0}" = 1 ]; then
  printf '安装包必须使用固定证书签名，不能使用临时签名。\n' >&2
  exit 1
fi
if [ "${MACTOOLBOX_REQUIRE_DEVELOPER_ID:-0}" = 1 ] && [ -z "${MACTOOLBOX_INSTALLER_IDENTITY:-}" ]; then
  printf '正式 PKG 缺少 Developer ID Installer 证书；已停止。\n' >&2
  exit 1
fi
app="${MACTOOLBOX_APP_OUTPUT:-/private/tmp/MacToolbox-release-$(id -u)/MacToolbox.app}"
MACTOOLBOX_APP_OUTPUT="$app" MACTOOLBOX_ARCHITECTURES=universal MACTOOLBOX_BUILD_CONFIGURATION=release \
  sh tools/build_app.sh "$@"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
task_package=$(mktemp -d /private/tmp/MacToolbox-package-XXXXXX)
trap 'rm -r "$task_package"' EXIT
mkdir -p "$task_package/payload/Applications" "$task_package/resources"
ditto --norsrc --noextattr --noacl "$app" "$task_package/payload/Applications/MacToolbox.app"
codesign --verify --strict "$task_package/payload/Applications/MacToolbox.app"
cat > "$task_package/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
<key>RootRelativeBundlePath</key><string>Applications/MacToolbox.app</string>
<key>BundleIsRelocatable</key><false/>
<key>BundleIsVersionChecked</key><true/>
<key>BundleHasStrictIdentifier</key><true/>
<key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST
pkgbuild --root "$task_package/payload" --component-plist "$task_package/components.plist" \
  --identifier local.devkite.MacToolbox.installer --version "$version" --install-location / \
  "$task_package/MacToolbox-component.pkg"
cat > "$task_package/resources/welcome.html" <<'HTML'
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><body style="font:14px -apple-system;padding:12px">
<h2>安装或更新 MacToolbox</h2><p>适用于 macOS 14 及以上，包含苹果芯片和 Intel 两种版本。</p>
<p>应用安装到 <b>/Applications/MacToolbox.app</b>，可在“应用程序”中打开。原有偏好、剪贴板历史和 API 配置保留在各用户自己的目录。</p>
<p>请先退出 MacToolbox，再继续安装。首次使用需由本人授予辅助功能和屏幕采集权限。</p>
<p>安装包不能自动授予系统权限；签名、公证与授权迁移状态请以本次版本说明为准。</p>
<p>© 富途网络科技（盐城）有限公司 · 官网：<a href="https://www.fortumap.com">www.fortumap.com</a></p>
</body></html>
HTML
cat > "$task_package/resources/conclusion.html" <<'HTML'
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><body style="font:14px -apple-system;padding:12px">
<h2>安装完成</h2><p>在“应用程序”中打开 <b>MacToolbox.app</b>，或在 Finder 按 ⌘⇧G 输入 <b>/Applications/MacToolbox.app</b>。</p>
<p>使用顶部菜单栏的叠卡星光图标进入截图、剪贴板记录和偏好设置。</p>
<p>更新沿用同一应用身份；若系统仍要求确认，请只为 MacToolbox 开启对应权限。无需重新填写 API Key。</p>
</body></html>
HTML
cat > "$task_package/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>MacToolbox $version</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_anywhere="false" enable_localSystem="true" enable_currentUserHome="false"/>
  <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" visible="false"><pkg-ref id="local.devkite.MacToolbox.installer"/></choice>
  <pkg-ref id="local.devkite.MacToolbox.installer"><must-close><app id="local.devkite.MacToolbox"/></must-close></pkg-ref>
  <pkg-ref id="local.devkite.MacToolbox.installer" version="$version" onConclusion="None">
    MacToolbox-component.pkg
  </pkg-ref>
</installer-gui-script>
XML
if [ -n "${MACTOOLBOX_INSTALLER_IDENTITY:-}" ]; then
  # A separate Installer identity is required; Application certificates cannot sign PKGs.
  productbuild --distribution "$task_package/Distribution.xml" --package-path "$task_package" \
    --resources "$task_package/resources" --sign "$MACTOOLBOX_INSTALLER_IDENTITY" --timestamp \
    "$task_root/build/MacToolbox-$version-universal.pkg"
  pkgutil --check-signature "$task_root/build/MacToolbox-$version-universal.pkg"
else
  productbuild --distribution "$task_package/Distribution.xml" --package-path "$task_package" \
    --resources "$task_package/resources" "$task_root/build/MacToolbox-$version-universal.pkg"
fi
shasum -a 256 "$task_root/build/MacToolbox-$version-universal.pkg" > "$task_root/build/MacToolbox-$version-universal.pkg.sha256"
printf 'Installer: %s\n' "$task_root/build/MacToolbox-$version-universal.pkg"
