#!/bin/zsh
set -euo pipefail
umask 077
cd "${0:A:h:h}"
: "${MORROW_DEVELOPMENT_TEAM:?Set the development team selected in Xcode.}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
proof="${PWD}/evidence/private/signing/mac-cloud-${stamp}"
mkdir -p "$proof/project"
security find-identity -v -p codesigning > "$proof/identities-before.txt"
security find-certificate -a -c 'Apple Development' -p > "$proof/development-certificates.pem"
python3 - "$proof" "$MORROW_DEVELOPMENT_TEAM" "$PWD/configuration/MorrowDesktopCloud.entitlements" <<'PY'
import json,pathlib,re,subprocess,sys
proof=pathlib.Path(sys.argv[1]);team=sys.argv[2];entitlements=sys.argv[3]
assert re.fullmatch(r'[A-Z0-9]{10}',team), 'Invalid development team'
valid=set(re.findall(r'([0-9A-F]{40})\s+"Apple Development:[^\n]+"',(proof/'identities-before.txt').read_text()))
matching=set()
for pem in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',(proof/'development-certificates.pem').read_text(),re.S):
    metadata=subprocess.check_output(['openssl','x509','-noout','-subject','-nameopt','RFC2253','-fingerprint','-sha1'],input=pem.encode()).decode()
    subject=next(line for line in metadata.splitlines() if line.startswith('subject='))
    ou=re.search(r'(?:^|,)OU=([A-Z0-9]+)(?:,|$)',subject)
    fingerprint=next(line for line in metadata.splitlines() if 'Fingerprint=' in line).split('=')[-1].replace(':','').strip()
    if ou and ou.group(1)==team and fingerprint in valid:matching.add(fingerprint)
assert len(matching)==1, 'Expected exactly one existing development identity for the team'
(proof/'existing-identity.sha1').write_text(next(iter(matching))+'\n')
spec={'name':'MorrowDesktopCloudProfile','targets':{'MorrowDesktopCloudProfile':{
    'type':'application','platform':'macOS','deploymentTarget':'26.0','sources':['main.swift'],
    'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'app.smail.desktop','DEVELOPMENT_TEAM':team,
    'CODE_SIGN_STYLE':'Automatic','CODE_SIGN_IDENTITY':'Apple Development','CODE_SIGN_ENTITLEMENTS':entitlements,
    'GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_KEY_MorrowCloudKitContainer':'iCloud.app.smail.workspace',
    'MARKETING_VERSION':'0.9.0','CURRENT_PROJECT_VERSION':'25','ENABLE_APP_SANDBOX':'NO'}}}}}
(proof/'project/project.json').write_text(json.dumps(spec,indent=2)+'\n')
(proof/'project/main.swift').write_text('import AppKit\nNSApplication.shared.run()\n')
PY
xcodegen generate --spec "$proof/project/project.json" > "$proof/xcodegen.log" 2>&1
print 'Preparing the desktop CloudKit development profile. Logs are private.'
asc xcode build --project "$proof/project/MorrowDesktopCloudProfile.xcodeproj" --scheme MorrowDesktopCloudProfile \
  --configuration Release --destination 'platform=macOS,arch=arm64' \
  --derived-data-path "$PWD/.build-desktop-cloud-profile" --result-bundle-path "$proof/Build.xcresult" \
  --xcodebuild-flag=-allowProvisioningUpdates --xcodebuild-flag=-allowProvisioningDeviceRegistration \
  --output json > "$proof/build.json" 2> "$proof/build.log"
app="$PWD/.build-desktop-cloud-profile/Build/Products/Release/MorrowDesktopCloudProfile.app"
codesign --verify --deep --strict "$app" > "$proof/verify.log" 2>&1
codesign -d --entitlements :- "$app" > "$proof/signed-entitlements.plist" 2> "$proof/codesign.log"
codesign -d "--extract-certificates=$proof/signed-certificate-" "$app" > "$proof/certificate-extract.log" 2>&1
security cms -D -i "$app/Contents/embedded.provisionprofile" > "$proof/profile.plist"
cp "$app/Contents/embedded.provisionprofile" "$proof/MorrowDesktopCloud.provisionprofile"
security find-identity -v -p codesigning > "$proof/identities-after.txt"
python3 - "$proof" "$MORROW_DEVELOPMENT_TEAM" <<'PY'
import datetime,hashlib,json,pathlib,plistlib,subprocess,sys
proof=pathlib.Path(sys.argv[1]);team=sys.argv[2]
profile=plistlib.loads((proof/'profile.plist').read_bytes())
entitlements=plistlib.loads((proof/'signed-entitlements.plist').read_bytes())
cloud='iCloud.app.smail.workspace'
assert team in profile['TeamIdentifier'], 'Profile team mismatch'
assert profile['ExpirationDate']>datetime.datetime.now(), 'Profile expired'
assert hashlib.sha1((proof/'signed-certificate-0').read_bytes()).hexdigest().upper()==(proof/'existing-identity.sha1').read_text().strip(), 'A different development certificate was used'
app_id=profile['ApplicationIdentifierPrefix'][0]+'.app.smail.desktop'
assert entitlements.get('com.apple.application-identifier',entitlements.get('application-identifier'))==app_id, 'Desktop app identifier mismatch'
assert cloud in entitlements.get('com.apple.developer.icloud-container-identifiers',[]), 'Signed container is missing'
assert cloud in profile['Entitlements'].get('com.apple.developer.icloud-container-identifiers',[]), 'Profile does not explicitly authorize the container'
assert 'CloudKit' in entitlements.get('com.apple.developer.icloud-services',[]), 'CloudKit service is missing'
hardware=plistlib.loads(subprocess.check_output(['system_profiler','SPHardwareDataType','-xml']))
item=hardware[0]['_items'][0]
hardware_uuid=item.get('provisioning_UDID') or item.get('platform_UUID')
assert hardware_uuid and hardware_uuid in profile.get('ProvisionedDevices',[]), 'This Mac is absent from the development profile'
summary={'bundleIdentifier':'app.smail.desktop','cloudContainer':cloud,'existingCertificateVerified':True,
         'profileExplicitlyAuthorizesContainer':True,'localMacInProfile':True,
         'profilePath':str(proof/'MorrowDesktopCloud.provisionprofile'),
         'decodedProfilePath':str(proof/'profile.plist'),'signedEntitlementsPath':str(proof/'signed-entitlements.plist'),
         'cloudSyncEnabled':False,'probeWasLaunched':False}
(proof/'verified-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
PY
print "Private desktop profile receipt: $proof"
