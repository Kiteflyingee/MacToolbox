#!/bin/sh
# Package an existing Developer ID-signed universal app for drag installation.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
if [ -f "$task_root/tools/signing.local.env" ]; then . "$task_root/tools/signing.local.env"; fi
app="${1:-${MACTOOLBOX_APP_OUTPUT:-/private/tmp/MacToolbox-release-$(id -u)/MacToolbox.app}}"
if [ ! -d "$app/Contents" ]; then
  printf '请传入 MacToolbox.app；DMG 已改为拖拽安装，不再包装 PKG。\n' >&2
  exit 1
fi
task_identity="${MACTOOLBOX_SIGNING_IDENTITY:-}"
task_team="${MACTOOLBOX_TEAM_ID:-}"
if [ -z "$task_identity" ] || [ -z "$task_team" ]; then
  printf 'DMG 分发需要 Developer ID Application 签名身份和团队 ID。\n' >&2
  exit 1
fi
task_requirement="identifier \"local.devkite.MacToolbox\" and anchor apple generic and certificate leaf[subject.OU] = \"$task_team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
codesign --verify --strict -R "=$task_requirement" "$app"
lipo "$app/Contents/MacOS/MacToolboxApp" -verify_arch arm64 x86_64
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
case "$version" in ''|*[!0-9.]*) printf '无效的应用版本号。\n' >&2; exit 1;; esac
task_image=$(mktemp -d /private/tmp/MacToolbox-dmg-XXXXXX)
trap 'rm -r "$task_image"' EXIT
mkdir -p "$task_image/contents"
ditto --norsrc --noextattr --noacl "$app" "$task_image/contents/MacToolbox.app"
codesign --verify --strict -R "=$task_requirement" "$task_image/contents/MacToolbox.app"
ln -s /Applications "$task_image/contents/Applications"
cat > "$task_image/contents/安装说明.txt" <<TEXT
MacToolbox $version
© 富途网络科技（盐城）有限公司
官网：www.fortumap.com

1. 先退出正在运行的 MacToolbox。
2. 把 MacToolbox.app 拖到旁边的 Applications 文件夹；更新时选择替换旧版。
3. 推出此磁盘映像，在“应用程序”中打开 MacToolbox.app。
4. 使用顶部菜单栏的叠卡星光图标进入截图、剪贴板记录和偏好设置。

Applications 入口指向系统 /Applications 文件夹。原有偏好、剪贴板历史与 API 配置保留在各用户自己的目录。
最低 macOS 14，包含苹果芯片 arm64 与 Intel x86_64 两种架构。

首次使用请按提示允许辅助功能和屏幕采集。
TEXT
mkdir -p "$task_root/build"
output="${MACTOOLBOX_DMG_OUTPUT:-$task_root/build/MacToolbox-$version-universal.dmg}"
hdiutil create -srcfolder "$task_image/contents" -volname "MacToolbox $version" \
  -fs HFS+ -format UDZO -ov "$output"
hdiutil verify "$output"
codesign --force --sign "$task_identity" --timestamp --identifier local.devkite.MacToolbox.dmg "$output"
codesign --verify --strict "$output"
(cd "$(dirname "$output")" && shasum -a 256 "$(basename "$output")") > "$output.sha256"
printf 'Disk image: %s\n' "$output"
printf '已签名，尚未完成公证；请运行 tools/notarize_dmg.sh 后再对外分发。\n'
