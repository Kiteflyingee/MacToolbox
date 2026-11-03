#!/bin/sh
# Upload only the selected distribution image; credentials stay in Keychain.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
task_image="${1:?Usage: sh tools/notarize_dmg.sh /path/to/MacToolbox.dmg [keychain-profile]}"
task_profile="${2:-MacToolbox-notary}"
test -f "$task_image"
case "$task_image" in *.dmg) ;; *) printf '只接受 DMG 文件。\n' >&2; exit 1;; esac
codesign --verify --strict "$task_image"
hdiutil verify "$task_image"
mkdir -p "$task_root/build/notarization"
task_result="$task_root/build/notarization/$(basename "$task_image").json"
printf '向 Apple 公证服务提交：%s\n钥匙串 profile：%s\n' "$task_image" "$task_profile"
if ! xcrun notarytool submit "$task_image" --keychain-profile "$task_profile" \
    --wait --timeout 10m --output-format json > "$task_result"; then
  printf '公证尚未完成，结果保存在：%s；未标记为可分发。\n' "$task_result" >&2
  exit 1
fi
task_status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", "Unknown"))' "$task_result")
task_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$task_result")
if [ "$task_status" != Accepted ]; then
  if [ -n "$task_id" ]; then
    xcrun notarytool log "$task_id" --keychain-profile "$task_profile" "$task_result.log.json" || true
  fi
  printf 'Apple 公证未通过：%s；请检查 %s。\n' "$task_status" "$task_result" >&2
  exit 1
fi
xcrun stapler staple "$task_image"
xcrun stapler validate "$task_image"
codesign --verify --strict "$task_image"
spctl --assess --type open --context context:primary-signature --verbose=4 "$task_image"
hdiutil verify "$task_image"
(cd "$(dirname "$task_image")" && shasum -a 256 "$(basename "$task_image")") > "$task_image.sha256"
printf 'Apple 公证、票据装订及 Gatekeeper 检查通过：%s\n' "$task_image"
