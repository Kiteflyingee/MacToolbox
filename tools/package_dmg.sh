#!/bin/sh
# Package a universal app bundle for drag installation.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
if [ -f "$task_root/tools/signing.local.env" ]; then . "$task_root/tools/signing.local.env"; fi
app="${1:-${MACTOOLBOX_APP_OUTPUT:-/private/tmp/MacToolbox-release-$(id -u)/MacToolbox.app}}"
if [ ! -d "$app/Contents" ]; then
  printf '请传入 MacToolbox.app；DMG 使用拖拽安装形式。\n' >&2
  exit 1
fi
task_identity="${MACTOOLBOX_SIGNING_IDENTITY:-}"
task_team="${MACTOOLBOX_TEAM_ID:-}"
if [ -n "$task_identity" ]; then
  if [ -z "$task_team" ]; then
    printf '使用 Developer ID 签名时需同时提供 MACTOOLBOX_TEAM_ID。\n' >&2
    exit 1
  fi
  task_requirement="identifier \"local.mactoolbox.MacToolbox\" and anchor apple generic and certificate leaf[subject.OU] = \"$task_team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  codesign --verify --strict -R "=$task_requirement" "$app"
elif [ "${MACTOOLBOX_REQUIRE_DEVELOPER_ID:-0}" = 1 ]; then
  printf '缺少 Developer ID Application 签名配置；已停止。\n' >&2
  exit 1
else
  codesign --verify --strict "$app"
fi
lipo "$app/Contents/MacOS/MacToolboxApp" -verify_arch arm64 x86_64
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
case "$version" in ''|*[!0-9.]*) printf '无效的应用版本号。\n' >&2; exit 1;; esac
task_image=$(mktemp -d /private/tmp/MacToolbox-dmg-XXXXXX)
trap 'rm -r "$task_image"' EXIT
mkdir -p "$task_image/contents"
ditto --norsrc --noextattr --noacl "$app" "$task_image/contents/MacToolbox.app"
if [ -n "$task_identity" ]; then
  codesign --verify --strict -R "=$task_requirement" "$task_image/contents/MacToolbox.app"
else
  codesign --verify --strict "$task_image/contents/MacToolbox.app"
fi
ln -s /Applications "$task_image/contents/Applications"
cat > "$task_image/contents/安装说明.txt" <<TEXT
MacToolbox $version (MIT License)

1. 先退出正在运行的 MacToolbox。
2. 把 MacToolbox.app 拖到旁边的 Applications 文件夹；更新时选择替换旧版。
3. 推出此磁盘映像，在“应用程序”中打开 MacToolbox.app。
   · 若首次打开提示“无法验证开发者”，请在“应用程序”中右键（或按住 Control 点击）MacToolbox.app 选择“打开”，或在“系统设置 → 隐私与安全性”底部点击“仍要打开”。
4. 使用顶部菜单栏的叠卡星光图标进入截图、剪贴板记录和偏好设置。

Applications 入口指向系统 /Applications 文件夹。原有偏好、剪贴板历史与 API 配置保留在各用户自己的目录。
最低支持 macOS 14，包含苹果芯片 arm64 与 Intel x86_64 两种架构。

首次使用相关功能时，请按提示允许辅助功能和屏幕采集。
TEXT
mkdir -p "$task_root/build"
output="${MACTOOLBOX_DMG_OUTPUT:-$task_root/build/MacToolbox-$version-universal.dmg}"
hdiutil create -srcfolder "$task_image/contents" -volname "MacToolbox $version" \
  -fs HFS+ -format UDZO -ov "$output"
hdiutil verify "$output"
if [ -n "$task_identity" ]; then
  codesign --force --sign "$task_identity" --timestamp --identifier local.mactoolbox.MacToolbox.dmg "$output"
else
  codesign --force --sign - --identifier local.mactoolbox.MacToolbox.dmg "$output"
fi
codesign --verify --strict "$output"
(cd "$(dirname "$output")" && shasum -a 256 "$(basename "$output")") > "$output.sha256"
printf 'Disk image: %s\n' "$output"
