#!/bin/sh
set -eu
source_app="${MACTOOLBOX_APP_OUTPUT:-/private/tmp/MacToolbox-build-$(id -u)/MacToolbox.app}"
destination="${MACTOOLBOX_INSTALL_PATH:-/Applications/MacToolbox.app}"
installed_app="$destination"
if [ "$destination" = /Applications/MacToolbox.app ] && [ ! -e "$destination" ] && [ -e "$HOME/Applications/MacToolbox.app" ]; then
  installed_app="$HOME/Applications/MacToolbox.app"
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" = local.devkite.MacToolbox
codesign --verify --strict "$source_app"
if pgrep -x MacToolboxApp >/dev/null; then
  printf '请先退出正在运行的 MacToolbox，然后重新安装。\n' >&2
  exit 1
fi
if [ -e "$installed_app" ]; then
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")" = local.devkite.MacToolbox
  source_requirement=$(codesign -d -r- "$source_app" 2>&1 | sed -n 's/^designated => //p')
  installed_requirement=$(codesign -d -r- "$installed_app" 2>&1 | sed -n 's/^designated => //p')
  if [ -z "$source_requirement" ] || [ "$source_requirement" != "$installed_requirement" ]; then
    printf '签名身份发生变化，已停止更新以免造成重复授权。请检查签名证书。\n' >&2
    exit 1
  fi
fi
parent=$(dirname "$destination")
mkdir -p "$parent"
staging="$parent/.MacToolbox-update-$(uuidgen).app"
trap 'if [ -d "$staging" ]; then rm -r "$staging"; fi' EXIT
ditto --norsrc --noextattr --noacl "$source_app" "$staging"
codesign --verify --strict "$staging"
if [ -e "$installed_app" ]; then
  backup_root="${MACTOOLBOX_BACKUP_DIRECTORY:-$HOME/Library/Application Support/local.devkite.MacToolbox/Backups}"
  mkdir -p "$backup_root"
  backup="$backup_root/MacToolbox-$(date +%Y%m%d-%H%M%S)-$(uuidgen).app"
  mv "$installed_app" "$backup"
  printf '旧版备份：%s\n' "$backup"
fi
if ! mv "$staging" "$destination"; then
  if [ -n "${backup:-}" ]; then mv "$backup" "$installed_app"; fi
  exit 1
fi
printf 'Installed: %s\n' "$destination"
