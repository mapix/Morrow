#!/bin/zsh
set -euo pipefail
umask 077
cd "${0:A:h:h}"

# Use an existing Apple Development identity from the selected Xcode team.
# With MORROW_SIGNING_PROFILE_UUID, use an existing profile without portal changes.
# Otherwise Xcode can update this app's profile and register the target device.
: "${MORROW_DEVELOPMENT_TEAM:?Set the development team selected in Xcode.}"
: "${MORROW_DEVICE_ID:?Set the paired iPhone identifier from devicectl.}"
action="${1:-install}"
[[ "$action" == build || "$action" == install || "$action" == launch ]] || {
  print -u2 'Usage: sign-install-mobile.sh [build|install|launch]'
  exit 2
}
[[ "$MORROW_DEVELOPMENT_TEAM" =~ '^[A-Z0-9]{10}$' ]] || {
  print -u2 'Invalid development team.'
  exit 2
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
proof="${PWD}/evidence/private/signing/${stamp}"
derived="${MORROW_DERIVED_DATA_PATH:-${PWD}/.build-mobile-signing}"
app="${derived}/Build/Products/Release-iphoneos/MorrowMobile.app"
mkdir -p "$proof"
security find-identity -v -p codesigning > "$proof/identities.txt"
security find-certificate -a -c 'Apple Development' -p > "$proof/development-certificates.pem"
identity="$(python3 - "$proof/identities.txt" "$proof/development-certificates.pem" "$MORROW_DEVELOPMENT_TEAM" <<'PY'
import pathlib, re, subprocess, sys
text = pathlib.Path(sys.argv[1]).read_text()
valid = set(re.findall(r'([0-9A-F]{40})\s+"Apple Development:[^\n]+"', text))
identities = set()
certificates = pathlib.Path(sys.argv[2]).read_text()
for pem in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', certificates, re.S):
    metadata = subprocess.check_output(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253', '-fingerprint', '-sha1'], input=pem.encode()).decode()
    subject = next(line for line in metadata.splitlines() if line.startswith('subject='))
    team = re.search(r'(?:^|,)OU=([A-Z0-9]+)(?:,|$)', subject)
    fingerprint = next(line for line in metadata.splitlines() if 'Fingerprint=' in line).split('=')[-1].replace(':', '').strip()
    if team and team.group(1) == sys.argv[3] and fingerprint in valid:
        identities.add(fingerprint)
if len(identities) != 1:
    raise SystemExit('Expected exactly one existing Apple Development identity for the selected team. See the private identity audit.')
print(next(iter(identities)))
PY
)"
xcrun devicectl list devices --quiet --json-output "$proof/devices.json" > "$proof/devices.log" 2>&1
device_udid="$(python3 - "$proof/devices.json" "$MORROW_DEVICE_ID" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
matches = [d for d in data['result']['devices'] if d['identifier'] == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit('The target device was not found.')
device = matches[0]
if device['connectionProperties'].get('pairingState') != 'paired' or device['connectionProperties'].get('tunnelState') != 'connected':
    raise SystemExit('The target device must be paired and connected.')
print(device['hardwareProperties']['udid'])
PY
)"
flags=("--xcodebuild-flag=DEVELOPMENT_TEAM=$MORROW_DEVELOPMENT_TEAM"
       "--xcodebuild-flag=CODE_SIGN_IDENTITY=$identity")
if [[ -n "${MORROW_SIGNING_PROFILE_UUID:-}" ]]; then
  # A command-line profile setting would also reach SwiftPM resource bundles.
  # Compile unsigned, then apply the app profile and concrete entitlements here.
  flags=(--no-code-signing)
else
  # Automatic provisioning accepts the generic identity name only. The exact
  # existing certificate is checked before and after Xcode signs the app.
  flags=("--xcodebuild-flag=DEVELOPMENT_TEAM=$MORROW_DEVELOPMENT_TEAM"
          --xcodebuild-flag=CODE_SIGN_IDENTITY=Apple\ Development
          --xcodebuild-flag=CODE_SIGN_STYLE=Automatic
          --xcodebuild-flag=-allowProvisioningUpdates
          --xcodebuild-flag=-allowProvisioningDeviceRegistration)
fi
if [[ -n "${MORROW_CLOUD_CONTAINER:-}" ]]; then
  python3 - "$proof/MorrowCloud.entitlements" "$MORROW_CLOUD_CONTAINER" <<'PY'
import plistlib, re, sys
container = sys.argv[2]
if not re.fullmatch(r'iCloud\.[A-Za-z0-9.-]+', container):
    raise SystemExit('Invalid iCloud container identifier.')
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'keychain-access-groups': ['$(AppIdentifierPrefix)app.smail.mobile'],
                  'com.apple.developer.icloud-container-identifiers': [container],
                  'com.apple.developer.icloud-services': ['CloudKit'],
                  'com.apple.developer.icloud-container-environment': 'Development'}, f)
