#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift package resolve
python3 scripts/patch-mlx-nax.py
python3 scripts/patch-package-resources.py
build_configuration="${MORROW_BUILD_CONFIGURATION:-release}"
swift build --configuration "$build_configuration" --jobs 4 -Xswiftc -debug-prefix-map -Xswiftc "$PWD=." -Xswiftc -file-prefix-map -Xswiftc "$PWD=." -Xcc "-ffile-prefix-map=$PWD=." -Xcc "-fdebug-prefix-map=$PWD=."
if [[ ! -f .build/morrow-metal/mlx.metallib ]]; then python3 scripts/build-metal.py; fi
mkdir -p dist
final_app_path="$PWD/dist/Morrow.app"
staging_path=$(mktemp -d "$PWD/dist/morrow-build.XXXXXX")
previous_app_path="$staging_path/previous.app"
cleanup_package() {
  if [[ ! -d "$final_app_path" && -d "$previous_app_path" ]]; then mv "$previous_app_path" "$final_app_path"; fi
  if [[ -d "$staging_path" ]]; then rm -rf "$staging_path"; fi
}
trap cleanup_package EXIT
app_path="$staging_path/Morrow.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/arm64-apple-macosx/$build_configuration/Morrow "$app_path/Contents/MacOS/Morrow"
cp .build/morrow-metal/mlx.metallib "$app_path/Contents/Resources/mlx.metallib"
for bundle_path in .build/arm64-apple-macosx/$build_configuration/*.bundle(N); do
  ditto "$bundle_path" "$app_path/Contents/Resources/${bundle_path:t}"
done
if [[ ${MORROW_BUNDLE_MODEL:-1} == 1 ]]; then
  default_model_path="$HOME/Library/Application Support/Morrow/models/embeddinggemma-2"
  if [[ -f "$PWD/dist/EmbeddingGemma2-Text/model.safetensors" ]]; then default_model_path="$PWD/dist/EmbeddingGemma2-Text"; fi
  model_path="${MORROW_MODEL_DIR:-$default_model_path}"
  if [[ ! -f "$model_path/model.safetensors" ]]; then python3 scripts/download-embedding.py "$model_path"; fi
  ditto "$model_path" "$app_path/Contents/Resources/embeddinggemma-2"
fi
icon_source="${MORROW_APP_ICON:-$PWD/website/assets/morrow-icon.png}"
if [[ ! -f "$icon_source" ]]; then print -u2 "Missing generated Morrow icon: $icon_source"; exit 1; fi
cp "$icon_source" "$PWD/dist/icon.png"
mkdir -p dist/AppIcon.iconset
for icon_size in 16 32 128 256 512; do
  sips -z "$icon_size" "$icon_size" dist/icon.png --out "dist/AppIcon.iconset/icon_${icon_size}x${icon_size}.png" >/dev/null
  double_size=$((icon_size * 2))
  sips -z "$double_size" "$double_size" dist/icon.png --out "dist/AppIcon.iconset/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns dist/AppIcon.iconset -o "$app_path/Contents/Resources/AppIcon.icns"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Morrow</string>
<key>CFBundleDisplayName</key><string>Morrow</string>
<key>CFBundleIdentifier</key><string>app.smail.desktop</string>
<key>CFBundleExecutable</key><string>Morrow</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.10.1</string>
<key>CFBundleVersion</key><string>101</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSContactsUsageDescription</key><string>将你选择允许访问的系统联系人导入本机邮件通讯录。</string>
<key>NSCalendarsWriteOnlyAccessUsageDescription</key><string>将你确认的邮件会议邀请添加到系统日历。</string>
<key>NSMicrophoneUsageDescription</key><string>将你主动录制的语音转成Chat输入文字。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>使用本机中文语音识别，将你的语音转成邮件伙伴的输入。</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Mail message</string><key>CFBundleURLSchemes</key><array><string>mailto</string></array></dict></array>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Email message</string><key>CFBundleTypeExtensions</key><array><string>eml</string><string>mbox</string></array><key>CFBundleTypeRole</key><string>Viewer</string></dict></array>
</dict></plist>
PLIST
oauth_configuration="${MORROW_OAUTH_CONFIG:-configuration/oauth-clients.example.json}"
if [[ -f "$oauth_configuration" ]]; then cp "$oauth_configuration" "$app_path/Contents/Resources/oauth-clients.json"; fi
mkdir -p "$app_path/Contents/Resources/Notices"
cp .build/checkouts/mlx-swift/LICENSE "$app_path/Contents/Resources/Notices/MLX-LICENSE"
cp .build/checkouts/mlx-swift-lm/LICENSE "$app_path/Contents/Resources/Notices/MLX-LM-LICENSE"
cp .build/checkouts/swift-transformers/LICENSE "$app_path/Contents/Resources/Notices/Transformers-LICENSE"
cp LICENSE "$app_path/Contents/Resources/Notices/EmbeddingGemma2-LICENSE"
cp Tests/Fixtures/OpenUI/LICENSE "$app_path/Contents/Resources/Notices/OpenUI-MIT-LICENSE"
cp docs/public/OPENUI-NATIVE-LIBRARY.json "$app_path/Contents/Resources/Notices/OpenUI-native-library.json"
cp docs/public/EMBEDDING-MODEL-CARD.md "$app_path/Contents/Resources/Notices/EmbeddingGemma2-MODEL-CARD.md"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
if [[ -d "$final_app_path" ]]; then
  if [[ -d "$previous_app_path" ]]; then rm -rf "$previous_app_path"; fi
  mv "$final_app_path" "$previous_app_path"
fi
mv "$app_path" "$final_app_path"
print "Ready: $final_app_path"
