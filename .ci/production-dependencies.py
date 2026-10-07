#!/usr/bin/env python3
"""Read-only proof of an exact dependency migration over a frozen source checkpoint.

No source preparation, manifest rewriting, resolver invocation, or network access.
Frozen parity evidence stays unchanged. This gate checks the intentional metadata
transition and every other committed blob, its file type, mode and working bytes.
"""
from __future__ import annotations
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess

CHECKPOINTS = {
    'SideSign': 'aaa4375a59075a7b0a446cf4c2dc8193c247a875',
    'SideStore': '9d8c71ed69684f805325ef440983e74d97113a71',
}
ANISETTE = '62ce85c8798d8eab8e29752aba7dc9f1f6a5b80d'
ANISETTE_URL = 'https://github.com/NRG-Wardog/AnisetteKit.git'
MINIMUXER = 'efbcab05d7d636aa37c6bf6c7f364d122c5610f6'
LOCKS = {'SideSign': 'Package.resolved',
         'SideStore': 'AltStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'}
DEPENDENCY_FILES = {'SideSign': {'Package.swift', LOCKS['SideSign']},
                    'SideStore': {'.gitmodules', LOCKS['SideStore']}}
TEST_FILES = {'SideSign': set(), 'SideStore': {'tests/runtime_source/test_runtime_source.py'}}
ADDITIONS = {'.ci/production-dependencies.py', '.ci/production-dependencies.json',
             '.ci/test_production_dependencies.py', '.ci/PRODUCTION_DEPENDENCIES.md'}


class ProofError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ProofError(message)


