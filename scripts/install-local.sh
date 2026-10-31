#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_app="$PWD/dist/Morrow.app"
target_app="/Applications/Morrow.app"
if pgrep -x Morrow >/dev/null || pgrep -x Smail >/dev/null; then
  print -u2 'Morrow is running. Quit it from its menu before installing this build.'
  exit 2
fi
codesign --verify --deep --strict "$source_app"
if [[ $(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist") != app.smail.desktop ]]; then
  print -u2 'The source is not the Morrow desktop package.'; exit 1
fi
staging_root=$(mktemp -d /Applications/.morrow-install.XXXXXX)
backup_app="$staging_root/previous.app"
cleanup_install() {
  if [[ ! -d "$target_app" && -d "$backup_app" ]]; then mv "$backup_app" "$target_app"; fi
  if [[ -d "$staging_root" ]]; then rm -rf "$staging_root"; fi
}
trap cleanup_install EXIT
ditto "$source_app" "$staging_root/Morrow.app"
codesign --verify --deep --strict "$staging_root/Morrow.app"
if [[ -d "$target_app" ]]; then
  if [[ -d "$backup_app" ]]; then rm -rf "$backup_app"; fi
  mv "$target_app" "$backup_app"
fi
mv "$staging_root/Morrow.app" "$target_app"
print "Installed: $target_app"
if [[ ${MORROW_LAUNCH_AFTER_INSTALL:-1} == 1 ]]; then open "$target_app"; fi
