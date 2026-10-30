#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
package_path=${1:-}
if [[ $# != 1 || ! -f "$package_path" || "$package_path" != *.pkg ]]; then
  print -u2 '用法：Tools/capture-reference-session.sh /absolute/path/to/reference.pkg'
  exit 2
fi
# A fresh extraction avoids accidentally capturing an older package's client.
mkdir -p "$repo_root/.build"
work_path=$(mktemp -d "$repo_root/.build/reference.XXXXXX")
trap 'rm -rf "$work_path"' EXIT
capture_path="$repo_root/.captures/reference-session.tsv"

if pgrep -x PaperLikeClient >/dev/null; then
  print -u2 '请先退出正在运行的 PaperLikeClient。'
  exit 2
fi

mkdir -p "$repo_root/.captures"
expanded_path="$work_path/expanded"
pkgutil --expand-full "$package_path" "$expanded_path"

app_path="$expanded_path/PaperLike260704.pkg/Payload/PaperLikeClient.app"
clang -Wall -Wextra -Werror -dynamiclib \
  "$repo_root/Tools/SerialTap/serialtap.c" \
  -o "$work_path/serialtap.dylib"
codesign --force --deep --sign - "$app_path"
: > "$capture_path"

PAPERLIKE_CAPTURE_PATH="$capture_path" \
DYLD_INSERT_LIBRARIES="$work_path/serialtap.dylib" \
"$app_path/Contents/MacOS/PaperLikeClient"
