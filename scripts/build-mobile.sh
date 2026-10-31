#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

mode="${1:-simulator}"
if [[ ! -f dist/EmbeddingGemma2-Text/model.safetensors ]]; then
  model_source="${MORROW_MODEL_SOURCE:-/Applications/Morrow.app/Contents/Resources/embeddinggemma-2}"
  python3 scripts/pack-mobile-embedding.py "$model_source" dist/EmbeddingGemma2-Text
fi
xcodegen generate --spec iOS/project.yml
destination='generic/platform=iOS Simulator'
derived='.build-mobile-expansion'
platform='iphonesimulator'
if [[ "$mode" == device || "$mode" == signed-device ]]; then
  destination='generic/platform=iOS'
  derived='.build-mobile-device'
  platform='iphoneos'
fi
google_callback_scheme=$(python3 - <<'PYCONFIG'
import json,pathlib
p=pathlib.Path("configuration/oauth-clients.json")
d=json.loads(p.read_text()) if p.exists() else {}
i=d.get("google_ios", "")
print("com.googleusercontent.apps."+i.split(".apps.googleusercontent.com")[0] if i.endswith(".apps.googleusercontent.com") else "morrow-google-oauth")
PYCONFIG
)
flags=(--no-code-signing)
if [[ "$mode" == signed-device ]]; then
  : "${MORROW_DEVELOPMENT_TEAM:?Set your Apple Development team ID locally.}"
  flags=(--xcodebuild-flag=-allowProvisioningUpdates "--xcodebuild-flag=DEVELOPMENT_TEAM=$MORROW_DEVELOPMENT_TEAM")
fi
# Resolve first, then repair the exact Xcode checkout before any compilation.
# Patching only SwiftPM's .build checkout leaves physical-device JIT broken.
xcodebuild -resolvePackageDependencies -project iOS/MorrowMobile.xcodeproj \
  -scheme MorrowMobile -clonedSourcePackagesDirPath "$derived/SourcePackages"
python3 scripts/patch-mlx-nax.py --checkout "$derived/SourcePackages/checkouts/mlx-swift"
asc xcode build --project iOS/MorrowMobile.xcodeproj --scheme MorrowMobile \
  --configuration Release --destination "$destination" --derived-data-path "$derived" \
  --xcodebuild-flag=-disableAutomaticPackageResolution "--xcodebuild-flag=GOOGLE_OAUTH_CALLBACK_SCHEME=$google_callback_scheme" "${flags[@]}" --output json
echo "App output: $derived/Build/Products/Release-$platform/MorrowMobile.app"
