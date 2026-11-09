"""Acquire and validate exact generated-input recipes for the maintained owner.

No product source is rewritten. Local frameworks are built from reviewed sources;
RemotePairingKit staging delegates to the source-bound production adapter.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

TOOLS = ('NRG-Wardog/sidestore-auto-refresh', 'f484876b791a4fe553f7bc1cfdf38b6d01efa667')
SOURCES = {
    'idevice': ('NRG-Wardog/idevice', '72c0044c62b4b28e813fb6670dfd4651622bf20a'),
    'jktcp': ('NRG-Wardog/jktcp', 'a46594f6af56b66b6d9342ed9f5ee6d1b7fb9cc9'),
    'RemotePairingKit': ('mahee96/RemotePairingKit', 'e3f70d16c0c551540a533a39d540e78e5b0a60a8'),
}
GITLINKS = {
    'Dependencies/SideSign': '3036cfb7803844842d604d17d9697ddbbbc4d50f',
    'Dependencies/minimuxer': '49c430dc46d87a330b45fa07d467b821983ccbfd',
}


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def exact_checkout(root, pin):
    require(root.is_dir() and not root.is_symlink(), 'Missing or linked source root')
    require(git(root, 'rev-parse', 'HEAD') == pin, 'Source commit differs: ' + str(root))
    require(not git(root, 'status', '--porcelain', '--untracked-files=no'), 'Tracked source differs: ' + str(root))
    return git(root, 'rev-parse', 'HEAD^{tree}')


def clone_exact(parent, name, repository, pin):
    root = parent / name
    require(not root.exists() and not root.is_symlink(), 'Refusing existing checkout: ' + str(root))
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    subprocess.run(['git', '-C', str(root), 'fetch', '--no-tags', '--depth=1',
                    'https://github.com/' + repository + '.git', pin], check=True)
    subprocess.run(['git', '-C', str(root), 'checkout', '--detach', 'FETCH_HEAD'], check=True)
    return exact_checkout(root, pin)


def lock_identity(value):
    require(value.get('version') == 3 and isinstance(value.get('pins'), list), 'Unsupported package lock')
    # originHash is resolver metadata; all package identities, locations and
    # revisions must remain exactly unchanged, including duplicate detection.
    pins = value['pins']
    require(len({p['identity'] for p in pins}) == len(pins), 'Duplicate package pin')
    return sorted(pins, key=lambda p: p['identity'])


def acquire(root, output):
    root = root.resolve(strict=True)
    require(not output.exists() and not output.is_symlink(), 'Refusing existing acquisition directory')
    require(not output.resolve().is_relative_to(root), 'Acquisition must be outside product checkout')
    output.mkdir(parents=True)
    for path, pin in GITLINKS.items():
        require(git(root, 'rev-parse', 'HEAD:' + path) == pin, 'Product gitlink differs: ' + path)
        exact_checkout(root / path, pin)
    identities = {'tools': clone_exact(output, 'tools', *TOOLS)}
    for name, (repository, pin) in SOURCES.items():
        identities[name] = clone_exact(output, name, repository, pin)
    graph = json.loads((output / 'tools/ci/issues-native/candidate-graph.json').read_text())['owners']
    for name, expected in SOURCES.items():
        require(graph.get(name) == list(expected), 'Orchestrator/source pin disagreement: ' + name)
    for name, pin in GITLINKS.items():
        require(graph['SideStore/' + name][1] == pin, 'Orchestrator gitlink disagreement: ' + name)
    lock = root / 'AltStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    receipt = {'product_head': git(root, 'rev-parse', 'HEAD'), 'recipe_commit': TOOLS[1],
               'trees': identities, 'gitlinks': GITLINKS,
               'package_pins': lock_identity(json.loads(lock.read_text()))}
    (output / 'source-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


def verify_locks(root, output):
    receipt = json.loads((output / 'source-receipt.json').read_text())
    require(receipt['recipe_commit'] == TOOLS[1] and receipt['gitlinks'] == GITLINKS, 'Input receipt changed')
    exact_checkout(output / 'tools', TOOLS[1])
    for path, pin in GITLINKS.items():
        exact_checkout(root / path, pin)
    lock_relative = 'AltStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    lock = root / lock_relative
    baseline = lock_identity(json.loads(git(root, 'show', 'HEAD:' + lock_relative)))
    require(receipt['package_pins'] == baseline, 'Source lock receipt differs from committed owner blob')
    require(lock_identity(json.loads(lock.read_text())) == baseline, 'Xcode changed package revisions or locations')
    exact_checkout(output / 'jktcp', SOURCES['jktcp'][1])
    exact_checkout(output / 'RemotePairingKit', SOURCES['RemotePairingKit'][1])
    idevice = output / 'idevice'
    require(git(idevice, 'rev-parse', 'HEAD') == SOURCES['idevice'][1], 'Transport source commit changed')
    changed = set(git(idevice, 'diff', '--name-only', 'HEAD').splitlines())
    require(changed <= {'ffi/idevice.h', 'cpp/include/idevice.h', 'swift/include/idevice.h'}, 'Transport build changed non-output sources')
    # The existing production overlay verifier checks the exact original source
    # tree, single admitted manifest delta and every generated byte/receipt.
    subprocess.run(['python3', '-B', '-c',
        'import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); import embedded; embedded.validate_embedded(Path(sys.argv[2]))',
        str(output / 'tools/ci/issue53-lts'), str(root / 'Dependencies/minimuxer')], check=True)
    receipt['resolved_lock_sha256'] = hashlib.sha256(lock.read_bytes()).hexdigest()
    (output / 'resolver-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['acquire', 'verify-locks'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    {'acquire': acquire, 'verify-locks': verify_locks}[args.action](args.root, args.output)
