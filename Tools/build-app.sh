#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
configuration=${1:-release}
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  print -u2 '用法：Tools/build-app.sh [debug|release]'
  exit 2
fi
signing_identity=${PAPERLIKE_SIGNING_IDENTITY:-}
if [[ -n "$signing_identity" && "$signing_identity" != 'Developer ID Application: '* ]]; then
  print -u2 'PAPERLIKE_SIGNING_IDENTITY 必须为 Developer ID Application 身份；不设置时使用 ad-hoc。'
  exit 2
fi
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
minimum_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$repo_root/Resources/Info.plist")
app_path="$repo_root/.build/PaperLike Native.app"
clang_cache="$repo_root/.build/clang-module-cache"
swiftpm_cache="$repo_root/.build/swiftpm-module-cache"
mkdir -p "$clang_cache" "$swiftpm_cache"
export CLANG_MODULE_CACHE_PATH="$clang_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$swiftpm_cache"

cd "$repo_root"
# CLT's swiftbuild needs explicit linker metadata to opt into the current native UI.
# Keep per-file optimization: Swift 6.2 whole-module builds report a circular reference.
swift build --disable-sandbox --sdk "$sdk_path" \
  -c "$configuration" --arch arm64 --product PaperLikeNative \
  -Xswiftc -no-whole-module-optimization \
  -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_os" -Xlinker "$sdk_version"
binary_dir=$(swift build --disable-sandbox --sdk "$sdk_path" \
  -c "$configuration" --arch arm64 --show-bin-path)

if [[ -d "$app_path" ]]; then
  rm -rf "$app_path"
fi
mkdir -p "$app_path/Contents/MacOS"
mkdir -p "$app_path/Contents/Resources"
cp "$binary_dir/PaperLikeNative" "$app_path/Contents/MacOS/PaperLikeNative"
# Xcode preview builds may emit companion dylibs; keep them beside the executable.
for companion_dylib in "$binary_dir"/PaperLikeNative*.dylib(N) "$binary_dir"/__preview.dylib(N); do
  cp "$companion_dylib" "$app_path/Contents/MacOS/"
done
cp "$repo_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_root/LICENSE" "$app_path/Contents/Resources/LICENSE.txt"
cp "$repo_root/Resources/AppIcon/Paperlike-Native.icns" "$app_path/Contents/Resources/Paperlike-Native.icns"
for icon_svg in "$repo_root"/Resources/MenuBarIcons/*.svg; do
  sips -s format png -z 64 64 "$icon_svg" \
    --out "$app_path/Contents/Resources/${icon_svg:t:r}.png" >/dev/null
done
icon_developer_dir=${PAPERLIKE_ICON_DEVELOPER_DIR:-${DEVELOPER_DIR:-$(xcode-select -p)}}
if [[ ! -x "$icon_developer_dir/usr/bin/actool" && -x /Applications/Xcode-beta.app/Contents/Developer/usr/bin/actool ]]; then
  icon_developer_dir=/Applications/Xcode-beta.app/Contents/Developer
fi
icon_tool="$icon_developer_dir/../Applications/Icon Composer.app/Contents/Executables/ictool"
about_icon="$app_path/Contents/Resources/PaperLikeNativeAboutIcon.png"
if [[ -x "$icon_tool" ]]; then
  "$icon_tool" "$repo_root/Resources/AppIcon/Paperlike-Native.icon" --export-image \
    --output-file "$about_icon" --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
else
  cp "$repo_root/Resources/AppIcon/Paperlike-Native-rendered.png" "$about_icon"
fi
if [[ -x "$icon_developer_dir/usr/bin/actool" ]]; then
  DEVELOPER_DIR="$icon_developer_dir" xcrun actool --compile "$app_path/Contents/Resources" \
    --platform macosx --minimum-deployment-target "$minimum_os" \
    --app-icon Paperlike-Native --skip-app-store-deployment \
    --output-partial-info-plist "$repo_root/.build/Paperlike-Icon-Partial.plist" \
    "$repo_root/Resources/AppIcon/Paperlike-Native.icon" >/dev/null
fi
plutil -lint "$app_path/Contents/Info.plist"
if [[ -n "$signing_identity" ]]; then
  for companion_dylib in "$app_path"/Contents/MacOS/*.dylib(N); do
    codesign --force --sign "$signing_identity" --options runtime --timestamp "$companion_dylib"
  done
  codesign --force --sign "$signing_identity" --options runtime --timestamp \
    --entitlements "$repo_root/Resources/Entitlements.plist" "$app_path"
else
  bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
  codesign --force --deep --sign - -r="designated => identifier \"$bundle_identifier\"" "$app_path"
  print -u2 '使用 ad-hoc 签名：此构建未通过 Developer ID 签名或 Apple 公证。'
fi
codesign --verify --deep --strict "$app_path"

print "$app_path"
