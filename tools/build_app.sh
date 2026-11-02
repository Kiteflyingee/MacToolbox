#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
if [ -f "$task_root/tools/signing.local.env" ]; then . "$task_root/tools/signing.local.env"; fi
task_identity="${MACTOOLBOX_SIGNING_IDENTITY:-}"
task_team="${MACTOOLBOX_TEAM_ID:-}"
if [ -n "$task_identity" ]; then
  case "$task_identity" in *[!a-fA-F0-9]*) printf 'Signing identity must be a certificate SHA1.\n' >&2; exit 1;; esac
  test "${#task_identity}" = 40
  case "$task_team" in ''|*[!A-Z0-9]*) printf 'A valid Apple Team ID is required.\n' >&2; exit 1;; esac
  test "${#task_team}" = 10
  if [ "${MACTOOLBOX_ADHOC_SIGN:-0}" = 1 ]; then
    printf '正式证书与临时签名选项不能同时使用。\n' >&2; exit 1
  fi
elif [ "${MACTOOLBOX_REQUIRE_DEVELOPER_ID:-0}" = 1 ]; then
  printf '正式构建缺少 Developer ID Application 证书；已停止，不会退回本地签名。\n' >&2
  exit 1
fi
mkdir -p build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$task_root/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/build/ModuleCache"
configuration="${MACTOOLBOX_BUILD_CONFIGURATION:-debug}"
architectures="${MACTOOLBOX_ARCHITECTURES:-native}"
case "$configuration" in debug|release) ;; *) printf 'Unsupported configuration\n' >&2; exit 1;; esac
build_binary() {
  swift build --product MacToolboxApp --configuration "$configuration" --scratch-path "$task_scratch" \
    --cache-path build/PackageCache --config-path build/PackageConfig --security-path build/PackageSecurity --disable-sandbox "$@"
  task_bin=$(swift build --configuration "$configuration" --scratch-path "$task_scratch" \
    --cache-path build/PackageCache --config-path build/PackageConfig --security-path build/PackageSecurity --disable-sandbox --show-bin-path "$@")
}
case "$architectures" in
  native)
    task_scratch=build/SwiftPM
    build_binary "$@"
    task_executable="$task_bin/MacToolboxApp"
    ;;
  universal)
    task_scratch=build/SwiftPM-arm64
    build_binary --triple arm64-apple-macosx14.0 "$@"
    task_arm_binary="$task_bin/MacToolboxApp"
    task_scratch=build/SwiftPM-x86_64
    build_binary --triple x86_64-apple-macosx14.0 "$@"
    task_executable="$task_root/build/MacToolboxApp-universal"
    lipo -create "$task_arm_binary" "$task_bin/MacToolboxApp" -output "$task_executable"
    lipo "$task_executable" -verify_arch arm64 x86_64
    ;;
  *) printf 'Unsupported architectures (use native or universal)\n' >&2; exit 1;;
esac
# Keep the signed bundle outside iCloud/File Provider: FinderInfo added to synced
# Documents folders invalidates app signatures. The distributable zip stays in build/.
app="${MACTOOLBOX_APP_OUTPUT:-/private/tmp/MacToolbox-build-$(id -u)/MacToolbox.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$task_executable" "$app/Contents/MacOS/MacToolboxApp"
sh tools/build_icon.sh
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/CaptureGlyphs.json "$app/Contents/Resources/CaptureGlyphs.json"
cp -R Resources/Licenses "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacToolboxApp</string>
<key>CFBundleIdentifier</key><string>local.devkite.MacToolbox</string>
<key>CFBundleName</key><string>MacToolbox</string>
<key>CFBundleDisplayName</key><string>MacToolbox</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleShortVersionString</key><string>0.2.12</string>
<key>CFBundleVersion</key><string>23</string>
<key>NSHumanReadableCopyright</key><string>© 富途网络科技（盐城）有限公司</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
xattr -cr "$app"
if [ -n "$task_identity" ]; then
  codesign --force --sign "$task_identity" --options runtime --timestamp --identifier local.devkite.MacToolbox "$app"
  task_requirement="identifier \"local.devkite.MacToolbox\" and anchor apple generic and certificate leaf[subject.OU] = \"$task_team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  codesign --verify --strict -R "=$task_requirement" "$app"
elif [ "${MACTOOLBOX_ADHOC_SIGN:-0}" = 1 ]; then
  task_identity=-
  codesign --force --sign "$task_identity" --identifier local.devkite.MacToolbox "$app"
else
  swiftc -module-cache-path build/ModuleCache tools/local_signing_identity.swift -o build/local_signing_identity
  task_identity=$(build/local_signing_identity)
  codesign --force --sign "$task_identity" --identifier local.devkite.MacToolbox "$app"
fi
codesign --verify --strict "$app"
task_zip="${MACTOOLBOX_ZIP_OUTPUT:-$task_root/build/MacToolbox.zip}"
ditto -c -k --keepParent --norsrc --noextattr --noacl "$app" "$task_zip"
printf 'Built: %s\n' "$app"
