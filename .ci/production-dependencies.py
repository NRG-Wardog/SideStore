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
    'SideSign': 'ed30d3989ea0f80bcb91466d6d5ca043f4366df0',
    'SideStore': '9d8c71ed69684f805325ef440983e74d97113a71',
}
ANISETTE = '62ce85c8798d8eab8e29752aba7dc9f1f6a5b80d'
ANISETTE_URL = 'https://github.com/NRG-Wardog/AnisetteKit.git'
MINIMUXER = 'efbcab05d7d636aa37c6bf6c7f364d122c5610f6'
NATIVE_RECEIPT_SHA256 = '82ca6fbfa1a51d28de31b38f42abc6b7d5f662da54e33b9e841f778cf053cfc4'
READINESS_SIDESIGN_COMMIT = '06351a87d44ff8faa7d5a2e8c7ed3096fff73d2c'
LOCKS = {'SideSign': 'Package.resolved',
         'SideStore': 'AltStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'}
DEPENDENCY_FILES = {'SideSign': {'Package.swift', LOCKS['SideSign']},
                    'SideStore': {'.gitmodules', LOCKS['SideStore']}}
TEST_FILES = {'SideSign': set(), 'SideStore': {'tests/runtime_source/test_runtime_source.py'}}
ADDITIONS = {'.ci/production-dependencies.py', '.ci/production-dependencies.json',
             '.ci/test_production_dependencies.py', '.ci/PRODUCTION_DEPENDENCIES.md'}

DIAGNOSTIC_ACCEPTED = {'commit': '1ebc69390f5b570f95cd823ac8df97c3a2f082f9',
                       'tree': '4d043ad782d6dc782e765fe94564be353cb35e80'}
DIAGNOSTIC_SOURCE_CHECKPOINT = {'commit': '7b3f356c5128b17fdd76eed81285096b3cc41da7',
                                'tree': '5eec041d13f5eb5d805189f5827d6a60ddfa91f2'}
DIAGNOSTIC_ACCEPTED_ANISETTE = 'e530b84687ebea2e7d1115119e1a6d18372de14b'
DIAGNOSTIC_ANISETTE = 'f494494ede88890555df345054f7fbb87b53aea5'
DIAGNOSTIC_REGISTRY_SHA256 = '2333ff8e03dea9fa4b8620e64e15ec76cb6a870a2d61c42dd057ddce0c13354f'
DIAGNOSTIC_DELTA_SHA256 = '65a3689c1609cfbcfaa317e33401d500c5bde88a80cf054b240124f93b025165'
DIAGNOSTIC_ACCEPTED_SIDESIGN = '3bd4afa0addbf95a8666ac91d8bfcf99f5182eea'
DIAGNOSTIC_METADATA = {'.ci/production-dependencies.py',
                       '.ci/test_diagnostic_dependencies.py',
                       '.ci/DIAGNOSTIC_DEPENDENCIES.md'}
DIAGNOSTIC_LOCK = LOCKS['SideStore']
DIAGNOSTIC_CHILD = 'Dependencies/SideSign'


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
    require(set(current) == {'pins', 'version'}, 'Lock must preserve the reviewed absent originHash state')
    require(current['version'] == baseline['version'] == 3, 'Lock schema changed')
    expected = pin_map(baseline)
    expected['anisettekit'] = {'identity': 'anisettekit', 'kind': 'remoteSourceControl',
        'location': ANISETTE_URL, 'state': {'revision': ANISETTE}}
    require(pin_map(current) == expected, 'SwiftPM pin drift outside exact AnisetteKit transition')
    return len(expected) - 1