def git(root, *args, input_data=None):
    root = Path(root).resolve(strict=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_NO_REPLACE_OBJECTS='1', GIT_GRAFT_FILE=os.devnull,
               GIT_NO_LAZY_FETCH='1', GIT_CONFIG_SYSTEM=os.devnull,
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
               GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0')
    return subprocess.check_output([
        'git', '--no-replace-objects', '--git-dir=' + str(root / '.git'),
        '--work-tree=' + str(root), '-c', 'core.fsmonitor=false',
        '-c', 'core.untrackedCache=false', *args], input=input_data, env=env,
        stderr=subprocess.PIPE)


def inventory(root, revision):
    result = {}
    for row in git(root, 'ls-tree', '-rz', revision).split(b'\0'):
        if row:
            header, path = row.split(b'\t', 1)
            result[os.fsdecode(path)] = tuple(header.decode().split())
    return result


def blobs(root, object_ids):
    ordered = sorted(object_ids)
    result = {}
    if not ordered:
        return result
    data = git(root, 'cat-file', '--batch', input_data=('\n'.join(ordered)+'\n').encode())
    offset = 0
    for oid in ordered:
        end = data.index(b'\n', offset)
        header = data[offset:end].decode().split()
        require(len(header) == 3 and header[:2] == [oid, 'blob'], 'Invalid committed object')
        begin = end + 1
        end = begin + int(header[2])
        require(data[end:end+1] == b'\n', 'Truncated committed blob')
        result[oid] = data[begin:end]
        offset = end + 1
    require(offset == len(data), 'Unexpected committed object bytes')
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_regular(path):
    mode = path.lstat().st_mode
    require(stat.S_ISREG(mode) and not mode & 0o111, str(path) + ': expected regular 100644 file')
    return path.read_bytes()


def pin_map(lock):
    result = {}
    for pin in lock['pins']:
        identity = pin['identity']
        require(identity not in result, 'Duplicate package identity: ' + identity)
        result[identity] = pin
    return result


def verify_lock(current, baseline):
    require(set(current) == {'pins', 'version'}, 'Provisional lock must omit stale/unverified originHash')
    require(current['version'] == baseline['version'] == 3, 'Lock schema changed')
    expected = pin_map(baseline)
    expected['anisettekit'] = {'identity': 'anisettekit', 'kind': 'remoteSourceControl',
        'location': ANISETTE_URL, 'state': {'revision': ANISETTE}}
    require(pin_map(current) == expected, 'SwiftPM pin drift outside exact AnisetteKit transition')
    return len(expected) - 1


def verify(root, *, allow_pending_child_pins=False):
    root = Path(root).resolve(strict=True)
    spec = json.loads(read_regular(root / '.ci/production-dependencies.json'))
    owner = spec['owner']
    require(owner in CHECKPOINTS, 'Unexpected owner')
    require(spec['source_checkpoint'] == CHECKPOINTS[owner], 'Unexpected source checkpoint')
    checkpoint = CHECKPOINTS[owner]
    require(git(root, 'rev-parse', '--is-shallow-repository').strip() == b'false', 'Shallow history')
    git(root, 'merge-base', '--is-ancestor', checkpoint, 'HEAD')
    before, after = inventory(root, checkpoint), inventory(root, 'HEAD')
    require(set(after) == set(before) | ADDITIONS, 'Committed inventory drift')
    require(set(spec['dependency_files']) == DEPENDENCY_FILES[owner], 'Dependency allowlist drift')
    require(set(spec['test_files']) == TEST_FILES[owner], 'Test allowlist drift')
    data = blobs(root, {oid for mode, kind, oid in list(before.values()) + list(after.values()) if kind == 'blob'})
    expected_links = {p: entry[2] for p, entry in before.items() if entry[0] == '160000'}
    pending = False
    if owner == 'SideStore':
        require(set(spec['child_gitlinks']) == {'Dependencies/SideSign', 'Dependencies/minimuxer'}, 'Child allowlist drift')
        require(spec['child_gitlinks']['Dependencies/minimuxer'] == MINIMUXER, 'minimuxer pin drift')
        sidesign = spec['child_gitlinks']['Dependencies/SideSign']
        pending = sidesign is None
        if not pending:
            require(isinstance(sidesign, str) and re.fullmatch('[0-9a-f]{40}', sidesign), 'Invalid SideSign pin')
            require(sidesign != before['Dependencies/SideSign'][2], 'SideSign still points at upstream checkpoint')
            expected_links = spec['child_gitlinks']
    else:
        require(spec['child_gitlinks'] == {}, 'Unexpected child gitlinks')
    links = {p: entry[2] for p, entry in after.items() if entry[0] == '160000'}
    require(links == expected_links, 'Child gitlinks differ from exact approved stage')
    classified = {**spec['dependency_files'], **spec['test_files']}
    unchanged = 0
    for path, entry in after.items():
        mode, kind, oid = entry
        if mode == '160000':
            continue
        require(kind == 'blob', 'Unsupported committed object: ' + path)
        if path in classified:
            expected = classified[path]
            require(mode == expected['mode'] == '100644', 'Dependency/test mode drift: ' + path)
            require(sha(data[before[path][2]]) == expected['checkpoint_sha256'], 'Checkpoint metadata drift: ' + path)
            require(sha(data[oid]) == expected['production_sha256'], 'Dependency/test bytes drift: ' + path)
        elif path in before:
            require(entry == before[path], 'Frozen blob/mode changed: ' + path)
            unchanged += 1
        else:
            require(mode == '100644', 'Proof metadata mode drift: ' + path)
        target = root / path
        actual_mode = target.lstat().st_mode
        if mode == '120000':
            require(stat.S_ISLNK(actual_mode) and os.fsencode(os.readlink(target)) == data[oid], 'Symlink drift: ' + path)
        else:
            require(stat.S_ISREG(actual_mode), 'Nonregular working file: ' + path)
            require(('100755' if actual_mode & 0o111 else '100644') == mode, 'Working mode drift: ' + path)
            require(target.read_bytes() == data[oid], 'Uncommitted bytes: ' + path)
    files = set()
    for directory, dirs, names in os.walk(root, followlinks=False):
        rel = Path(directory).relative_to(root)
        for name in list(dirs):
            path = rel / name
            if path.as_posix() == '.git' or path.as_posix() in links:
                dirs.remove(name)
            elif (root / path).is_symlink():
                files.add(path.as_posix())
                dirs.remove(name)
        files.update((rel / name).as_posix() for name in names
                     if (rel / name).as_posix() != ".git")
    require(files == set(after) - set(links), 'Working inventory drift')
    index = {}
    for row in git(root, 'ls-files', '--stage', '-z').split(b'\0'):
        if row:
            header, path = row.split(b'\t', 1)
            mode, oid, stage = header.decode().split()
            require(stage == '0', 'Unmerged index')
            index[os.fsdecode(path)] = (mode, oid)
    require(index == {p:(e[0],e[2]) for p,e in after.items()}, 'Index differs from HEAD')
    require(not git(root, 'status', '--porcelain', '--untracked-files=all').strip(), 'Dirty repository')
    lockpath = LOCKS[owner]
    frozen_pins = verify_lock(json.loads(data[after[lockpath][2]]), json.loads(data[before[lockpath][2]]))
    if owner == 'SideSign':
        original = data[before['Package.swift'][2]].decode()
        old = '.package(url: "https://github.com/mahee96/AnisetteKit.git",   branch: "main"),'
        new = '.package(url: "' + ANISETTE_URL + '", revision: "' + ANISETTE + '"),'
        require(original.count(old) == 1 and data[after['Package.swift'][2]].decode() == original.replace(old, new), 'Manifest changes exceed exact AnisetteKit pin')
    else:
        modules = configparser.ConfigParser()
        modules.read_string(data[after['.gitmodules'][2]].decode())
        require(set(modules.sections()) == {'submodule "Dependencies/SideSign"', 'submodule "Dependencies/minimuxer"'}, 'Submodule inventory drift')
        for child in ('SideSign', 'minimuxer'):
            require(dict(modules['submodule "Dependencies/' + child + '"']) == {
                'path':'Dependencies/' + child, 'url':'https://github.com/NRG-Wardog/' + child + '.git'}, 'Submodule URL/branch drift: ' + child)
    require(allow_pending_child_pins or not pending, 'Pending published SideSign child pin; preparation only')
    return {'owner':owner, 'status':'preparation_only_child_pins_pending' if pending else 'exact_dependency_transition_pass',
            'checkpoint':checkpoint, 'commit':git(root, 'rev-parse', 'HEAD').decode().strip(),
            'unchanged_checkpoint_blobs':unchanged, 'dependency_files':sorted(DEPENDENCY_FILES[owner]),
            'test_files':sorted(TEST_FILES[owner]), 'unrelated_swiftpm_pins_preserved':frozen_pins,
            'child_gitlinks':links, 'native_resolver_status':'not_run', 'production_ready':False,
            'runtime_behavior_changes':[]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--allow-pending-child-pins', action='store_true', help='Report preparation only; cannot establish cutover readiness')
    args = parser.parse_args()
    print(json.dumps(verify(args.root, allow_pending_child_pins=args.allow_pending_child_pins), indent=2))
