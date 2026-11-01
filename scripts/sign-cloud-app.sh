#!/bin/zsh
set -euo pipefail
umask 077
cd "${0:A:h:h}"
exec python3 - "$@" <<'PY'
"""Sign a compiled Morrow macOS app with prepared Apple development assets.

No build, provisioning update, certificate change, or cloud access is performed.
--check validates inputs without copying, editing, signing, or installing the app.
--output clones into a new path. Repeated in-place signing is a verified no-op.
"""
import argparse, copy, datetime, fnmatch, hashlib, json, os, pathlib, plistlib
import re, shutil, subprocess, sys, uuid

ROOT = pathlib.Path.cwd()
CONTAINER = 'iCloud.app.smail.workspace'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('platform', choices=['macos'])
parser.add_argument('--app', required=True, help='Already compiled .app bundle')
parser.add_argument('--profile', required=True, help='Prepared Apple CMS provisioning profile')
parser.add_argument('--entitlements', required=True, help='Concrete signing entitlements, with no build macros')
parser.add_argument('--identity-file', required=True, help='File containing the existing development certificate SHA1')
parser.add_argument('--output', help='Optional new clone destination; must not already exist')
parser.add_argument('--expect-version')
parser.add_argument('--expect-build')
parser.add_argument('--cloud-environment', choices=['Development', 'Production'], default='Development', help='Concrete environment already authorized by the supplied profile')
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
os.umask(0o077)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
proof = ROOT / 'evidence/private/signing' / ('sign-cloud-' + args.platform + '-' + stamp + '-' + uuid.uuid4().hex[:6])
proof.mkdir(parents=True, mode=0o700)

def require(condition, message):
    if not condition:
        raise ValueError(message)

def run(command, log, stdout_path=None, check=True):
    with (proof / log).open('ab') as err:
        if stdout_path:
            with pathlib.Path(stdout_path).open('wb') as out:
                result = subprocess.run(command, stdout=out, stderr=err)
        else:
            result = subprocess.run(command, stdout=err, stderr=err)
    if check and result.returncode:
        raise ValueError('Command failed; inspect private ' + log)
    return result.returncode

def profile_allows(patterns, value):
    if isinstance(patterns, str):
        patterns = [patterns]
    return any(isinstance(pattern, str) and fnmatch.fnmatchcase(value, pattern) for pattern in patterns)

def leaf_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from leaf_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from leaf_strings(item)

def resource_manifest(bundle, info_path, executable, embedded_profile):
    result = {}
    for path in sorted(bundle.rglob('*')):
        relative = path.relative_to(bundle)
        if '_CodeSignature' in relative.parts or path in [info_path, executable, embedded_profile]:
            continue
        if path.is_file():
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            result[str(relative)] = digest.hexdigest()
    return result

def verify_signature(bundle, entitlements, identity, embedded_profile, profile_bytes):
    if not embedded_profile.exists() or embedded_profile.read_bytes() != profile_bytes:
        return False
    if run(['codesign', '--verify', '--deep', '--strict', str(bundle)], 'verify.log', check=False):
        return False
    if run(['codesign', '-d', '--entitlements', ':-', str(bundle)], 'codesign.log', proof / 'signed-entitlements.plist', check=False):
        return False
    try:
        actual = plistlib.loads((proof / 'signed-entitlements.plist').read_bytes())
    except Exception:
        return False
    if actual != entitlements:
        return False
    if run(['codesign', '-d', '--extract-certificates=' + str(proof / 'signed-certificate-'), str(bundle)], 'certificate-extract.log', check=False):
        return False
    certificate = proof / 'signed-certificate-0'
    if not certificate.exists() or hashlib.sha1(certificate.read_bytes()).hexdigest().upper() != identity:
        return False
    run(['codesign', '-d', '--verbose=4', str(bundle)], 'signature-details.log')
    if not re.search(r'flags=0x[0-9a-fA-F]+\([^\n]*runtime', (proof / 'signature-details.log').read_text(errors='replace')):
        return False
    return True