def verify_native_lineage(root, spec, current, lock_bytes):
    receipt = spec.get('native_receipt')
    require(isinstance(receipt, dict), 'Missing reviewed native receipt')
    encoded = json.dumps(receipt, sort_keys=True, separators=(',', ':')).encode()
    require(sha(encoded) == NATIVE_RECEIPT_SHA256, 'Reviewed native receipt mismatch')
    require(spec['native_resolver_status'] == 'passed_remote_iphoneos' and
            spec['origin_hash_status'] == 'verified_absent_after_remote_xcode_resolution',
            'Resolver status differs from reviewed observed absence')
    tested = receipt['native_tested_commit']
    git(root, 'merge-base', '--is-ancestor', tested, 'HEAD')
    require(git(root, 'rev-parse', tested + '^{tree}').decode().strip() ==
            receipt['native_tested_tree'], 'Native-tested source tree changed')
    native_tree = inventory(root, tested)
    require(set(current) == set(native_tree), 'Native-tested inventory changed')
    changed = {path for path in current if current[path] != native_tree[path]}
    require(changed <= ADDITIONS | {'Dependencies/SideSign'},
            'Native-tested tree changed outside readiness metadata and SideSign gitlink')
    tested_children = {path: entry[2] for path, entry in native_tree.items() if entry[0] == '160000'}
    require(tested_children == receipt['native_tested_children'], 'Native-tested child graph changed')
    require(current['Dependencies/SideSign'] == ('160000', 'commit', READINESS_SIDESIGN_COMMIT),
            'SideSign readiness child differs from reviewed publication')
    require(sha(lock_bytes) == receipt['locks']['SideStore']['sha256'] and
            git(root, 'show', tested + ':' + LOCKS['SideStore']) == lock_bytes,
            'Lock differs from actual Xcode-tested bytes')
    require(receipt['readiness_scope'] == 'eligible_for_gated_full_build' and
            receipt['final_exact_ref_ipa_build_required'] is True,
            'Final gated build requirement changed')
    return receipt


def verify_working_blob(root, path, entry, data):
    mode, kind, oid = entry
    target = root / path
    actual_mode = target.lstat().st_mode
    if mode == '120000':
        require(stat.S_ISLNK(actual_mode) and os.fsencode(os.readlink(target)) == data[oid], 'Symlink drift: ' + path)
    else:
        require(stat.S_ISREG(actual_mode), 'Nonregular working file: ' + path)
        require(('100755' if actual_mode & 0o111 else '100644') == mode, 'Working mode drift: ' + path)
        require(target.read_bytes() == data[oid], 'Uncommitted bytes: ' + path)


def verify_working_inventory(root, after):
    links = {p:e[2] for p,e in after.items() if e[0] == "160000"}
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
        verify_working_blob(root, path, entry, data)
    verify_working_inventory(root, after)
    lockpath = LOCKS[owner]
    frozen_pins = verify_lock(json.loads(data[after[lockpath][2]]), json.loads(data[before[lockpath][2]]))
    native = verify_native_lineage(root, spec, after, data[after[lockpath][2]])
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
            'child_gitlinks':links, 'native_resolver_status':spec['native_resolver_status'],
            'ios_compilation':'PASS_ON_NATIVE_TESTED_GRAPH',
            'native_tested_commit':native['native_tested_commit'],
            'native_tested_tree':native['native_tested_tree'],
            'native_tested_children':native['native_tested_children'],
            'native_run_url':native['run_url'],
            'native_validation_host_commit':native['validation_host_commit'],
            'native_artifact_sha256':native['artifact_zip_sha256'],
            'native_receipt_sha256':NATIVE_RECEIPT_SHA256,
            'readiness_scope':native['readiness_scope'],
            'final_exact_ref_ipa_build_required':True,
            'production_ready':True,
            'runtime_behavior_changes':[]}


