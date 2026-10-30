#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
app_path="$repo_root/.build/PaperLike Native.app"
info_plist="$repo_root/Resources/Info.plist"
output_dir="$repo_root/dist"
version=$(plutil -extract CFBundleShortVersionString raw "$info_plist")
package_name="PaperLike-Native-${version}-macOS-arm64"
zip_path="$output_dir/$package_name.zip"
dmg_path="$output_dir/$package_name.dmg"
signing_identity=${PAPERLIKE_SIGNING_IDENTITY:-}
notary_profile=${PAPERLIKE_NOTARY_PROFILE:-}
if [[ -n "$signing_identity" && "$signing_identity" != 'Developer ID Application: '* ]]; then
    print -u2 'PAPERLIKE_SIGNING_IDENTITY 必须为 Developer ID Application 身份。'
    exit 2
fi
if [[ -n "$notary_profile" && -z "$signing_identity" ]]; then
    print -u2 '公证需要设置 PAPERLIKE_SIGNING_IDENTITY（Developer ID Application）。'
    exit 2
fi
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/paperlike-native-package.XXXXXX")

cleanup() {
    rm -rf "$staging_root"
}
trap cleanup EXIT

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait \
        --output-format json > "$staging_root/notary-result.json"
    if [[ $(plutil -extract status raw "$staging_root/notary-result.json") != Accepted ]]; then
        print -u2 "Apple 未接受公证：$1；详情："
        cat "$staging_root/notary-result.json" >&2
        return 1
    fi
}

"$repo_root/Tools/build-app.sh" release

mkdir -p "$output_dir"
if [[ -n "$notary_profile" ]]; then
    notary_zip="$staging_root/notarize-app.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notary_zip"
    notarize "$notary_zip"
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
fi
# The downloadable ZIP must contain the stapled app, not the submission ZIP.
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

dmg_contents="$staging_root/PaperLike Native"
mkdir -p "$dmg_contents"
ditto "$app_path" "$dmg_contents/PaperLike Native.app"
cp "$repo_root/Resources/首次打开说明.txt" "$dmg_contents/首次打开说明.txt"
ln -s /Applications "$dmg_contents/Applications"

hdiutil create \
    -volname "PaperLike Native" \
    -srcfolder "$dmg_contents" \
    -format UDZO \
    -ov \
    "$dmg_path"

if [[ -n "$signing_identity" ]]; then
    codesign --force --sign "$signing_identity" --timestamp "$dmg_path"
    codesign --verify --strict "$dmg_path"
fi
if [[ -n "$notary_profile" ]]; then
    notarize "$dmg_path"
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
fi

codesign --verify --deep --strict "$app_path"
plutil -lint "$app_path/Contents/Info.plist"

print
print "已生成："
print "$zip_path"
print "$dmg_path"
print
cd "$output_dir"
shasum -a 256 "$package_name.zip" "$package_name.dmg" > SHA256SUMS
print "$output_dir/SHA256SUMS"
if [[ -z "$notary_profile" ]]; then
    print -u2 '此分发包未通过 Apple 公证；请按分发与安装文档说明其签名状态。'
fi
