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


def proof_environment() -> dict[str, str]:
    # A proof must use the supplied repository, never a caller's redirected
    # object database, index, replacement graph, configuration or worktree.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update({
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": os.devnull,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_GRAFT_FILE": os.devnull,
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
    })
    return environment


def git(root: Path, *arguments: str, input_data: bytes | None = None) -> bytes:
    root = root.resolve(strict=True)
    command = ["git", "--no-replace-objects", "--git-dir=" + str(root / ".git"),
               "--work-tree=" + str(root), "-c", "core.fsmonitor=false",
               "-c", "core.untrackedCache=false", *arguments]
    return subprocess.check_output(command, input=input_data, env=proof_environment(),
                                   stderr=subprocess.PIPE)


def blob_hashes(root: Path, object_ids: set[str]) -> dict[str, str]:
    ordered = sorted(object_ids)
    output = git(root, "cat-file", "--batch", input_data=("\n".join(ordered) + "\n").encode())
    hashes = {}
    offset = 0
    for expected_oid in ordered:
        newline = output.index(b"\n", offset)
        header = output[offset:newline].decode().split()
        if len(header) != 3 or header[0] != expected_oid or header[1] != "blob":
            raise ParityError(f"Missing or invalid committed blob: {expected_oid}")
        length = int(header[2])
        start = newline + 1
        end = start + length
        if end >= len(output) or output[end:end + 1] != b"\n":
            raise ParityError(f"Truncated committed blob: {expected_oid}")
        hashes[expected_oid] = digest(output[start:end])
        offset = end + 1
    if offset != len(output):
        raise ParityError("Unexpected committed-object data")
    return hashes


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
    git(root, "merge-base", "--is-ancestor", base, "HEAD")
    gitlinks = {}
    tracked = {}
    head_entries = {}
    for record in git(root, "ls-tree", "-rz", "HEAD").split(b"\0"):
        if not record:
            continue
        header, path = record.split(b"\t", 1)
        mode, kind, oid = header.decode().split()
        relative = os.fsdecode(path)
        head_entries[relative] = (mode, oid)
        if mode == "160000":
            gitlinks[relative] = oid
        else:
            if kind != "blob":
                raise ParityError(f"Unsupported committed entry: {relative}")
            tracked[relative] = (mode, oid)
    if gitlinks != manifest["gitlinks"]:
        raise ParityError("Child gitlinks changed")
    allowed = set(manifest["files"]) | set(manifest["allowed_nonruntime_files"])
    if set(tracked) != allowed:
        raise ParityError(f"Tracked inventory drift: missing={sorted(allowed-set(tracked))}, extra={sorted(set(tracked)-allowed)}")
    hashes = blob_hashes(root, {oid for mode, oid in tracked.values()})
    for relative, entry in manifest["files"].items():
        mode, oid = tracked[relative]
        if mode != entry["mode"] or hashes[oid] != entry["sha256"]:
            raise ParityError(f"Committed byte/mode drift: {relative}")
    # Also bind the working verifier/manifest/docs to their committed versions.
    # Git status alone is insufficient when assume-unchanged or skip-worktree
    # flags hide a restored working copy that differs from the actual commit.
    for relative in manifest["allowed_nonruntime_files"]:
        mode, oid = tracked[relative]
        if describe(root / relative) != {"mode": mode, "sha256": hashes[oid]}:
            raise ParityError(f"Uncommitted proof metadata: {relative}")
    if require_clean:
        index_entries = {}
        for record in git(root, "ls-files", "--stage", "-z").split(b"\0"):
            if not record:
                continue
            header, path = record.split(b"\t", 1)
            mode, oid, stage = header.decode().split()
            if stage != "0":
                raise ParityError("Unmerged index")
            index_entries[os.fsdecode(path)] = (mode, oid)
        if index_entries != head_entries:
            raise ParityError("Index differs from committed tree")
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
