"""Offline publication guards for the historical pod-orchestration archive.

This is NOT a deployment audit. It checks tracked public files only and
ensures high-risk historical behaviours are conspicuously disclosed.
"""
from __future__ import annotations

from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

# Construct PEM markers rather than placing a complete key-header substring
# in the test itself. The synthetic tests use no genuine private material.
KEY_KINDS = (b"OPENSSH", b"RSA", b"EC", b"DSA")
TOKEN_PATTERN = re.compile(
    rb"\b(?:gh[pousr]_[A-Za-z0-9_]{25,}|github_pat_[A-Za-z0-9_]{35,}|"
    rb"hf_[A-Za-z0-9]{24,}|sk-[A-Za-z0-9_-]{28,}|AKIA[0-9A-Z]{16})\b"
)


def has_credential_shape(data: bytes) -> bool:
    for kind in KEY_KINDS:
        if b"-----BEGIN " + kind + b" PRIVATE KEY-----" in data:
            return True
    return bool(TOKEN_PATTERN.search(data))


class PublicationSafetyTests(unittest.TestCase):
    def test_detector_recognises_synthetic_examples(self):
        secret = b"hf_" + b"x" * 30
        self.assertTrue(has_credential_shape(secret))
        self.assertTrue(has_credential_shape(b"-----BEGIN " + b"OPENSSH" + b" PRIVATE KEY-----"))
        self.assertFalse(has_credential_shape(b"HF_TOKEN=placeholder"))
        self.assertFalse(has_credential_shape(b"ssh-ed25519 AAAAexample-public-key"))

    def test_no_obvious_credentials_in_tracked_public_files(self):
        names = subprocess.run(
            ["git", "ls-files", "-z"], cwd=ROOT, capture_output=True,
            check=True, timeout=10,
        ).stdout.split(b"\0")
        self.assertGreater(len(names), 15)
        flagged = []
        for encoded in names:
            if not encoded:
                continue
            relpath = Path(encoded.decode("utf-8", "surrogateescape"))
            path = ROOT / relpath
            if path.is_symlink():
                flagged.append(relpath.as_posix() + ": symlink")
                continue
            if not path.is_file():
                flagged.append(relpath.as_posix() + ": missing")
                continue
            if has_credential_shape(path.read_bytes()):
                # Path only. Never print a matching credential.
                flagged.append(relpath.as_posix() + ": private material")
        self.assertEqual(flagged, [], "Review tracked publication inputs")

    def test_historical_risks_are_documented_without_a_false_safe_claim(self):
        docs = (ROOT / "docs" / "SECURITY_BOUNDARIES.md").read_text()
        readme = (ROOT / "README.md").read_text()
        runpod = (ROOT / "RUNPOD.md").read_text()
        main = (ROOT / "osf_pod_link" / "osf-main-up").read_text()
        bootstrap = (ROOT / "community_worker" / "print-b300-worker-bootstrap-b64").read_text()
        direct = (ROOT / "community_worker" / "print-b300-worker-bootstrap").read_text()
        if "chmod -R 777 /workspace/_h200_writeback" in main:
            self.assertIn("world-writable", docs)
            self.assertIn("chmod -R 777", readme)
        if 'if [ ! -s "$KEY" ]' in bootstrap and direct:
            self.assertIn("reused", docs.lower())
            self.assertIn("successive workers", runpod)
        if 'KEY_B64="$(base64 -w0 "$KEY")"' in bootstrap:
            self.assertIn("Base64 is only an encoding", docs)
        self.assertIn("not a hardened", docs)
        self.assertIn("does not assess or modify", docs)


if __name__ == "__main__":
    unittest.main()
