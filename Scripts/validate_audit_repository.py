#!/usr/bin/env python3
"""Fail closed if a public audit checkout contains private or unsafe material."""

from __future__ import annotations

import pathlib
import re


ROOT = pathlib.Path(__file__).resolve().parent.parent
IGNORED_PARTS = {".build", ".git", ".swiftpm", "__pycache__"}
ALLOWED_TOP_LEVEL = {
    ".github",
    ".gitignore",
    "Collector",
    "Contract",
    "CONTRIBUTING.md",
    "LICENSE",
    "Package.resolved",
    "Package.swift",
    "PRIVACY.md",
    "README.md",
    "Scripts",
    "SECURITY.md",
    "Sources",
    "Tests",
    "THIRD_PARTY.md",
}
FORBIDDEN_SUFFIXES = {
    ".a",
    ".cer",
    ".dylib",
    ".gguf",
    ".key",
    ".mobileprovision",
    ".p12",
    ".pem",
    ".so",
    ".xcarchive",
    ".xcframework",
}
FORBIDDEN_TEXT = {
    "private-key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "Alibaba access key": re.compile(r"\bLTAI[A-Za-z0-9]{12,}\b"),
    "AWS access key": re.compile(r"\bAKIA[A-Z0-9]{16}\b"),
    "private operations": re.compile(
        "(?i)(?:"
        + "|".join(
            re.escape(value)
            for value in (
                "chiboard-" + "telemetry-symbols",
                "Cloud/Alibaba/" + "ram",
                "Cloud/Alibaba/" + "sls",
                "provision" + "ing",
                "dashboard" + "_web",
            )
        )
        + ")"
    ),
    "deployment endpoint": re.compile(r"https://[^\s'\"]+\.(?:fcapp\.run|aliyuncs\.com)"),
}


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> None:
    unexpected = {path.name for path in ROOT.iterdir()} - ALLOWED_TOP_LEVEL - IGNORED_PARTS
    if unexpected:
        fail(f"Unexpected public repository path(s): {sorted(unexpected)}")

    manifest = (ROOT / "Package.swift").read_text()
    for required in (
        'exact: "1.12.2"',
        'type: .static',
        '.process("Resources/PrivacyInfo.xcprivacy")',
    ):
        if required not in manifest:
            fail(f"Package manifest is missing {required}")

    for path in ROOT.rglob("*"):
        relative = path.relative_to(ROOT)
        if any(part in IGNORED_PARTS for part in relative.parts):
            continue
        if path.is_symlink():
            fail(f"Symlinks are not permitted in the audit repository: {relative}")
        if not path.is_file():
            continue
        if path.suffix.lower() in FORBIDDEN_SUFFIXES or any(
            part.endswith((".dSYM", ".framework")) for part in relative.parts
        ):
            fail(f"Binary or private release artifact found: {relative}")
        if path.stat().st_size > 1_000_000:
            fail(f"Unexpected large file found: {relative}")
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            fail(f"Unexpected binary file found: {relative}")
        for label, pattern in FORBIDDEN_TEXT.items():
            if pattern.search(text):
                fail(f"Potential {label} found in {relative}")

    source_modules = {
        path.name for path in (ROOT / "Sources").iterdir() if path.is_dir()
    }
    if source_modules != {"ChiboardTelemetry"}:
        fail(f"Unexpected source module(s): {sorted(source_modules)}")
    fixtures = {path.stem for path in (ROOT / "Contract" / "Fixtures").glob("*.json")}
    if fixtures != {"usage-summary", "model-load-result", "setup-milestone", "crash"}:
        fail(f"Golden payload fixture set is incomplete: {sorted(fixtures)}")

    print("Validated public audit scope, dependencies, private paths, binaries, and secrets.")


if __name__ == "__main__":
    main()
