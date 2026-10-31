#!/usr/bin/env python3
"""Synthetic publication-gate tests. Does not stage the application workspace."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("publication", ROOT / "scripts/check-publication.py")
publication = importlib.util.module_from_spec(spec); spec.loader.exec_module(publication)
POLICY = json.loads((ROOT / "configuration/publication-allowlist.json").read_text())


class PublicationGateTests(unittest.TestCase):
    def testReservedFixturesRemainAllowedAndValuesNeverAppearInFindings(self):
        self.assertEqual(publication.findings_for_text("Sources/Test.swift", 'let token = "fixture-token"; let email = "me@example.invalid"', POLICY), [])
        private_address = "person" + "@gmail.com"
        found = publication.findings_for_text("Sources/Test.swift", private_address, POLICY)
        self.assertEqual(found[0]["category"], "private-email")
        self.assertNotIn(private_address, json.dumps(found))
        synthetic_secret = "opaque-" + "A" * 32
        for value in ['{"refresh_token":"' + synthetic_secret + '"}', "API_KEY: " + synthetic_secret]:
            found = publication.findings_for_text("configuration/example.json", value, POLICY)
            self.assertTrue(found)
            self.assertNotIn(synthetic_secret, json.dumps(found))

    def testEvidenceAndSigningNeverPassEvenWithReviewedAssetEntries(self):
        policy = dict(POLICY); policy["reviewed_assets"] = {"evidence/screenshot.png": "0" * 64}
        self.assertEqual(publication.path_category("evidence/screenshot.png", policy), "runtime-or-evidence-path")
        self.assertEqual(publication.path_category("website/.hallmark/results.json", policy), "runtime-or-evidence-path")
        self.assertEqual(publication.path_category("Sources/private/account.json", policy), "runtime-or-evidence-path")
        self.assertEqual(publication.path_category("Tests/output/state.json", policy), "runtime-or-evidence-path")
        self.assertEqual(publication.path_category("website/Evidence/state.json", policy), "runtime-or-evidence-path")
        self.assertEqual(publication.path_category("Sources/token.p12", policy), "runtime-or-sensitive-file")
        self.assertEqual(publication.path_category("configuration/oauth-clients.json", policy), "personal-configuration")
        self.assertEqual(publication.path_category("../private.swift", policy), "unsafe-path")
        self.assertEqual(publication.path_category("Sources/unsafe\nfile.swift", policy), "unsafe-path")
        self.assertIsNone(publication.path_category("website/deploy/nginx.conf", POLICY))
        self.assertEqual(publication.path_category("website/deploy/personal.conf", POLICY), "unapproved-configuration-file")
        self.assertIsNone(publication.path_category("iOS/MorrowMobile/Resources/Notices/MLX-LICENSE", POLICY))
        self.assertEqual(publication.path_category("docs/public/personal-LICENSE", POLICY), "unapproved-file-type")

    def testIndexBytesAreCheckedInsteadOfSanitizedWorktree(self):
        with tempfile.TemporaryDirectory(prefix="publication-index-") as folder:
            root = Path(folder); (root / "Sources").mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            source = root / "Sources/Test.swift"
            synthetic_secret = "sk-" + "A" * 32
            source.write_text('let key = "' + synthetic_secret + '"\n')
            subprocess.run(["git", "-C", str(root), "add", "Sources/Test.swift"], check=True)
            source.write_text('let key = "fixture-key"\n')
            result = subprocess.run([sys.executable, str(ROOT / "scripts/check-publication.py"), "--root", str(root), "--allowlist", str(ROOT / "configuration/publication-allowlist.json"), "--staged"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("provider-secret", result.stdout)
            self.assertNotIn(synthetic_secret, result.stdout + result.stderr)

    def testCompressedPNGMetadataIsScannedAfterHashReview(self):
        def chunk(kind, value):
            return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value) & 0xffffffff)
        private_address = "person" + "@gmail.com"
        value = b"Description\x00\x01\x00\x00\x00" + zlib.compress(private_address.encode())
        data = b"\x89PNG\r\n\x1a\n" + chunk(b"iTXt", value) + chunk(b"IEND", b"")
        policy = dict(POLICY); policy["reviewed_assets"] = {"assets/brand/icon.png": hashlib.sha256(data).hexdigest()}
        found = publication.scan_bytes("assets/brand/icon.png", data, policy)
        self.assertTrue(any(x["category"] == "private-email" for x in found))
        self.assertNotIn(private_address, json.dumps(found))

    def testDefaultIndexModeUsesStagedPolicyNotNewWorktreePolicy(self):
        with tempfile.TemporaryDirectory(prefix="publication-policy-") as folder:
            root = Path(folder); (root / "configuration").mkdir(); (root / "assets/brand").mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            policy = dict(POLICY); policy["reviewed_assets"] = {}
            path = root / "configuration/publication-allowlist.json"
            path.write_text(json.dumps(policy))
            data = b"\x89PNG\r\n\x1a\n"
            asset = root / "assets/brand/preview.png"; asset.write_bytes(data)
            subprocess.run(["git", "-C", str(root), "add", "configuration/publication-allowlist.json", "assets/brand/preview.png"], check=True)
            policy["reviewed_assets"] = {"assets/brand/preview.png": hashlib.sha256(data).hexdigest()}
            path.write_text(json.dumps(policy))
            result = subprocess.run([sys.executable, str(ROOT / "scripts/check-publication.py"), "--root", str(root), "--staged"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("unreviewed-binary-asset", result.stdout)

    def testWebPExifCannotHideInReviewedRaster(self):
        payload = b"II" + b"\x00" * 8
        chunks = b"EXIF" + struct.pack("<I", len(payload)) + payload
        data = b"RIFF" + struct.pack("<I", len(chunks) + 4) + b"WEBP" + chunks
        policy = dict(POLICY); policy["reviewed_assets"] = {"website/assets/hero.webp": hashlib.sha256(data).hexdigest()}
        found = publication.scan_bytes("website/assets/hero.webp", data, policy)
        self.assertEqual(found[0]["category"], "image-exif-metadata")


if __name__ == "__main__":
    unittest.main()