PY
  flags+=("--xcodebuild-flag=CODE_SIGN_ENTITLEMENTS=$proof/MorrowCloud.entitlements"
          "--xcodebuild-flag=INFOPLIST_KEY_MorrowCloudKitContainer=$MORROW_CLOUD_CONTAINER")
fi
if [[ "${MORROW_REUSE_COMPILED_APP:-0}" == 1 ]]; then
  [[ -n "${MORROW_SIGNING_PROFILE_UUID:-}" && -f "$app/Info.plist" ]] || {
    print -u2 'Reusing a compiled app requires an existing profile and app.'
    exit 2
  }
  print 'Signing the previously verified compiled app. Logs are private.'
else
  print 'Building the device app. Logs are private.'
  asc xcode build --project iOS/MorrowMobile.xcodeproj --scheme MorrowMobile \
    --configuration Release --destination "platform=iOS,id=$device_udid" \
    --derived-data-path "$derived" --result-bundle-path "$proof/Build.xcresult" \
    "${flags[@]}" --output json > "$proof/build.json" 2> "$proof/build.log"
fi
if [[ -n "${MORROW_SIGNING_PROFILE_UUID:-}" ]]; then
  asc profiles local list --output json > "$proof/local-profiles.json"
  python3 - "$app" "$proof" "$MORROW_SIGNING_PROFILE_UUID" "$MORROW_DEVELOPMENT_TEAM" "$device_udid" "$identity" "${MORROW_CLOUD_CONTAINER:-}" <<'PY'
import datetime, fnmatch, hashlib, json, pathlib, plistlib, shutil, subprocess, sys
app, proof = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
uuid, team, device, identity, cloud = sys.argv[3:8]
rows = json.loads((proof / 'local-profiles.json').read_text())['items']
row = next(r for r in rows if r['uuid'] == uuid)
profile_data = subprocess.check_output(['security', 'cms', '-D', '-i', row['path']])
(proof / 'profile.plist').write_bytes(profile_data)
profile = plistlib.loads(profile_data)
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'app.smail.mobile', 'Unexpected bundle identifier'
assert team in profile['TeamIdentifier'], 'Profile team mismatch'
assert device in profile.get('ProvisionedDevices', []), 'Target device is absent from the profile'
assert profile['ExpirationDate'] > datetime.datetime.now(), 'Profile expired'
assert identity in {hashlib.sha1(c).hexdigest().upper() for c in profile['DeveloperCertificates']}, 'Signing identity is absent from the profile'
application_id = profile['ApplicationIdentifierPrefix'][0] + '.' + info['CFBundleIdentifier']
allowed = profile['Entitlements']
assert fnmatch.fnmatch(application_id, allowed['application-identifier']), 'App ID is outside the profile'
assert any(fnmatch.fnmatch(application_id, group) for group in allowed.get('keychain-access-groups', [])), 'Keychain group is outside the profile'
entitlements = {'application-identifier': application_id, 'keychain-access-groups': [application_id],
                'com.apple.developer.team-identifier': team, 'get-task-allow': allowed.get('get-task-allow', False)}
if cloud:
    assert cloud in allowed.get('com.apple.developer.icloud-container-identifiers', []), 'Profile does not authorize the requested cloud container'
    assert any(fnmatch.fnmatch('CloudKit', service) for service in allowed.get('com.apple.developer.icloud-services', [])), 'Profile does not authorize CloudKit'
    info['MorrowCloudKitContainer'] = cloud
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    assert 'Development' in allowed.get('com.apple.developer.icloud-container-environment', []), 'Profile does not authorize the development cloud environment'
    entitlements.update({'com.apple.developer.icloud-container-identifiers': [cloud], 'com.apple.developer.icloud-services': ['CloudKit'], 'com.apple.developer.icloud-container-environment': 'Development'})
else:
    assert not info.get('MorrowCloudKitContainer'), 'Existing app contains unexpected cloud configuration'
