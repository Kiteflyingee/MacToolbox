#!/bin/sh
# Wrap an existing, verified installer without rebuilding or re-signing the app.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
package="${1:?Usage: sh tools/package_dmg.sh /path/to/MacToolbox-VERSION-universal.pkg}"
test -f "$package"
package_name=$(basename "$package")
version=$(printf '%s' "$package_name" | sed -n 's/^MacToolbox-\([0-9][0-9.]*\)-universal\.pkg$/\1/p')
test -n "$version"
task_image=$(mktemp -d /private/tmp/MacToolbox-dmg-XXXXXX)
trap 'rm -r "$task_image"' EXIT
mkdir -p "$task_image/contents"
cp "$package" "$task_image/contents/安装或更新 MacToolbox.pkg"
cat > "$task_image/contents/安装说明.txt" <<TEXT
MacToolbox $version
© 富途网络科技（盐城）有限公司
官网：www.fortumap.com

1. 先退出正在运行的 MacToolbox。
2. 双击“安装或更新 MacToolbox.pkg”，按安装器提示完成安装。
3. 在“应用程序”中打开 MacToolbox.app，或在 Finder 按 ⌘⇧G 输入 /Applications/MacToolbox.app。
4. 使用顶部菜单栏的叠卡星光图标进入截图、剪贴板记录和偏好设置。

应用统一安装到 /Applications。原有偏好、剪贴板历史与 API 配置保留在各用户自己的目录。
最低 macOS 14，包含苹果芯片 arm64 与 Intel x86_64 两种架构。

DMG 不会自动授予或改变系统权限。首次安装或签名身份迁移时，请按系统提示确认。
安装器签名可通过系统安装器或 pkgutil --check-signature 检查；Apple 公证状态请参阅本次发行说明。
TEXT
output="$task_root/build/MacToolbox-$version-universal.dmg"
hdiutil create -srcfolder "$task_image/contents" -volname "MacToolbox $version" \
  -fs HFS+ -format UDZO -ov "$output"
hdiutil verify "$output"
shasum -a 256 "$output" > "$output.sha256"
printf 'Disk image: %s\n' "$output"