try:
    app = pathlib.Path(args.app).resolve()
    profile_path = pathlib.Path(args.profile).resolve()
    entitlements_path = pathlib.Path(args.entitlements).resolve()
    require(app.is_dir() and app.suffix == '.app', 'Compiled app bundle is missing')
    require(profile_path.is_file() and entitlements_path.is_file(), 'Prepared profile or entitlements are missing')
    identity = pathlib.Path(args.identity_file).read_text().strip().upper()
    require(bool(re.fullmatch(r'[0-9A-F]{40}', identity)), 'Identity file must contain one development certificate SHA1')
    run(['security', 'find-identity', '-v', '-p', 'codesigning'], 'identities.log', proof / 'identities.txt')
    valid_development = set(re.findall(r'([0-9A-F]{40})\s+"Apple Development:[^\n]+"', (proof / 'identities.txt').read_text()))
    require(identity in valid_development, 'The specified existing Apple Development private identity is not valid locally')
    run(['security', 'cms', '-D', '-i', str(profile_path)], 'profile-decode.log', proof / 'profile.plist')
    profile = plistlib.loads((proof / 'profile.plist').read_bytes())
    profile_bytes = profile_path.read_bytes()
    entitlements = plistlib.loads(entitlements_path.read_bytes())
    require(not any('$(' in value or '*' in value for value in leaf_strings(entitlements)), 'Signing entitlements must be concrete, with no build macros or wildcards')
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    require(profile['ExpirationDate'] > now, 'Prepared provisioning profile has expired')
    require('OSX' in profile.get('Platform', []), 'Profile platform does not match the macOS app')
    certificates = {hashlib.sha1(cert).hexdigest().upper(): cert for cert in profile['DeveloperCertificates']}
    require(identity in certificates, 'The prepared profile does not include the selected existing certificate')
    (proof / 'development-certificate.der').write_bytes(certificates[identity])
    run(['openssl', 'x509', '-inform', 'DER', '-in', str(proof / 'development-certificate.der'), '-noout', '-subject', '-nameopt', 'RFC2253'], 'certificate-metadata.log', proof / 'certificate-subject.txt')
    subject = (proof / 'certificate-subject.txt').read_text().strip()
    ou = re.search(r'(?:^|,)OU=([A-Z0-9]+)(?:,|$)', subject)
    require(bool(ou) and ou.group(1) in profile['TeamIdentifier'], 'Certificate OU and profile team do not match')
    team = ou.group(1)
    require(entitlements.get('com.apple.developer.team-identifier') == team, 'Concrete entitlements use another developer team')
    info_path = app / 'Contents/Info.plist'
    info_bytes = info_path.read_bytes()
    info = plistlib.loads(info_bytes)
    expected_bundle = 'app.smail.desktop'
    require(info.get('CFBundleIdentifier') == expected_bundle, 'Unexpected Morrow bundle identifier')
    require(not args.expect_version or info.get('CFBundleShortVersionString') == args.expect_version, 'App version does not match the expected final build')
    require(not args.expect_build or str(info.get('CFBundleVersion')) == args.expect_build, 'App build number does not match the expected final build')
    application_id = profile['ApplicationIdentifierPrefix'][0] + '.' + expected_bundle
    app_id_key = 'com.apple.application-identifier'
    allowed = profile['Entitlements']
    require(allowed.get(app_id_key) == application_id, 'Cloud profile is not bound to this explicit App ID')
    require(entitlements.get(app_id_key) == application_id, 'Signing entitlements do not contain the concrete App ID')
    require(entitlements.get('com.apple.developer.icloud-container-identifiers') == [CONTAINER], 'Signing entitlements do not select the shared container exactly')
    require(CONTAINER in allowed.get('com.apple.developer.icloud-container-identifiers', []), 'Apple profile does not explicitly authorize the shared container')
    require(entitlements.get('com.apple.developer.icloud-services') == ['CloudKit'], 'Signing entitlements must select CloudKit')
    require(profile_allows(allowed.get('com.apple.developer.icloud-services', []), 'CloudKit'), 'Apple profile does not authorize CloudKit')
    require(entitlements.get('com.apple.developer.icloud-container-environment') == args.cloud_environment, 'Signing entitlements must use the selected cloud environment')
    require(profile_allows(allowed.get('com.apple.developer.icloud-container-environment', []), args.cloud_environment), 'Apple profile does not authorize the selected cloud environment')
    task_key = 'com.apple.security.get-task-allow'
    # macOS development profiles may omit this unrestricted entitlement.
    if task_key in allowed:
        require(bool(entitlements.get(task_key)) == bool(allowed.get(task_key)), 'Task entitlement does not match the development profile')
    for group in entitlements.get('keychain-access-groups', []):
        require(profile_allows(allowed.get('keychain-access-groups', []), group), 'Apple profile does not authorize a requested Keychain group')
    run(['system_profiler', 'SPHardwareDataType', '-xml'], 'hardware.log', proof / 'hardware.plist')
    hardware = plistlib.loads((proof / 'hardware.plist').read_bytes())[0]['_items'][0]
    device_udid = hardware.get('provisioning_UDID') or hardware.get('platform_UUID')
    require(device_udid in profile.get('ProvisionedDevices', []), 'Target device is absent from the Apple development profile')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    require(executable.is_file(), 'Compiled app executable is missing')
    with executable.open('rb') as stream:
        magic = stream.read(4)
    require(magic in [b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'], 'Compiled app executable is not Mach-O')
    for path in app.rglob('*'):
        require(not (path.is_symlink() and not path.resolve().is_relative_to(app)), 'App contains a symlink outside its bundle')
        require(path.suffix not in ['.framework', '.dylib', '.appex', '.xpc', '.app'], 'Nested executable code needs its own signing plan before this app can be signed')
    summary = {'platform': args.platform, 'bundleIdentifier': expected_bundle,
               'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
               'existingCertificateVerified': True, 'explicitCloudProfileVerified': True,
               'targetDeviceInProfile': True, 'cloudContainer': CONTAINER, 'cloudEnvironment': args.cloud_environment,
               'appPath': str(app), 'checkedOnly': args.check, 'signed': False,
               'cloudOptInPerformed': False}
    (proof / 'profile-uuid.txt').write_text(profile['UUID'] + '\n')
    if args.check:
        summary['readyToSign'] = True
    else:
        if args.output:
            output = pathlib.Path(args.output).resolve()
            require(not output.exists(), 'Clone destination already exists; use its app path for repeated in-place signing')
            require(output.suffix == '.app' and output.parent.is_dir(), 'Clone destination must be a new .app under an existing folder')
            run(['cp', '-cR', str(app), str(output)], 'clone.log')
            app = output
            info_path = app / 'Contents/Info.plist'
            executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
            summary['appPath'] = str(app)
        embedded_profile = app / 'Contents/embedded.provisionprofile'
        already_signed = info.get('MorrowCloudKitContainer') == CONTAINER and info.get('MorrowCloudKitEnvironment') == args.cloud_environment and verify_signature(app, entitlements, identity, embedded_profile, profile_bytes)
        if not already_signed:
            before_resources = resource_manifest(app, info_path, executable, embedded_profile)
            original_info = copy.deepcopy(info)
            info['MorrowCloudKitContainer'] = CONTAINER
            info['MorrowCloudKitEnvironment'] = args.cloud_environment
            info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY if info_bytes.startswith(b'bplist00') else plistlib.FMT_XML, sort_keys=False))
            embedded_profile.write_bytes(profile_bytes)
            (proof / 'signing-entitlements.plist').write_bytes(plistlib.dumps(entitlements))
            command = ['codesign', '--force', '--sign', identity, '--timestamp=none', '--entitlements', str(proof / 'signing-entitlements.plist')]
            command += ['--options', 'runtime']
            run(command + [str(app)], 'signing.log')
            require(verify_signature(app, entitlements, identity, embedded_profile, profile_bytes), 'Signed app failed signature/profile/entitlement/certificate verification')
            after_info = plistlib.loads(info_path.read_bytes())
            original_info.pop('MorrowCloudKitContainer', None)
            after_info.pop('MorrowCloudKitContainer', None)
            original_info.pop('MorrowCloudKitEnvironment', None)
            after_info.pop('MorrowCloudKitEnvironment', None)
            require(after_info == original_info, 'Signing changed unrelated Info.plist values')
            require(resource_manifest(app, info_path, executable, embedded_profile) == before_resources, 'Signing changed a bundled resource')
        summary.update({'signed': True, 'signatureVerified': True, 'idempotentNoOp': already_signed,
                        'oauthURLTypesAndResourcesPreserved': True})
    (proof / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    print('Private signing receipt: ' + str(proof))
except Exception as error:
    (proof / 'failure.txt').write_text(type(error).__name__ + ': ' + str(error) + '\n')
    print('Signing failed: ' + str(error), file=sys.stderr)
    print('Private signing receipt: ' + str(proof), file=sys.stderr)
    sys.exit(1)
PY
