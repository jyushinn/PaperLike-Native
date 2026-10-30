#!/bin/zsh
set -euo pipefail

# Exercise the real package script without building, signing or contacting Apple.
repo_root=${0:A:h:h}
if zsh "$repo_root/Tools/build-app.sh" invalid >/dev/null 2>&1; then
  print -u2 'Invalid build configuration was accepted'; exit 1
fi
if PAPERLIKE_SIGNING_IDENTITY='-' zsh "$repo_root/Tools/build-app.sh" release >/dev/null 2>&1; then
  print -u2 'Invalid Developer ID identity was accepted'; exit 1
fi
if zsh "$repo_root/Tools/capture-reference-session.sh" >/dev/null 2>&1; then
  print -u2 'Missing capture package was accepted'; exit 1
fi
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/paperlike-release-test.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/Tools" "$fixture_root/Resources" "$fixture_root/bin"
cp "$repo_root/Tools/package-app.sh" "$fixture_root/Tools/"
cp "$repo_root/Resources/Info.plist" "$fixture_root/Resources/"
cp "$repo_root/Resources/首次打开说明.txt" "$fixture_root/Resources/"
export PAPERLIKE_TEST_LOG="$fixture_root/commands.log"
export PAPERLIKE_TEST_ROOT="$fixture_root"
cat > "$fixture_root/Tools/build-app.sh" <<'STUB'
#!/bin/zsh
mkdir -p "$PAPERLIKE_TEST_ROOT/.build/PaperLike Native.app/Contents"
cp "$PAPERLIKE_TEST_ROOT/Resources/Info.plist" "$PAPERLIKE_TEST_ROOT/.build/PaperLike Native.app/Contents/Info.plist"
print build >> "$PAPERLIKE_TEST_LOG"
STUB
cat > "$fixture_root/bin/stub" <<'STUB'
#!/bin/zsh
print "${0:t} $*" >> "$PAPERLIKE_TEST_LOG"
case ${0:t} in
  ditto) if [[ $1 == -c ]]; then touch "${@: -1}"; else mkdir -p "$2"; fi ;;
  hdiutil) touch "${@: -1}" ;;
  xcrun)
    [[ ${PAPERLIKE_TEST_FAIL_NOTARY:-0} != 1 || $1 != notarytool ]] || exit 1
    if [[ $1 == notarytool ]]; then
      print '{"status":"'${PAPERLIKE_TEST_NOTARY_STATUS:-Accepted}'"}'
    fi ;;
esac
STUB
chmod +x "$fixture_root/Tools/build-app.sh" "$fixture_root/bin/stub"
for command_name in ditto hdiutil codesign xcrun; do
  ln -s stub "$fixture_root/bin/$command_name"
done
export PATH="$fixture_root/bin:$PATH"
export PAPERLIKE_SIGNING_IDENTITY='Developer ID Application: Test (TESTTEAM)'
export PAPERLIKE_NOTARY_PROFILE='test-profile'
zsh "$fixture_root/Tools/package-app.sh" >/dev/null
[[ -s "$fixture_root/dist/SHA256SUMS" ]] || { print -u2 'Missing persisted SHA256SUMS'; exit 1; }
# App ticket must be stapled before the final ZIP/DMG; DMG gets its own ticket.
awk '
  /notarytool submit/ { if ($0 !~ /--wait/) exit 1; submits++ }
  /stapler staple .*\.app/ { app_stapled=1 }
  /ditto -c/ { if (submits > 0 && !app_stapled) exit 1 }
  /hdiutil create/ { if (!app_stapled) exit 1; image_created=1 }
  /stapler staple .*\.dmg/ { if (!image_created || submits != 2) exit 1; image_stapled=1 }
  END { if (!app_stapled || !image_stapled || submits != 2) exit 1 }
' "$PAPERLIKE_TEST_LOG"
export PAPERLIKE_TEST_FAIL_NOTARY=1
if zsh "$fixture_root/Tools/package-app.sh" >/dev/null 2>&1; then
  print -u2 'Notarization failure was ignored'; exit 1
fi
unset PAPERLIKE_TEST_FAIL_NOTARY
export PAPERLIKE_TEST_NOTARY_STATUS=Invalid
if zsh "$fixture_root/Tools/package-app.sh" >/dev/null 2>&1; then
  print -u2 'Rejected notarization status was ignored'; exit 1
fi
unset PAPERLIKE_TEST_NOTARY_STATUS PAPERLIKE_SIGNING_IDENTITY
if zsh "$fixture_root/Tools/package-app.sh" >/dev/null 2>&1; then
  print -u2 'Notarization without Developer ID was allowed'; exit 1
fi
unset PAPERLIKE_NOTARY_PROFILE
zsh "$fixture_root/Tools/package-app.sh" >/dev/null
print 'Release tooling checks passed (stubbed external signing/notarization).'
