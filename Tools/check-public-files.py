#!/usr/bin/env python3
"""Check publishable files for local paths and common credential formats."""
from pathlib import Path
import os
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
patterns = [
    re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
    re.compile(r"/(?:var/folders|private/tmp)/"),
    re.compile(r"(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{30,}"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
]
excluded = {"outputs", ".build", ".captures", ".swiftpm", "dist", ".git"}
repository = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=root, capture_output=True)
if repository.returncode == 0 and Path(repository.stdout.decode().strip()).resolve() == root:
    paths = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root, check=True, capture_output=True,
    ).stdout.split(b"\0")
else:
    paths = []
    for directory, directories, files in os.walk(root):
        directories[:] = [name for name in directories if name not in excluded]
        paths.extend(os.fsencode((Path(directory) / name).relative_to(root)) for name in files)
assert patterns[0].search("/" + "Users/example/project")
assert not any(pattern.search("https://example.com/project") for pattern in patterns)
failed = []
for item in paths:
    if not item:
        continue
    path = Path(item.decode())
    if path.parts[0] in excluded or path.name.startswith(".env") or path.suffix in {".p12", ".p8", ".keychain-db", ".mobileprovision"}:
        failed.append(str(path))
        continue
    full = root / path
    if not full.is_file():
        continue
    text = full.read_bytes().decode("utf-8", errors="ignore")
    for number, line in enumerate(text.splitlines(), 1):
        if any(pattern.search(line) for pattern in patterns):
            failed.append(f"{path}:{number}")
if failed:
    print("Review possible private content in:\n" + "\n".join(failed))
    sys.exit(1)
print("Public file checks passed; manually review attribution and commit identity.")
