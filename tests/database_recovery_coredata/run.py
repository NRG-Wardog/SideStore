#!/usr/bin/env python3
"""Native exact production recovery + PersistentContainer, original model versions."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tests/database_recovery'))
from target_settings import inspect_project, PROJECT
SCHEMA = 'sidestore-exact-recovery-coredata-v2'
STATUS = 'PASS_NATIVE_EXACT_ENGINE_REAL_COREDATA'

def source_paths():
    model = ROOT/'AltStore/Core/Model/AltStore.xcdatamodeld'
    return [ROOT/'SideStore/DatabaseRecovery.swift', ROOT/'SideStore/DatabaseRecoverySQLite.c',
            ROOT/'AltStore/Core/Model/DatabaseManager/PersistentContainer.swift',
            ROOT/'AltStore/Core/Model/DatabaseManager/DatabaseManager.swift',
            ROOT/'SideStore/MaintenanceManager.swift', ROOT/'AltStore/Core/Model/InstalledApp.swift',
            ROOT/'tests/database_recovery_coredata/Cases.swift',
            ROOT/'tests/database_recovery_coredata/run.py',
            ROOT/'tests/database_recovery_coredata/test_contract.py',
            ROOT/'tests/database_recovery/target_settings.py', ROOT/PROJECT,
            *sorted(p for p in model.rglob('*') if p.is_file())]

def hashes():
    paths = source_paths()
    for path in paths:
        if (not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()) or
                any((ROOT/parent).is_symlink() for parent in path.relative_to(ROOT).parents)):
            raise RuntimeError('Missing, linked, or external qualification input.')
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}

def run(argv, log):
    result = subprocess.run([str(a) for a in argv], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=240)
    log.write_text(json.dumps({'stage': log.name, 'command': pathlib.Path(argv[0]).name}) + '\n' +
                   result.stdout + '\n' + json.dumps({'return_code': result.returncode}) + '\n')
    if result.returncode:
        raise RuntimeError(f"native stage failed: {log.name}")
    return result.stdout

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        raise SystemExit('Native macOS, CoreData, momc and swiftc are required; no skip or stub substitute.')
    output = args.output.resolve()
    if args.output.is_symlink() or output.exists() or output.is_relative_to(ROOT.resolve()) or ROOT.resolve().is_relative_to(output):
        raise SystemExit('Fresh output outside the source tree is required.')
    output.mkdir(parents=True)
    before_inputs = hashes()
    settings = inspect_project(ROOT)
    if settings['project_sha256'] != before_inputs[PROJECT]:
        raise RuntimeError('Project changed before build-setting inspection.')
    models = ROOT / 'AltStore/Core/Model/AltStore.xcdatamodeld'
    bundle = output / 'Models.bundle'
    resources = bundle / 'Contents/Resources'
    resources.mkdir(parents=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.example.sidestore.database-recovery-fixture',
        'CFBundleName': 'Models', 'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1'}))
    run(['xcrun', 'momc', '--macosx-deployment-target', '13.0', models, resources / 'AltStore.momd'], output/'momc.log')
    manager = (ROOT/'AltStore/Core/Model/DatabaseManager/DatabaseManager.swift').read_text()
    start, end = '// V3_DATABASE_STARTUP_OUTCOME_V1:', 'public class DatabaseManager:'
    assert manager.count(start) == manager.count(end) == 1
    diagnostics = output/'Diagnostics.swift'
    diagnostics.write_text('import Foundation\n' + manager[manager.index(start):manager.index(end)])
    shim = output/'sqlite-shim.o'
    run(['xcrun', 'clang', '-c', ROOT/'SideStore/DatabaseRecoverySQLite.c', '-o', shim], output/'clang.log')
    binary = output/'coredata-recovery'
    inputs = [ROOT/'SideStore/DatabaseRecovery.swift',
              ROOT/'AltStore/Core/Model/DatabaseManager/PersistentContainer.swift',
              ROOT/'tests/database_recovery_coredata/Cases.swift', diagnostics]
    run(['xcrun', 'swiftc', '-swift-version', settings['swiftc_argument'], '-parse-as-library', *inputs, shim,
         '-lsqlite3', '-o', binary], output/'swiftc.log')
    evidence = []
    for mode in ('delete', 'wal'):
        root = output/mode
        private = root/'private'
        private.mkdir(parents=True)
        run([binary, 'seed-'+mode, bundle, private/'AltStore.sqlite'], output/(mode+'-seed.log'))
        before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in private.iterdir()}
        if mode == 'wal' and (private/'AltStore.sqlite-wal').stat().st_size <= 32:
            raise RuntimeError('Real nonempty committed WAL required.')
        text = run([binary, 'recover', bundle, root], output/(mode+'-recover.log'))
        if 'EXACT_RECOVERY_ENGINE_AND_PERSISTENT_CONTAINER_COREDATA_PASS' not in text:
            raise RuntimeError('Required source-owned native success marker missing.')
        after = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in private.iterdir()}
        # SHM contains operational locks; SQLite may update it. Main/WAL must remain.
        for name, digest in before.items():
            if not name.endswith('-shm') and after.get(name) != digest:
                raise RuntimeError('Original persistent bytes changed: '+name)
        evidence.append({'mode': mode, 'status': 'PASS', 'original_persistent_bytes_unchanged': True})
    if hashes() != before_inputs:
        raise RuntimeError('Production/fixture inputs changed during Core Data qualification.')
    receipt = {'schema': SCHEMA, 'status': STATUS, 'cases': evidence,
               'inputs': before_inputs, 'swift_build_settings': settings,
               'swift_version': subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip(),
               'physical_device_execution': False, 'synthetic_data_only': True,
               'app_startup_or_installed_app_runtime_executed': False}
    (output/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print('Real Core Data recovery qualification passed.')

if __name__ == '__main__':
    main()