assert not list((app / 'Frameworks').glob('*')) and not list((app / 'PlugIns').glob('*')), 'Nested code requires explicit signing before the app'
shutil.copyfile(row['path'], app / 'embedded.mobileprovision')
(proof / 'signing-entitlements.plist').write_bytes(plistlib.dumps(entitlements))
(proof / 'executable-before-sign.sha256').write_text(hashlib.sha256((app / info['CFBundleExecutable']).read_bytes()).hexdigest() + '\n')
PY
  codesign --force --sign "$identity" --entitlements "$proof/signing-entitlements.plist" "$app" > "$proof/signing.log" 2>&1
fi
codesign --verify --deep --strict "$app" > "$proof/verify.log" 2>&1
codesign -d --entitlements :- "$app" > "$proof/signed-entitlements.plist" 2> "$proof/codesign.log"
codesign -d "--extract-certificates=$proof/signed-certificate-" "$app" > "$proof/certificate-extract.log" 2>&1
security cms -D -i "$app/embedded.mobileprovision" > "$proof/profile.plist"
python3 - "$app" "$proof" "$MORROW_DEVELOPMENT_TEAM" "$device_udid" "${MORROW_CLOUD_CONTAINER:-}" "$identity" <<'PY'
import datetime, fnmatch, hashlib, json, pathlib, plistlib, sys
app, proof = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
team, device, cloud, identity = sys.argv[3:7]
info = plistlib.loads((app / 'Info.plist').read_bytes())
profile = plistlib.loads((proof / 'profile.plist').read_bytes())
entitlements = plistlib.loads((proof / 'signed-entitlements.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'app.smail.mobile', 'Unexpected bundle identifier'
assert team in profile['TeamIdentifier'], 'Profile team mismatch'
assert device in profile.get('ProvisionedDevices', []), 'Target device is absent from the profile'
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Profile expired'
assert entitlements['com.apple.developer.team-identifier'] == team, 'Signature team mismatch'
assert hashlib.sha1((proof / 'signed-certificate-0').read_bytes()).hexdigest().upper() == identity, 'Xcode did not use the prevalidated existing development identity'
application_id = profile['ApplicationIdentifierPrefix'][0] + '.' + info['CFBundleIdentifier']
assert entitlements['application-identifier'] == application_id, 'Signature does not contain the concrete app ID'
assert application_id in entitlements.get('keychain-access-groups', []), 'Concrete app Keychain group is absent'
assert all('*' not in group for group in entitlements['keychain-access-groups']), 'Signed Keychain groups must be concrete'
assert fnmatch.fnmatch(application_id, profile['Entitlements']['application-identifier']), 'App ID is outside the profile'
if cloud:
    assert info.get('MorrowCloudKitContainer') == cloud, 'Runtime container configuration mismatch'
    assert cloud in entitlements.get('com.apple.developer.icloud-container-identifiers', []), 'Signed container entitlement is missing'
    assert 'CloudKit' in entitlements.get('com.apple.developer.icloud-services', []), 'CloudKit service entitlement is missing'
    assert cloud in profile['Entitlements'].get('com.apple.developer.icloud-container-identifiers', []), 'Profile does not explicitly authorize the signed cloud container'
    assert entitlements.get('com.apple.developer.icloud-container-environment') == 'Development', 'Unexpected cloud environment'
else:
    assert not info.get('MorrowCloudKitContainer'), 'Unexpected runtime cloud configuration'
summary = {'signatureVerified': True, 'targetDeviceInProfile': True, 'concreteKeychainGroupVerified': True,
           'bundleIdentifier': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
           'build': info['CFBundleVersion'], 'cloudKitConfigured': bool(cloud), 'appPath': str(app)}
(proof / 'verified-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
PY
if [[ "$action" != build ]]; then
  xcrun devicectl device install app --device "$MORROW_DEVICE_ID" "$app" \
    --quiet --json-output "$proof/install.json" > "$proof/install.log" 2>&1
  print 'Signed Morrow installed on the selected iPhone.'
fi
if [[ "$action" == launch ]]; then
  xcrun devicectl device process launch --device "$MORROW_DEVICE_ID" app.smail.mobile \
    --quiet --json-output "$proof/launch.json" > "$proof/launch.log" 2>&1
  print 'Morrow launched on the selected iPhone.'
fi
print "Private signing receipt: $proof"
