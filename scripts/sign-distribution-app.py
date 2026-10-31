#!/usr/bin/env python3
"""Verify or Developer-ID-sign an already compiled Morrow macOS application.

No build, provisioning update, certificate creation, app clone, or app backup is
performed. --check validates prepared inputs without editing the application.
Only an existing Developer ID Application private identity and an unrestricted
Production CloudKit provisioning profile are accepted. Notarization is separate.
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import uuid

BUNDLE_ID = "app.smail.desktop"
CONTAINER = "iCloud.app.smail.workspace"
MACHO_MAGICS = {bytes.fromhex(value) for value in ["feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]}
NESTED_CODE_SUFFIXES = {".app", ".framework", ".dylib", ".so", ".xpc", ".appex", ".plugin"}


class SigningFailure(Exception):
    pass


def require(condition: bool, category: str) -> None:
    if not condition:
        raise SigningFailure(category)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def permits(allowed: object, value: str) -> bool:
    values = [allowed] if isinstance(allowed, str) else allowed
    return isinstance(values, list) and any(isinstance(item, str) and fnmatch.fnmatchcase(value, item) for item in values)


def concrete(value: object) -> bool:
    if isinstance(value, str):
        return not any(marker in value for marker in ("$(", "${", "*", "?"))
    if isinstance(value, dict):
        return all(concrete(item) for item in value.values())
    if isinstance(value, list):
        return all(concrete(item) for item in value)
    return True


def inspect_code(bundle: Path, executable: Path) -> None:
    require(not bundle.is_symlink() and not executable.is_symlink(), "symlink-app-or-main-executable")
    require(executable.is_file(), "missing-main-executable")
    require(bool(executable.stat().st_mode & stat.S_IXUSR), "main-executable-not-executable")
    with executable.open("rb") as source:
        require(source.read(4) in MACHO_MAGICS, "main-executable-not-mach-o")
    for path in bundle.rglob("*"):
        if path.is_symlink():
            require(path.resolve().is_relative_to(bundle), "symlink-outside-app")
        if path.suffix.lower() in NESTED_CODE_SUFFIXES:
            raise SigningFailure("nested-code-needs-separate-signing-plan")
        if path.is_dir() and path.suffix == ".bundle":
            for info in (path / "Info.plist", path / "Contents/Info.plist"):
                if info.is_file():
                    require(not plistlib.loads(info.read_bytes()).get("CFBundleExecutable"), "nested-executable-bundle")
        if path.is_file() and path.resolve() != executable:
            with path.open("rb") as source:
                magic = source.read(4)
            require(magic not in MACHO_MAGICS and magic != b"\x7fELF" and not magic.startswith(b"#!"), "nested-executable-file")


def resources(bundle: Path, info: Path, executable: Path, embedded: Path) -> dict[str, str]:
    result = {}
    for path in sorted(bundle.rglob("*")):
        relative = path.relative_to(bundle)
        if path in {info, executable, embedded} or "_CodeSignature" in relative.parts:
            continue
        if path.is_symlink():
            result[str(relative)] = "link:" + os.readlink(path)
        elif path.is_file():
            result[str(relative)] = sha256(path)
    return result


def entitlement_set(profile: dict, selected_identity: str) -> tuple[dict, bytes, str]:
    require(isinstance(profile, dict), "profile-not-a-dictionary")
    require(profile.get("ProvisionsAllDevices") is True and not profile.get("ProvisionedDevices"), "profile-has-device-restrictions")
    platform = profile.get("Platform")
    require(isinstance(platform, list) and "OSX" in platform, "profile-not-macos")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, dt.datetime), "profile-expiration-missing")
    expires_at = expiry.replace(tzinfo=dt.timezone.utc) if expiry.tzinfo is None else expiry.astimezone(dt.timezone.utc)
    require(expires_at > dt.datetime.now(dt.timezone.utc), "profile-expired")
    teams, prefixes, certificates = profile.get("TeamIdentifier"), profile.get("ApplicationIdentifierPrefix"), profile.get("DeveloperCertificates")
    require(isinstance(teams, list) and len(teams) == 1 and isinstance(teams[0], str), "profile-team-missing-or-ambiguous")
    require(isinstance(prefixes, list) and len(prefixes) == 1 and isinstance(prefixes[0], str), "profile-app-prefix-missing-or-ambiguous")
    require(isinstance(certificates, list) and certificates and all(isinstance(item, bytes) for item in certificates), "profile-certificates-missing")
    matching = [item for item in certificates if hashlib.sha1(item).hexdigest().upper() == selected_identity]
    require(len(matching) == 1, "selected-certificate-not-in-profile")
    allowed = profile.get("Entitlements")
    require(isinstance(allowed, dict), "profile-entitlements-missing")
    app_id = prefixes[0] + "." + BUNDLE_ID
    require(allowed.get("com.apple.application-identifier") == app_id, "profile-not-explicit-app-id")
    require(allowed.get("com.apple.developer.team-identifier") == teams[0], "profile-team-entitlement-mismatch")
    require(allowed.get("com.apple.developer.icloud-container-environment") in ("Production", ["Production"]), "profile-not-production-cloud")
    containers = allowed.get("com.apple.developer.icloud-container-identifiers")
    require(isinstance(containers, list) and CONTAINER in containers and all(isinstance(item, str) and "*" not in item for item in containers), "profile-explicit-cloud-container-missing")
    require(permits(allowed.get("com.apple.developer.icloud-services"), "CloudKit"), "profile-cloudkit-service-missing")
    require(not allowed.get("com.apple.security.get-task-allow") and not allowed.get("get-task-allow"), "profile-allows-debug-task-access")
    entitlements = {
        "com.apple.application-identifier": app_id,
        "com.apple.developer.team-identifier": teams[0],
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": "Production",
    }
    # The desktop client uses CloudKit, not ubiquity documents/KV. Do not add
    # optional Keychain groups or copy a profile's broader permission set: the
    # existing login Keychain service namespace must retain its behavior.
    require(concrete(entitlements), "selected-entitlements-not-concrete")
    return entitlements, matching[0], teams[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Already compiled Morrow .app; modified in place only after successful preflight")
    parser.add_argument("--profile", type=Path, required=True, help="Prepared unrestricted Developer ID Production CloudKit CMS profile")
    parser.add_argument("--identity-file", type=Path, required=True, help="Private file containing one existing Developer ID Application certificate SHA1")
    parser.add_argument("--check", action="store_true", help="Read-only input/signature preflight; never signs, copies or edits the app")
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parent.parent
    evidence: Path | None = None
    summary = {"schemaVersion": 1, "checkedOnly": args.check, "readyToSign": False, "signed": False, "distributionSignatureVerified": False, "notarizationVerified": False, "appCopiedOrBackedUp": False, "appModified": False}
    try:
        require(sys.platform == "darwin", "macos-required")
        evidence_base = root / ".local/evidence/private"
        evidence_base.mkdir(parents=True, exist_ok=True, mode=0o700)
        require(evidence_base.resolve().is_relative_to(root / ".local"), "evidence-directory-outside-local-root")
        evidence = evidence_base / ("distribution-sign-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])
        evidence.mkdir(mode=0o700)
        require(not args.app.expanduser().is_symlink(), "symlink-app")
        bundle = args.app.expanduser().resolve()
        profile_path = args.profile.expanduser().resolve()
        identity_path = args.identity_file.expanduser().resolve()
        require(bundle.is_dir() and bundle.suffix == ".app", "compiled-app-missing")
        require(profile_path.is_file() and identity_path.is_file(), "prepared-signing-input-missing")
        identity = identity_path.read_text().strip().upper()
        require(re.fullmatch(r"[0-9A-F]{40}", identity) is not None, "identity-file-not-single-certificate-sha1")
        info_path = bundle / "Contents/Info.plist"
        info_bytes = info_path.read_bytes(); info = plistlib.loads(info_bytes)
        require(info.get("CFBundleIdentifier") == BUNDLE_ID, "unexpected-bundle-id")
        require(isinstance(info.get("CFBundleShortVersionString"), str) and re.fullmatch(r"[0-9][0-9.]{0,31}", info["CFBundleShortVersionString"]) is not None, "app-version-missing-or-invalid")
        require(re.fullmatch(r"[0-9]{1,12}", str(info.get("CFBundleVersion", ""))) is not None, "app-build-missing-or-invalid")
        executable_name = info.get("CFBundleExecutable")
        require(isinstance(executable_name, str) and re.fullmatch(r"[A-Za-z0-9._-]+", executable_name) is not None, "invalid-main-executable-name")
        executable = bundle / "Contents/MacOS" / executable_name
        embedded = bundle / "Contents/embedded.provisionprofile"
        inspect_code(bundle, executable)
        with tempfile.TemporaryDirectory(prefix="decoded-", dir=evidence) as temporary:
            temporary = Path(temporary)
            def run(command: list[str], label: str, *, check: bool = True, timeout: int = 120) -> bytes:
                result = subprocess.run(command, capture_output=True, timeout=timeout)
                (temporary / (label + ".stdout")).write_bytes(result.stdout)
                (temporary / (label + ".stderr")).write_bytes(result.stderr)
                if check and result.returncode:
                    # These may contain personal certificate subjects. Keep them
                    # in ignored private evidence; never copy app/data contents.
                    (evidence / (label + ".stderr")).write_bytes(result.stderr)
                    raise SigningFailure("command-failed-" + label)
                return result.stdout + (result.stderr if label == "signature-details" else b"")
            identities = run(["security", "find-identity", "-v", "-p", "codesigning"], "identity-check").decode(errors="replace")
            existing = set(re.findall(r'([A-F0-9]{40})\s+"Developer ID Application:[^\n]+"', identities))
            require(identity in existing, "existing-developer-id-application-identity-unavailable")
            decoded = run(["security", "cms", "-D", "-i", str(profile_path)], "profile-cms")
            profile = plistlib.loads(decoded)
            entitlements, certificate, team = entitlement_set(profile, identity)
            certificate_file = temporary / "selected-certificate.der"; certificate_file.write_bytes(certificate)
            subject = run(["openssl", "x509", "-inform", "DER", "-in", str(certificate_file), "-noout", "-subject", "-nameopt", "RFC2253"], "certificate-subject").decode(errors="replace")
            ou = re.search(r"(?:^|,)OU=([A-Z0-9]+)(?:,|$)", subject)
            require(ou is not None and ou.group(1) == team, "certificate-team-does-not-match-profile")
            require("CN=Developer ID Application:" in subject, "profile-certificate-is-not-developer-id-application")
            run(["openssl", "x509", "-inform", "DER", "-in", str(certificate_file), "-noout", "-checkend", "0"], "certificate-expiration")
            entitlement_file = temporary / "distribution-entitlements.plist"
            entitlement_file.write_bytes(plistlib.dumps(entitlements))
            profile_bytes = profile_path.read_bytes()

            def verify() -> bool:
                if not embedded.is_file() or embedded.read_bytes() != profile_bytes:
                    return False
                actual_info = plistlib.loads(info_path.read_bytes())
                if actual_info.get("MorrowCloudKitContainer") != CONTAINER or actual_info.get("MorrowCloudKitEnvironment") != "Production":
                    return False
                result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], capture_output=True)
                (temporary / "verify.stderr").write_bytes(result.stderr)
                if result.returncode:
                    return False
                signed = run(["codesign", "-d", "--entitlements", ":-", str(bundle)], "signed-entitlements")
                try:
                    if plistlib.loads(signed) != entitlements:
                        return False
                except plistlib.InvalidFileException:
                    return False
                prefix = temporary / "signed-certificate-"
                for stale in temporary.glob("signed-certificate-*"):
                    stale.unlink()
                run(["codesign", "-d", "--extract-certificates=" + str(prefix), str(bundle)], "extract-signed-certificate")
                leaf = Path(str(prefix) + "0")
                if not leaf.is_file() or hashlib.sha1(leaf.read_bytes()).hexdigest().upper() != identity:
                    return False
                details = run(["codesign", "-d", "--verbose=4", str(bundle)], "signature-details").decode(errors="replace")
                return bool(re.search(r"flags=0x[0-9a-fA-F]+\([^\n]*runtime", details) and re.search(r"^Timestamp=(?!none|not set).+", details, re.M | re.I) and re.search(r"^Authority=Developer ID Application:", details, re.M) and re.search(r"^Authority=Developer ID Certification Authority", details, re.M) and re.search(r"^Authority=Apple Root CA", details, re.M))

            summary.update({"readyToSign": True, "existingDeveloperIDVerified": True, "profileCertificateMembershipVerified": True, "profileAllDevices": True, "profileCloudEnvironment": "Production", "explicitBundleIDVerified": True, "explicitCloudContainerVerified": True, "nestedCodeAbsent": True, "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion")})
            already_verified = verify()
            if args.check:
                summary["distributionSignatureVerified"] = already_verified
            else:
                if not already_verified:
                    running = subprocess.run(["pgrep", "-f", "^" + re.escape(str(executable)) + r"(?: |$)"], capture_output=True)
                    require(running.returncode != 0, "app-is-running")
                    before = resources(bundle, info_path, executable, embedded)
                    original_info = copy.deepcopy(info)
                    info["MorrowCloudKitContainer"] = CONTAINER; info["MorrowCloudKitEnvironment"] = "Production"
                    summary["appModified"] = True
                    info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY if info_bytes.startswith(b"bplist00") else plistlib.FMT_XML, sort_keys=False))
                    embedded.write_bytes(profile_bytes)
                    run(["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp", "--entitlements", str(entitlement_file), str(bundle)], "developer-id-sign", timeout=180)
                    require(verify(), "distribution-signature-verification-failed")
                    after_info = plistlib.loads(info_path.read_bytes())
                    for key in ("MorrowCloudKitContainer", "MorrowCloudKitEnvironment"):
                        original_info.pop(key, None); after_info.pop(key, None)
                    require(after_info == original_info and resources(bundle, info_path, executable, embedded) == before, "unrelated-resources-or-info-changed")
                summary.update({"signed": True, "distributionSignatureVerified": True, "secureTimestampVerified": True, "hardenedRuntimeVerified": True, "productionCloudVerified": True, "idempotentNoOp": already_verified})
        if evidence is not None:
            (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
        if evidence is not None:
            print("Private receipt: " + str((evidence / "summary.json").relative_to(root)))
        return 0
    except (SigningFailure, OSError, ValueError, TypeError, AttributeError, KeyError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        category = str(error) if isinstance(error, SigningFailure) else "signing-preflight-or-verification-unavailable"
        summary["failureCategory"] = category
        if evidence is not None:
            try:
                (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            except OSError:
                pass
        print(json.dumps({"category": category, "signed": False}), file=sys.stderr)
        if evidence is not None:
            print("Private receipt: " + str((evidence / "summary.json").relative_to(root)), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
