#!/bin/zsh
set -euo pipefail
umask 077
cd "${0:A:h:h}"
: "${MORROW_DEVELOPMENT_TEAM:?Set the development team selected in Xcode.}"
: "${MORROW_DEVICE_ID:?Set the paired iPhone identifier.}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
proof="${PWD}/evidence/private/signing/ios-cloud-${stamp}"
mkdir -p "$proof/project"
security find-identity -v -p codesigning > "$proof/identities-before.txt"
security find-certificate -a -c 'Apple Development' -p > "$proof/development-certificates.pem"
xcrun devicectl list devices --quiet --json-output "$proof/devices.json" > "$proof/devices.log" 2>&1
device_udid="$(python3 - "$proof" "$MORROW_DEVELOPMENT_TEAM" "$MORROW_DEVICE_ID" "$PWD/iOS/MorrowMobile/MorrowMobile.entitlements" <<'PY'
import json,pathlib,re,subprocess,sys
proof=pathlib.Path(sys.argv[1]);team=sys.argv[2];device_id=sys.argv[3];entitlements=sys.argv[4]
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
device=next(d for d in json.loads((proof/'devices.json').read_text())['result']['devices'] if d['identifier']==device_id)
assert device['connectionProperties'].get('pairingState')=='paired' and device['connectionProperties'].get('tunnelState')=='connected', 'Target device is not connected and paired'
udid=device['hardwareProperties']['udid']
(proof/'target-device.udid').write_text(udid+'\n')
spec={'name':'MorrowMobileCloudProfile','targets':{'MorrowMobileCloudProfile':{
    'type':'application','platform':'iOS','deploymentTarget':'26.0','sources':['SigningProbe.swift'],
    'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'app.smail.mobile','DEVELOPMENT_TEAM':team,
    'CODE_SIGN_STYLE':'Automatic','CODE_SIGN_IDENTITY':'Apple Development','CODE_SIGN_ENTITLEMENTS':entitlements,
    'GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_KEY_MorrowCloudKitContainer':'iCloud.app.smail.workspace',
    'MARKETING_VERSION':'0.9.0','CURRENT_PROJECT_VERSION':'25','TARGETED_DEVICE_FAMILY':'1,2'}}}}}
(proof/'project/project.json').write_text(json.dumps(spec,indent=2)+'\n')
(proof/'project/SigningProbe.swift').write_text('import SwiftUI\n@main struct SigningProbe: App { var body: some Scene { WindowGroup { Text("Signing profile probe") } } }\n')
print(udid)
PY
)"
xcodegen generate --spec "$proof/project/project.json" > "$proof/xcodegen.log" 2>&1
print 'Preparing the mobile CloudKit development profile. Logs are private.'
asc xcode build --project "$proof/project/MorrowMobileCloudProfile.xcodeproj" --scheme MorrowMobileCloudProfile \
  --configuration Release --destination "platform=iOS,id=$device_udid" \
  --derived-data-path "$PWD/.build-ios-cloud-profile" --result-bundle-path "$proof/Build.xcresult" \
  --xcodebuild-flag=-allowProvisioningUpdates --xcodebuild-flag=-allowProvisioningDeviceRegistration \
  --output json > "$proof/build.json" 2> "$proof/build.log"
app="$PWD/.build-ios-cloud-profile/Build/Products/Release-iphoneos/MorrowMobileCloudProfile.app"
codesign --verify --deep --strict "$app" > "$proof/verify.log" 2>&1
codesign -d --entitlements :- "$app" > "$proof/signed-entitlements.plist" 2> "$proof/codesign.log"
codesign -d "--extract-certificates=$proof/signed-certificate-" "$app" > "$proof/certificate-extract.log" 2>&1
cp "$app/embedded.mobileprovision" "$proof/MorrowMobileCloud.mobileprovision"
security cms -D -i "$app/embedded.mobileprovision" > "$proof/profile.plist"
security find-identity -v -p codesigning > "$proof/identities-after.txt"
python3 - "$proof" "$MORROW_DEVELOPMENT_TEAM" <<'PY'
import datetime,hashlib,json,pathlib,plistlib,sys
proof=pathlib.Path(sys.argv[1]);team=sys.argv[2]
profile=plistlib.loads((proof/'profile.plist').read_bytes())
entitlements=plistlib.loads((proof/'signed-entitlements.plist').read_bytes())
cloud='iCloud.app.smail.workspace'
assert team in profile['TeamIdentifier'], 'Profile team mismatch'
assert profile['ExpirationDate']>datetime.datetime.now(), 'Profile expired'
assert (proof/'target-device.udid').read_text().strip() in profile.get('ProvisionedDevices',[]), 'Target iPhone is absent from the profile'
assert hashlib.sha1((proof/'signed-certificate-0').read_bytes()).hexdigest().upper()==(proof/'existing-identity.sha1').read_text().strip(), 'A different development certificate was used'
app_id=profile['ApplicationIdentifierPrefix'][0]+'.app.smail.mobile'
assert entitlements.get('application-identifier')==app_id, 'Mobile app identifier mismatch'
assert app_id in entitlements.get('keychain-access-groups',[]), 'Concrete app Keychain group is absent'
assert cloud in entitlements.get('com.apple.developer.icloud-container-identifiers',[]), 'Signed container is missing'
assert cloud in profile['Entitlements'].get('com.apple.developer.icloud-container-identifiers',[]), 'Profile does not explicitly authorize the container'
assert 'CloudKit' in entitlements.get('com.apple.developer.icloud-services',[]), 'CloudKit service is missing'
summary={'bundleIdentifier':'app.smail.mobile','cloudContainer':cloud,'existingCertificateVerified':True,
         'profileExplicitlyAuthorizesContainer':True,'targetIPhoneInProfile':True,
         'profilePath':str(proof/'MorrowMobileCloud.mobileprovision'),
         'decodedProfilePath':str(proof/'profile.plist'),'signedEntitlementsPath':str(proof/'signed-entitlements.plist'),
         'cloudSyncEnabled':False,'probeWasInstalled':False,'probeWasLaunched':False}
(proof/'verified-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
PY
print "Private mobile profile receipt: $proof"
