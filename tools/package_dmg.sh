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

1. 先退出正在运行的 MacToolbox。
2. 双击“安装或更新 MacToolbox.pkg”，按安装器提示完成安装。
3. 在 Finder 按 ⌘⇧G，输入 ~/Applications/MacToolbox.app 打开应用。
4. 使用顶部菜单栏的叠卡星光图标进入截图、剪贴板记录和偏好设置。

安装器沿用现有的当前用户应用目录，保留偏好、剪贴板历史与 API 配置。
最低 macOS 14，包含苹果芯片 arm64 与 Intel x86_64 两种架构。

这是本地开发测试版，尚未经过 Apple Developer ID 分发签名及公证。
DMG 不会自动授予或改变系统权限；当前版本 API Key 的跨更新钥匙串授权问题仍待解决。
TEXT
output="$task_root/build/MacToolbox-$version-universal.dmg"
hdiutil create -srcfolder "$task_image/contents" -volname "MacToolbox $version" \
  -fs HFS+ -format UDZO -ov "$output"
hdiutil verify "$output"
shasum -a 256 "$output" > "$output.sha256"
printf 'Disk image: %s\n' "$output"
