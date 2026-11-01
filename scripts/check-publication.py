#!/usr/bin/env python3
"""Check the complete Git index or an explicit proposed publication list.

Default mode reads staged bytes using git show, not newer worktree files. A
successful scan does not prove image pixels are private-free: raster assets
must have a review-pinned SHA256 in the publication allowlist. Findings never
include matching values, only filename, line and category. No files are changed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import sys
import zlib

FORBIDDEN_ROOTS = {
    "evidence", "output", ".hallmark", "dist", ".git", ".swiftpm", ".local",
    "tmp", "node_modules", ".asc", ".claude", ".codex", "private", "__pycache__",
}
FORBIDDEN_COMPONENT_SUFFIXES = (".app", ".xcresult", ".xcodeproj", ".xcworkspace", ".xcuserdatad")
FORBIDDEN_SUFFIXES = {
    ".sqlite", ".sqlite3", ".db", ".db-wal", ".db-shm", ".sqlite-wal", ".sqlite-shm",
    ".log", ".ips", ".eml", ".mbox", ".ics", ".p12", ".p8", ".pem", ".key",
    ".mobileprovision", ".provisionprofile", ".dmg", ".ipa", ".zip", ".safetensors",
    ".metallib", ".o", ".a", ".dylib", ".pdf", ".mov", ".mp4", ".mp3", ".wav",
}
RASTER_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".icns", ".ico"}
SAFE_LITERAL_VALUES = {"secret", "password", "testpass", "fixturepass", "test-secret", "fixture-secret", "access_token", "refresh_token", "id_token", "client_secret", "api_key", "bearer"}
EMAIL = re.compile(r"(?<![\w.+-])[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
VALUE_ASSIGNMENT = re.compile(
    r"(?i)\b(?:client[_-]?secret|api[_-]?key|access[_-]?token|refresh[_-]?token|password|authorization)"
    r"[\"']?\s*[:=]\s*[\"']([^\"'\r\n]{6,})[\"']"
)
UNQUOTED_CONFIG_SECRET = re.compile(r"(?i)^\s*(?:export\s+)?(?:[A-Z0-9_]*(?:API_KEY|CLIENT_SECRET|ACCESS_TOKEN|REFRESH_TOKEN|PASSWORD))\s*[:=]\s*([^\s#\"',}{]{6,})")
PATTERNS = {
    "private-key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "provider-secret": re.compile(r"\b(?:GOCSPX-[A-Za-z0-9_-]{12,}|ya29\.[A-Za-z0-9._-]{20,}|gh[pousr]_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{30,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,})\b"),
    "jwt-token": re.compile(r"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"),
    "aws-access-key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "personal-local-path": re.compile(r"(?:/Users/[\w.-]+/|/var/folders/[\w-]+/[\w-]+/|[A-Z]:\\Users\\[\w.-]+\\)"),
    "personal-google-client": re.compile(r"\b\d{8,}-[a-z0-9]{12,}\.apps\.googleusercontent\.com\b", re.I),
    "personal-google-ios-scheme": re.compile(r"\bcom\.googleusercontent\.apps\.\d{8,}-[a-z0-9]{12,}\b", re.I),
    "personal-cloud-project": re.compile(r"\b(?:smail|morrow)[-_]native[-_][a-z0-9_-]*20\d{6}\b", re.I),
    "personal-signing-id": re.compile(r"(?:\b(?:DEVELOPMENT_TEAM|teamID|teamIdentifier|TeamIdentifierPrefix)\b\s*(?:[:=]|==)\s*[\"']?([A-Z0-9]{10})\b|\b[A-Z0-9]{10}\.(?:app|iCloud)\.)"),
    "personal-device-or-profile": re.compile(r"(?i)\b(?:device|udid|profile[_-]?uuid|provisioning[_-]?profile)\b\s*[:=]\s*[\"']?[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b"),
    "credential-url": re.compile(r"\b(?:https?|postgres(?:ql)?|redis|smtps?|imaps?)://[^\s/\"']+:[^\s/@\"']+@[^\s/\"']+", re.I),
    "bearer-token": re.compile(r"(?i)\bBearer[ \t]+([A-Za-z0-9._-]{16,})"),
    "oauth-callback-secret": re.compile(r"(?i)[?&](?:code|access_token|refresh_token|id_token|client_secret|sig)=([A-Za-z0-9._%+-]{20,})"),
    "unreviewed-embedded-binary": re.compile(r"data:(?:image|application)/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]{1024,}", re.I),
}


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL)


def safe_literal(value: str) -> bool:
    lowered = value.lower()
    return (
        lowered in SAFE_LITERAL_VALUES
        or lowered.startswith(("fixture", "test-", "test_", "demo-", "dummy", "example", "synthetic", "your_", "<"))
        or "$(" in value or "${" in value or "\\(" in value or "{{" in value
    )


def safe_email(value: str, public: set[str]) -> bool:
    lower = value.lower()
    domain = lower.rsplit("@", 1)[1]
    return lower == "unknown@invalid.local" or lower.endswith("@2x.png") or lower in public or domain in {"example.com", "example.org", "example.net"} or domain.endswith((".invalid", ".test", ".localhost", ".example"))


def path_category(path: str, policy: dict) -> str | None:
    p = PurePosixPath(path)
    if p.is_absolute() or ".." in p.parts or "\\" in path or any(ord(character) < 32 for character in path):
        return "unsafe-path"
    if not p.parts:
        return "unsafe-path"
    if any(part.lower() in FORBIDDEN_ROOTS or part.lower().startswith(".build") for part in p.parts):
        return "runtime-or-evidence-path"
    if any(part.endswith(FORBIDDEN_COMPONENT_SUFFIXES) for part in p.parts):
        return "generated-or-user-state-path"
    if p.name.lower() in {".env", ".env.local", ".env.production", "oauth-clients.json", "credentials.json", "tokens.json", "auth.json"}:
        return "personal-configuration"
    if p.suffix.lower() in FORBIDDEN_SUFFIXES or p.name.lower().endswith((".sqlite-wal", ".sqlite-shm", ".db-wal", ".db-shm")):
        return "runtime-or-sensitive-file"
    if p.suffix.lower() in RASTER_SUFFIXES:
        reviewed_location = path.startswith("assets/") or path.startswith("website/assets/")
        if not reviewed_location or path not in policy.get("reviewed_assets", {}):
            return "unreviewed-binary-asset"
        return None
    allowed = path in policy["allowed_exact"] or any(path.startswith(tree) for tree in policy["allowed_trees"])
    if not allowed:
        return "outside-public-allowlist"
    if p.suffix.lower() == ".conf" and path not in policy["allowed_exact"]:
        return "unapproved-configuration-file"
    if p.suffix.lower() not in policy["text_suffixes"] and p.name not in {"LICENSE", "NOTICE", ".gitignore", ".gitattributes", "Dockerfile", ".dockerignore"}:
        return "unapproved-file-type"
    return None


def findings_for_text(path: str, text: str, policy: dict) -> list[dict]:
    findings: set[tuple[int, str]] = set()
    public_emails = set(policy.get("public_service_emails", []))
    for number, line in enumerate(text.splitlines(), 1):
        for match in EMAIL.finditer(line):
            if not safe_email(match.group(), public_emails):
                findings.add((number, "private-email"))
        for match in VALUE_ASSIGNMENT.finditer(line):
            if not safe_literal(match.group(1)):
                findings.add((number, "literal-credential"))
        for match in UNQUOTED_CONFIG_SECRET.finditer(line):
            if not safe_literal(match.group(1)):
                findings.add((number, "unquoted-config-credential"))
        for category, pattern in PATTERNS.items():
            for match in pattern.finditer(line):
                value = match.group()
                if category in {"bearer-token", "oauth-callback-secret"} and safe_literal(match.group(1)):
                    continue
                if category == "credential-url" and ("example." in value or "\\(" in value or "${" in value):
                    continue
                if category == "aws-access-key" and value.endswith("EXAMPLE"):
                    continue
                findings.add((number, category))
    return [{"filename": path, "line": line, "category": category} for line, category in sorted(findings)]


def png_text(data: bytes) -> list[str]:
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return []
    offset = 8; result = []
    while offset + 12 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        if offset + 12 + length > len(data):
            break
        payload = data[offset + 8:offset + 8 + length]
        if kind == b"tEXt":
            result.append(payload.decode("latin-1", errors="replace"))
        elif kind == b"zTXt":
            parts = payload.split(b"\x00", 1)
            if len(parts) == 2 and parts[1].startswith(b"\x00"):
                decoder = zlib.decompressobj(); decoded = decoder.decompress(parts[1][1:], 1024 * 1024)
                result.append(decoded.decode("utf-8", errors="replace"))
        elif kind == b"iTXt":
            parts = payload.split(b"\x00", 1)
            if len(parts) != 2 or len(parts[1]) < 2:
                raise ValueError("Malformed PNG textual metadata")
            keyword, rest = parts
            compression, method = rest[0], rest[1]
            translated = rest[2:].split(b"\x00", 2)
            if len(translated) != 3:
                raise ValueError("Malformed PNG international text")
            language, title, value = translated
            if compression:
                if compression != 1 or method != 0:
                    raise ValueError("Unsupported PNG textual compression")
                decoder = zlib.decompressobj(); value = decoder.decompress(value, 1024 * 1024)
                if decoder.unconsumed_tail:
                    raise ValueError("Oversized PNG textual metadata")
            result.append(b"\x00".join([keyword, language, title, value]).decode("utf-8", errors="replace"))
        elif kind == b"eXIf":
            result.append("PUBLICATION_EXIF_METADATA_PRESENT")
        offset += length + 12
    return result


def webp_text(data: bytes) -> list[str]:
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return []
    offset = 12; result = []
    while offset + 8 <= len(data):
        kind = data[offset:offset + 4]
        length = struct.unpack_from("<I", data, offset + 4)[0]
        if offset + 8 + length > len(data):
            raise ValueError("Malformed WebP metadata")
        payload = data[offset + 8:offset + 8 + length]
        if kind == b"EXIF":
            result.append("PUBLICATION_EXIF_METADATA_PRESENT")
        elif kind == b"XMP ":
            result.append(payload.decode("utf-8", errors="replace"))
        offset += 8 + length + (length % 2)
    return result


def scan_bytes(path: str, data: bytes, policy: dict) -> list[dict]:
    category = path_category(path, policy)
    if category:
        return [{"filename": path, "line": 0, "category": category}]
    p = PurePosixPath(path)
    if p.suffix.lower() in RASTER_SUFFIXES:
        expected = policy["reviewed_assets"][path]
        if not re.fullmatch(r"[a-f0-9]{64}", expected) or hashlib.sha256(data).hexdigest() != expected:
            return [{"filename": path, "line": 0, "category": "asset-review-hash-mismatch"}]
        if b"Exif\x00\x00" in data:
            return [{"filename": path, "line": 0, "category": "image-exif-metadata"}]
        results = []
        for value in png_text(data) + webp_text(data):
            if "PUBLICATION_EXIF_METADATA_PRESENT" in value:
                results.append({"filename": path, "line": 0, "category": "image-exif-metadata"})
            else:
                results.extend(findings_for_text(path, value, policy))
        return results
    if len(data) > 5 * 1024 * 1024:
        return [{"filename": path, "line": 0, "category": "oversized-source-or-runtime-payload"}]
    if b"\x00" in data:
        return [{"filename": path, "line": 0, "category": "unexpected-binary-content"}]
    return findings_for_text(path, data.decode("utf-8", errors="replace"), policy)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--allowlist", type=Path, help="Publication policy; default configuration/publication-allowlist.json")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--staged", action="store_true", help="Check complete Git index (default)")
    mode.add_argument("--worktree", action="store_true", help="Preflight only paths admitted by the allowlist, before staging")
    mode.add_argument("--candidate-list", type=Path, help="Explicit proposed paths, one repository-relative path per line")
    args = parser.parse_args()
    root = args.root.resolve()
    policy_path = args.allowlist or root / "configuration/publication-allowlist.json"
    try:
        if not args.worktree and not args.candidate_list and not args.allowlist:
            # The committed gate must use the same policy bytes as this check.
            # A newer permissive worktree policy cannot approve an older index.
            policy = json.loads(git(root, "show", ":configuration/publication-allowlist.json"))
        else:
            policy = json.loads(policy_path.read_text())
        for key in ("allowed_exact", "allowed_trees", "text_suffixes", "reviewed_assets"):
            if key not in policy:
                raise ValueError("Incomplete publication allowlist")
        index = {}
        if args.candidate_list:
            paths = [x.strip() for x in args.candidate_list.read_text().splitlines() if x.strip()]
        elif args.worktree:
            all_paths = set(git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").decode().split("\x00"))
            paths = sorted(p for p in all_paths if p and path_category(p, policy) is None)
        else:
            for item in git(root, "ls-files", "--stage", "-z").split(b"\x00"):
                if not item:
                    continue
                metadata, name = item.split(b"\t", 1)
                file_mode, _, stage = metadata.decode().split()
                path = name.decode(); index[path] = (file_mode, stage)
            paths = sorted(index)
        if not paths:
            print(json.dumps({"files": 0, "findings": 0, "category": "no-publication-files-selected"}))
            return 2
        findings = []
        for path in paths:
            reason = path_category(path, policy)
            if reason:
                findings.append({"filename": path, "line": 0, "category": reason}); continue
            if not args.worktree and not args.candidate_list:
                file_mode, stage = index[path]
                if file_mode == "120000" or stage != "0":
                    findings.append({"filename": path, "line": 0, "category": "symlink-or-unresolved-index-entry"}); continue
                data = git(root, "show", ":" + path)
            else:
                source = root / path
                if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(root):
                    findings.append({"filename": path, "line": 0, "category": "unsafe-or-missing-worktree-file"}); continue
                data = source.read_bytes()
            findings.extend(scan_bytes(path, data, policy))
        for finding in findings:
            print(json.dumps(finding, ensure_ascii=False))
        print(json.dumps({"files": len(paths), "findings": len(findings), "mode": "worktree" if args.worktree else "candidate" if args.candidate_list else "index"}))
        return 1 if findings else 0
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError, UnicodeError, zlib.error):
        print(json.dumps({"filename": str(policy_path.relative_to(root)) if policy_path.is_relative_to(root) else "publication-policy", "line": 0, "category": "publication-check-unavailable"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
