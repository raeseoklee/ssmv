"""Append verified Windows installers to an existing release; never replace assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare_assets(directory, tag, commit):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Expected a release tag such as v0.5.1")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected the full source commit")
    output = directory / "release"
    output.mkdir(exist_ok=True)
    files = []
    for architecture in ("x64", "ARM64"):
        source = directory / f"SSMV-windows-{architecture}-setup.exe"
        receipt = json.loads(source.with_suffix(".exe.json").read_text(encoding="utf-8-sig"))
        expected = {"commit": commit, "architecture": architecture, "release_tag": tag,
                    "version": tag[1:], "file": source.name}
        if any(receipt.get(key) != value for key, value in expected.items()):
            raise ValueError(f"Installer provenance mismatch: {architecture}")
        if source.read_bytes()[:2] != b"MZ" or receipt.get("sha256", "").lower() != sha256(source):
            raise ValueError(f"Installer integrity mismatch: {architecture}")
        target = output / f"SSMV-{tag[1:]}-windows-{architecture}-setup.exe"
        shutil.copyfile(source, target)
        receipt["file"] = target.name
        provenance = target.with_suffix(".exe.json")
        provenance.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        checksum = target.with_suffix(".exe.sha256")
        checksum.write_text(f"{sha256(target)}  {target.name}\n", encoding="utf-8")
        files.extend((target, provenance, checksum))
    return files


def upload_plan(release, files):
    if release.get("draft"):
        raise ValueError("Publish only to an existing published release")
    existing = {asset["name"]: asset for asset in release["assets"]}
    pending = []
    for path in files:
        asset = existing.get(path.name)
        if asset:
            if asset.get("digest") != "sha256:" + sha256(path):
                raise ValueError(f"Refusing to replace existing release asset: {path.name}")
        else:
            pending.append(path)
    return pending


def verify_release(before, after, files):
    for key in ("id", "tag_name", "target_commitish", "name", "body", "draft", "prerelease"):
        if before.get(key) != after.get(key):
            raise ValueError(f"Release metadata changed: {key}")
    assets = {asset["name"]: asset for asset in after["assets"]}
    for original in before["assets"]:
        current = assets.get(original["name"], {})
        for key in ("id", "size", "digest", "updated_at"):
            if current.get(key) != original.get(key):
                raise ValueError(f"Existing asset changed: {original['name']}")
    for path in files:
        if assets.get(path.name, {}).get("digest") != "sha256:" + sha256(path):
            raise ValueError(f"Published asset failed integrity check: {path.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    files = prepare_assets(args.directory, args.tag, args.commit)
    repository = os.environ["GH_REPO"]
    endpoint = f"repos/{repository}/releases/tags/{args.tag}"
    def read_release():
        return json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))
    before = read_release()
    if before["tag_name"] != args.tag:
        raise ValueError("Release tag mismatch")
    pending = upload_plan(before, files)
    if pending:
        # No --clobber: collisions fail instead of deleting or replacing anything.
        subprocess.run(["gh", "release", "upload", args.tag, *map(str, pending),
                        "--repo", repository], check=True)
    verify_release(before, read_release(), files)
    print(f"Verified {len(files)} Windows assets on {args.tag}; existing release assets preserved.")


if __name__ == "__main__":
    main()
