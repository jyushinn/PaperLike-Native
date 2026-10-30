#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
clang_cache="$repo_root/.build/clang-module-cache"
swiftpm_cache="$repo_root/.build/swiftpm-module-cache"
mkdir -p "$clang_cache" "$swiftpm_cache"
export CLANG_MODULE_CACHE_PATH="$clang_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$swiftpm_cache"
cd "$repo_root"

filter=''
while (( $# > 0 )); do
  case "$1" in
    --filter)
      filter="$2"
      shift 2
      ;;
    *)
      print -u2 "未知测试参数: $1"
      exit 2
      ;;
  esac
done

if [[ -n "$filter" ]]; then
  exec swift run --disable-sandbox PaperlikeTests "$filter"
fi
exec swift run --disable-sandbox PaperlikeTests