def exact_keys(value, keys, message):
    require(isinstance(value, dict) and set(value) == set(keys), message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def approved_external_json(root, path, approved_sha256, label):
    require(path is not None and isinstance(approved_sha256, str) and
            re.fullmatch('[0-9a-f]{64}', approved_sha256),
            label + ' requires a separately approved SHA256')
    path = Path(path).resolve(strict=True)
    require(not path.is_relative_to(root), label + ' must be external to the owner checkout')
    encoded = read_regular(path)
    require(sha(encoded) == approved_sha256, label + ' SHA256 mismatch')
    return json.loads(encoded, object_pairs_hook=unique_object)


def diagnostic_row(entry, data):
    if entry is None:
        return None
    mode, kind, oid = entry
    if (mode, kind) == ('160000', 'commit'):
        return {'mode': mode, 'commit': oid}
    require(kind == 'blob', 'Diagnostic transition requires blob objects')
    return {'mode': mode, 'blob': oid, 'sha256': sha(data[oid])}


def observed_origin_hash(lock):
    present = 'originHash' in lock
    value = lock.get('originHash')
    require(not present or (isinstance(value, str) and
            re.fullmatch('[0-9a-f]{64}', value)), 'Invalid observed originHash')
    return {'present': present, 'value': value}


def verify_diagnostic_resolver(root, receipt, lock_bytes, baseline_bytes, after):
    exact_keys(receipt, {'schema_version', 'owner', 'purpose', 'run_url', 'run_attempt',
        'resolver_tested_commit', 'resolver_tested_tree', 'lock_sha256', 'origin_hash',
        'toolchain', 'command', 'evidence_sha256'}, 'Unexpected diagnostic resolver receipt schema')
    require(type(receipt['schema_version']) is int and receipt['schema_version'] == 1 and
            receipt['owner'] == 'SideStore' and
            receipt['purpose'] == 'diagnostic_xcode_resolution',
            'Unexpected diagnostic resolver receipt identity')
    require(isinstance(receipt['run_url'], str) and re.fullmatch(
            r'https://github.com/NRG-Wardog/[A-Za-z0-9_.-]+/actions/runs/[1-9][0-9]*',
            receipt['run_url']) and type(receipt['run_attempt']) is int and
            receipt['run_attempt'] > 0, 'Invalid diagnostic resolver run identity')
    exact_keys(receipt['toolchain'], {'xcode', 'swift'}, 'Missing observed resolver toolchain')
    require(all(isinstance(v, str) and v.strip() for v in receipt['toolchain'].values()),
            'Missing observed resolver toolchain')
    require(isinstance(receipt['command'], list) and receipt['command'] and
            all(isinstance(v, str) and v for v in receipt['command']), 'Missing resolver command')
    exact_keys(receipt['evidence_sha256'], {'resolver_log', 'resolution_before', 'resolution_after'},
               'Missing diagnostic resolver evidence digests')
    require(all(isinstance(v, str) and re.fullmatch('[0-9a-f]{64}', v)
                for v in receipt['evidence_sha256'].values()), 'Invalid resolver evidence digest')
    tested = receipt['resolver_tested_commit']
    require(isinstance(tested, str) and re.fullmatch('[0-9a-f]{40}', tested) and
            isinstance(receipt['resolver_tested_tree'], str) and
            re.fullmatch('[0-9a-f]{40}', receipt['resolver_tested_tree']),
            'Invalid diagnostic resolver-tested identity')
    git(root, 'merge-base', '--is-ancestor', tested, 'HEAD')
    require(git(root, 'rev-parse', tested + '^{tree}').decode().strip() ==
            receipt['resolver_tested_tree'], 'Diagnostic resolver-tested tree mismatch')
    tested_inventory = inventory(root, tested)
    require(set(tested_inventory) == set(after) and all(
            tested_inventory[p] == entry for p, entry in after.items() if p != DIAGNOSTIC_LOCK),
            'Candidate differs from resolver-tested source outside captured lock')
    require(git(root, 'show', tested + ':' + DIAGNOSTIC_LOCK) == baseline_bytes,
            'Resolver did not start from the accepted lock')
    require(receipt['lock_sha256'] == sha(lock_bytes), 'Resolver-observed lock SHA256 mismatch')
    exact_keys(receipt['origin_hash'], {'present', 'value'}, 'Missing observed originHash state')
    require(type(receipt['origin_hash']['present']) is bool and
            receipt['origin_hash'] == observed_origin_hash(json.loads(lock_bytes)),
            'Resolver-observed originHash mismatch')


def verify_diagnostic_lock(lock_bytes, baseline_bytes):
    """Check source identity only; changed bytes still require a reviewed receipt."""
    baseline = json.loads(baseline_bytes, object_pairs_hook=unique_object)
    current = json.loads(lock_bytes, object_pairs_hook=unique_object)
    require(set(current) in ({'pins', 'version'}, {'pins', 'version', 'originHash'}) and
            type(current['version']) is int and current['version'] == baseline['version'] == 3,
            'Diagnostic lock schema drift')
    observed_origin_hash(current)
    expected = pin_map(baseline)
    require(len(expected) == 10, 'Accepted SideStore lock must have exactly ten pins')
    if lock_bytes != baseline_bytes:
        expected['anisettekit'] = {'identity': 'anisettekit', 'kind': 'remoteSourceControl',
            'location': ANISETTE_URL, 'state': {'revision': DIAGNOSTIC_ANISETTE}}
    require(pin_map(current) == expected, 'Diagnostic SwiftPM pin drift outside exact AnisetteKit transition')
    return len(expected) - 1



def verify_diagnostic(root, *, basis_path, basis_sha256,
                      resolver_receipt_path=None, resolver_receipt_sha256=None):
    """Prove the dependency delta over the frozen diagnostic source checkpoint."""
    root = Path(root).resolve(strict=True)
    basis = approved_external_json(root, basis_path, basis_sha256, 'Diagnostic basis')
    exact_keys(basis, {'schema_version', 'owner', 'purpose', 'source_registry_sha256',
                      'source_delta_sha256', 'accepted', 'source_checkpoint', 'candidate',
                      'anisette', 'sidesign', 'changes'},
               'Unexpected diagnostic source basis schema; outcomes belong in separate receipts')
    require(type(basis['schema_version']) is int and basis['schema_version'] == 1 and
            basis['owner'] == 'SideStore' and
            basis['purpose'] == 'diagnostic_dependency_source_transition',
            'Unexpected diagnostic basis identity')
    require(isinstance(DIAGNOSTIC_REGISTRY_SHA256, str) and
            re.fullmatch('[0-9a-f]{64}', DIAGNOSTIC_REGISTRY_SHA256),
            'Diagnostic source registry awaiting reviewed hash')
    require(basis['source_registry_sha256'] == DIAGNOSTIC_REGISTRY_SHA256,
            'Unexpected diagnostic source registry')
    require(isinstance(DIAGNOSTIC_DELTA_SHA256, str) and
            re.fullmatch('[0-9a-f]{64}', DIAGNOSTIC_DELTA_SHA256),
            'Diagnostic source delta awaiting reviewed hash')
    require(basis['source_delta_sha256'] == DIAGNOSTIC_DELTA_SHA256,
            'Unexpected accepted-to-diagnostic source delta')
    require(basis['accepted'] == DIAGNOSTIC_ACCEPTED, 'Unexpected accepted production base')
    require(basis['source_checkpoint'] == DIAGNOSTIC_SOURCE_CHECKPOINT,
            'Unexpected diagnostic source checkpoint')
    require(basis['anisette'] == {'repository': ANISETTE_URL, 'accepted_commit': DIAGNOSTIC_ACCEPTED_ANISETTE,
            'diagnostic_commit': DIAGNOSTIC_ANISETTE}, 'Unexpected diagnostic AnisetteKit pin')
    exact_keys(basis['candidate'], {'commit', 'tree'}, 'Unexpected diagnostic candidate schema')
    exact_keys(basis['sidesign'], {'repository', 'commit', 'tree', 'basis_sha256'},
               'Unexpected SideSign dependency identity schema')
    sidesign = basis['sidesign']
    require(sidesign['repository'] == 'https://github.com/NRG-Wardog/SideSign.git' and
            all(isinstance(sidesign[k], str) and re.fullmatch('[0-9a-f]{40}', sidesign[k]) and
                sidesign[k] != '0' * 40 for k in ('commit', 'tree')) and
            isinstance(sidesign['basis_sha256'], str) and
            re.fullmatch('[0-9a-f]{64}', sidesign['basis_sha256']) and
            sidesign['basis_sha256'] != '0' * 64 and
            sidesign['commit'] != DIAGNOSTIC_ACCEPTED_SIDESIGN,
            'Unresolved or invalid diagnostic SideSign dependency identity')
    require(git(root, 'rev-parse', '--is-shallow-repository').strip() == b'false', 'Shallow history')
    accepted = DIAGNOSTIC_ACCEPTED['commit']
    checkpoint = DIAGNOSTIC_SOURCE_CHECKPOINT['commit']
    git(root, 'merge-base', '--is-ancestor', accepted, checkpoint)
    git(root, 'merge-base', '--is-ancestor', checkpoint, 'HEAD')
    for label, identity in (('Accepted production', DIAGNOSTIC_ACCEPTED),
                            ('Diagnostic source checkpoint', DIAGNOSTIC_SOURCE_CHECKPOINT)):
        require(git(root, 'rev-parse', identity['commit'] + '^{tree}').decode().strip() ==
                identity['tree'], label + ' tree mismatch')
    commit = git(root, 'rev-parse', 'HEAD').decode().strip()
    tree = git(root, 'rev-parse', 'HEAD^{tree}').decode().strip()
    require(basis['candidate'] == {'commit': commit, 'tree': tree},
            'Diagnostic candidate commit/tree mismatch')
    before, after = inventory(root, checkpoint), inventory(root, 'HEAD')
    additions = DIAGNOSTIC_METADATA - set(before)
    require(set(after) == set(before) | additions, 'Diagnostic committed inventory drift')
    changed = {p for p in set(before) | set(after) if before.get(p) != after.get(p)}
    require(changed <= DIAGNOSTIC_METADATA | {DIAGNOSTIC_CHILD, DIAGNOSTIC_LOCK},
            'Diagnostic change outside exact dependency/verifier metadata scope')
    require(DIAGNOSTIC_METADATA | {DIAGNOSTIC_CHILD} <= changed,
            'Missing reviewed diagnostic metadata or SideSign gitlink transition')
    require(isinstance(basis['changes'], dict) and set(basis['changes']) == changed,
            'Diagnostic basis changed-path inventory mismatch')
    require(before[DIAGNOSTIC_CHILD] == ('160000', 'commit', DIAGNOSTIC_ACCEPTED_SIDESIGN),
            'Diagnostic source checkpoint SideSign pin mismatch')
    require(after[DIAGNOSTIC_CHILD] == ('160000', 'commit', sidesign['commit']),
            'Diagnostic SideSign gitlink differs from approved dependency identity')
    require(after['Dependencies/minimuxer'] == before['Dependencies/minimuxer'] ==
            ('160000', 'commit', MINIMUXER), 'Diagnostic minimuxer gitlink drift')
    data = blobs(root, {oid for mode, kind, oid in list(before.values()) + list(after.values())
                       if kind == 'blob'})
    for path, entry in after.items():
        if path in changed:
            expected_type = ('160000', 'commit') if path == DIAGNOSTIC_CHILD else ('100644', 'blob')
            require(entry[:2] == expected_type, 'Diagnostic transition file type/mode drift: ' + path)
            require(basis['changes'][path] == {'before': diagnostic_row(before.get(path), data),
                    'after': diagnostic_row(entry, data)}, 'Diagnostic basis blob/mode/hash mismatch: ' + path)
        else:
            require(entry == before[path], 'Diagnostic frozen blob/mode changed: ' + path)
        if entry[0] != '160000':
            require(entry[1] == 'blob', 'Unsupported committed object: ' + path)
            verify_working_blob(root, path, entry, data)
    verify_working_inventory(root, after)
    lock_bytes = data[after[DIAGNOSTIC_LOCK][2]]
    baseline_bytes = data[before[DIAGNOSTIC_LOCK][2]]
    require(baseline_bytes == git(root, 'show', accepted + ':' + DIAGNOSTIC_LOCK),
            'Diagnostic checkpoint lock differs from accepted production lock')
    frozen_pins = verify_diagnostic_lock(lock_bytes, baseline_bytes)
    receipt = None
    if lock_bytes == baseline_bytes:
        require(resolver_receipt_path is None and resolver_receipt_sha256 is None,
                'Pending unchanged lock cannot claim a diagnostic resolver receipt')
        lock_status = 'accepted_lock_retained_pending_resolution'
    else:
        receipt = approved_external_json(root, resolver_receipt_path, resolver_receipt_sha256,
                                         'Diagnostic resolver receipt')
        verify_diagnostic_resolver(root, receipt, lock_bytes, baseline_bytes, after)
        lock_status = 'reviewed_resolver_observed_lock'
    return {'owner': 'SideStore', 'status': 'diagnostic_dependency_transition_pass',
            'accepted': dict(DIAGNOSTIC_ACCEPTED),
            'source_checkpoint': dict(DIAGNOSTIC_SOURCE_CHECKPOINT), 'commit': commit, 'tree': tree,
            'diagnostic_basis_sha256': basis_sha256,
            'source_registry_sha256': DIAGNOSTIC_REGISTRY_SHA256,
            'source_delta_sha256': DIAGNOSTIC_DELTA_SHA256,
            'dependency_files': sorted(changed - DIAGNOSTIC_METADATA),
            'reviewed_metadata_files': sorted(DIAGNOSTIC_METADATA),
            'unchanged_checkpoint_blobs': sum(1 for p in after if p not in changed and after[p][1] == 'blob'),
            'child_gitlinks': {p: e[2] for p, e in after.items() if e[0] == '160000'},
            'child_identity_scope': 'approved_gitlink_only_child_tree_and_basis_require_outer_graph_proof',
            'unrelated_swiftpm_pins_preserved': frozen_pins,
            'lock_status': lock_status, 'lock_sha256': sha(lock_bytes),
            'origin_hash': observed_origin_hash(json.loads(lock_bytes)),
            'native_resolver_status': 'reviewed_diagnostic_resolution' if receipt else 'not_run_for_candidate',
            'resolver_receipt_sha256': resolver_receipt_sha256,
            'resolver_tested_commit': receipt['resolver_tested_commit'] if receipt else None,
            'resolver_tested_tree': receipt['resolver_tested_tree'] if receipt else None,
            'resolver_run_url': receipt['run_url'] if receipt else None,
            'native_validation_status': 'not_established_for_candidate',
            'historical_receipts_only': True,
            'readiness_scope': 'source_transition_only_requires_separate_native_receipt',
            'production_ready': False, 'runtime_source_changes': []}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--allow-pending-child-pins', action='store_true', help='Report preparation only; cannot establish cutover readiness')
    parser.add_argument('--diagnostic-basis', type=Path, help='External immutable diagnostic source transition basis')
    parser.add_argument('--diagnostic-basis-sha256', help='Separately reviewed SHA256 of exact basis bytes')
    parser.add_argument('--diagnostic-resolver-receipt', type=Path, help='External reviewed receipt for actual changed resolver lock')
    parser.add_argument('--diagnostic-resolver-receipt-sha256', help='Separately reviewed SHA256 of exact resolver receipt bytes')
    args = parser.parse_args()
    if any(value is not None for value in (args.diagnostic_basis, args.diagnostic_basis_sha256,
            args.diagnostic_resolver_receipt, args.diagnostic_resolver_receipt_sha256)):
        if args.allow_pending_child_pins:
            parser.error('--allow-pending-child-pins cannot be combined with diagnostic mode')
        result = verify_diagnostic(args.root, basis_path=args.diagnostic_basis,
            basis_sha256=args.diagnostic_basis_sha256,
            resolver_receipt_path=args.diagnostic_resolver_receipt,
            resolver_receipt_sha256=args.diagnostic_resolver_receipt_sha256)
    else:
        result = verify(args.root, allow_pending_child_pins=args.allow_pending_child_pins)
    print(json.dumps(result, indent=2))
