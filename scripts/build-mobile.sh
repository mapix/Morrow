#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

mode="${1:-simulator}"
if [[ ! -f dist/EmbeddingGemma2-Text/model.safetensors ]]; then
  model_source="${MORROW_MODEL_SOURCE:-/Applications/Morrow.app/Contents/Resources/embeddinggemma-2}"
  python3 scripts/pack-mobile-embedding.py "$model_source" dist/EmbeddingGemma2-Text
fi
destination='generic/platform=iOS Simulator'
derived='.build-mobile-expansion'
platform='iphonesimulator'
if [[ "$mode" == device || "$mode" == signed-device ]]; then
  destination='generic/platform=iOS'
  derived='.build-mobile-device'
  platform='iphoneos'
fi
google_callback_scheme=$(python3 - <<'PYCONFIG'
import json, os, pathlib, re, tempfile

# This generated file is ignored by Git. Never bundle the original local
# configuration: only validated public client IDs may enter an iOS resource.
explicit = os.environ.get("MORROW_OAUTH_CONFIG")
local = pathlib.Path.home() / "Library/Application Support/Morrow/oauth-clients.json"
template = pathlib.Path("configuration/oauth-clients.example.json")
source = pathlib.Path(explicit).expanduser() if explicit else local if local.is_file() else template
try:
    raw = json.loads(source.read_text()) if source.is_file() else {}
except (OSError, ValueError):
    raise SystemExit("OAuth configuration could not be read as JSON; no configuration was bundled.")
if explicit and not source.is_file():
    raise SystemExit("MORROW_OAUTH_CONFIG does not name an existing configuration file.")
if not isinstance(raw, dict):
    raise SystemExit("OAuth configuration must be a JSON object.")

clients = {}
for name in ("google", "google_ios"):
    value = raw.get(name)
    if isinstance(value, str) and re.fullmatch(r"[0-9]+-[A-Za-z0-9]+\.apps\.googleusercontent\.com", value.strip()):
        clients[name] = value.strip()
value = raw.get("microsoft")
if isinstance(value, str) and re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", value.strip()):
    clients["microsoft"] = value.strip()

output = pathlib.Path(".build-mobile-oauth/oauth-clients.json")
output.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(dir=output.parent, prefix="clients-", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as stream:
        json.dump(clients, stream, separators=(",", ":"))
    os.chmod(temporary, 0o600)
    os.replace(temporary, output)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)

scheme = os.environ.get("MORROW_GOOGLE_OAUTH_CALLBACK_SCHEME")
if scheme:
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9+.-]*", scheme):
        raise SystemExit("MORROW_GOOGLE_OAUTH_CALLBACK_SCHEME is not a URL scheme.")
else:
    client = clients.get("google_ios")
    scheme = "com.googleusercontent.apps." + client.removesuffix(".apps.googleusercontent.com") if client else "morrow-google-oauth"
print(scheme)
PYCONFIG
)
xcodegen generate --spec iOS/project.yml
flags=(--no-code-signing)
if [[ "$mode" == signed-device ]]; then
  : "${MORROW_DEVELOPMENT_TEAM:?Set your Apple Development team ID locally.}"
  flags=(--xcodebuild-flag=-allowProvisioningUpdates "--xcodebuild-flag=DEVELOPMENT_TEAM=$MORROW_DEVELOPMENT_TEAM")
fi
# Resolve first, then repair the exact Xcode checkout before any compilation.
# Patching only SwiftPM's .build checkout leaves physical-device JIT broken.
xcodebuild -resolvePackageDependencies -project iOS/MorrowMobile.xcodeproj \
  -scheme MorrowMobile -clonedSourcePackagesDirPath "$derived/SourcePackages" -jobs 4
python3 scripts/patch-mlx-nax.py --checkout "$derived/SourcePackages/checkouts/mlx-swift"
asc xcode build --project iOS/MorrowMobile.xcodeproj --scheme MorrowMobile \
  --configuration Release --destination "$destination" --derived-data-path "$derived" \
  --xcodebuild-flag=-jobs --xcodebuild-flag=4 \
  --xcodebuild-flag=-disableAutomaticPackageResolution "--xcodebuild-flag=GOOGLE_OAUTH_CALLBACK_SCHEME=$google_callback_scheme" "${flags[@]}" --output json
echo "App output: $derived/Build/Products/Release-$platform/MorrowMobile.app"
