#!/usr/bin/env python3
"""Read-only frozen source inventory verifier. No builder or patcher is imported."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


class ParityError(ValueError):
    pass


def git(root: Path, *arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *arguments], stderr=subprocess.STDOUT)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def describe(path: Path) -> dict[str, str]:
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        return {"mode": "120000", "sha256": digest(os.fsencode(os.readlink(path)))}
    if not stat.S_ISREG(mode):
        raise ParityError(f"Unsupported file type: {path}")
    return {"mode": "100755" if mode & 0o111 else "100644", "sha256": digest(path.read_bytes())}


def actual_paths(root: Path, gitlinks: dict[str, str]) -> set[str]:
    result: set[str] = set()
    for directory, dirs, files in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in list(dirs):
            path = directory_path / name
            relative = path.relative_to(root).as_posix()
            if relative == ".git" or relative in gitlinks:
                dirs.remove(name)
            elif path.is_symlink():
                result.add(relative)
                dirs.remove(name)
        for name in files:
            path = directory_path / name
            relative = path.relative_to(root).as_posix()
            if relative != ".git":
                result.add(relative)
    return result


def verify_files(root: Path, manifest: dict, *, old_pipeline: bool = False) -> int:
    expected = manifest["files"]
    allowed = set(expected)
    if old_pipeline:
        allowed.update(manifest.get("excluded_preparation_evidence", {}))
    else:
        allowed.update(manifest.get("allowed_nonruntime_files", []))
    actual = actual_paths(root, manifest.get("gitlinks", {}))
    missing = set(expected) - actual
    extra = actual - allowed
    if missing or extra:
        raise ParityError(f"Inventory drift: missing={sorted(missing)}, extra={sorted(extra)}")
    for relative, entry in expected.items():
        observed = describe(root / relative)
        if observed != {key: entry[key] for key in ("mode", "sha256")}:
            raise ParityError(f"Byte/mode drift: {relative}")
    if old_pipeline:
        for relative, entry in manifest.get("excluded_preparation_evidence", {}).items():
            if relative not in actual or describe(root / relative) != {
                    key: entry[key] for key in ("mode", "sha256")}:
                raise ParityError(f"Preparation evidence drift: {relative}")
    return len(expected)


def verify_git(root: Path, manifest: dict, *, require_clean: bool = False) -> None:
    base = manifest["upstream_base"]
    if git(root, "rev-parse", base + "^{tree}").decode().strip() != manifest["upstream_tree"]:
        raise ParityError("Upstream tree changed")
    subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", base, "HEAD"], check=True)
    gitlinks = {}
    tracked = set()
    for record in git(root, "ls-tree", "-rz", "HEAD").split(b"\0"):
        if not record:
            continue
        header, path = record.split(b"\t", 1)
        mode, kind, oid = header.decode().split()
        relative = os.fsdecode(path)
        if mode == "160000":
            gitlinks[relative] = oid
        else:
            tracked.add(relative)
    if gitlinks != manifest["gitlinks"]:
        raise ParityError("Child gitlinks changed")
    allowed = set(manifest["files"]) | set(manifest["allowed_nonruntime_files"])
    if tracked != allowed:
        raise ParityError(f"Tracked inventory drift: missing={sorted(allowed-tracked)}, extra={sorted(tracked-allowed)}")
    if require_clean and git(root, "status", "--porcelain", "--untracked-files=all").strip():
        raise ParityError("Repository is not clean")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--old-root", type=Path, help="Optional prepared OLD owner checkout; never rewritten")
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()
    manifest = json.loads((args.root / "docs/runtime-migration/source-manifest.json").read_text())
    count = verify_files(args.root, manifest)
    verify_git(args.root, manifest, require_clean=args.require_clean)
    if args.old_root:
        verify_files(args.old_root, manifest, old_pipeline=True)
    print(f"SIDESTORE_RUNTIME_SOURCE_PARITY_PASS files={count} changed={len(manifest['changed_paths'])} "
          f"gitlinks={len(manifest['gitlinks'])} excluded_preparation_evidence={len(manifest['excluded_preparation_evidence'])}")


if __name__ == "__main__":
    main()
