#!/usr/bin/env python3
"""Compile the exact production Swift/C engine and run native synthetic qualification.

Unsupported hosts fail explicitly. This runner never reports a skipped native run
as a passing qualification. All generated stores are synthetic and scratch-owned.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from target_settings import inspect_project, PROJECT
SCHEMA = 'sidestore-exact-recovery-sqlite-v2'
EXPECTED_CASES = {
    'wal-and-process-lease', 'wal-relocation-and-resume', 'identical-databases',
    'different-databases', 'identical-apps', 'different-apps',
    'apps-changed-before-publication', 'malformed-receipt', 'source-symlink',
    'apps-symlink', 'orphan-sidecar', 'real-rollback-journal',
    'validation-failure-before-promotion', 'racer-created-generation',
    'source-ancestor-symlink',
    'process-exit-before-publication', 'process-exit-after-publication-and-divergence',
}

def source_paths(root: pathlib.Path = ROOT) -> list[pathlib.Path]:
    return [root / 'SideStore/DatabaseRecovery.swift',
            root / 'SideStore/DatabaseRecoverySQLite.c', root / 'tests/database_recovery/main.swift',
            root / 'tests/database_recovery/run.py', root / 'tests/database_recovery/test_runner.py',
            root / 'tests/database_recovery/target_settings.py', root / PROJECT]

def sha(path: pathlib.Path) -> str:
    if (not path.is_file() or path.is_symlink() or
            not path.resolve().is_relative_to(ROOT.resolve()) or
            any((ROOT/parent).is_symlink() for parent in path.relative_to(ROOT).parents)):
        raise RuntimeError('Missing, linked, or external qualification input.')
    return hashlib.sha256(path.read_bytes()).hexdigest()

def require_native() -> None:
    if platform.system() != 'Darwin':
        raise RuntimeError('Native qualification requires macOS; NOT RUN on this host.')
    for command in ('swiftc', 'clang', 'xcrun'):
        if not shutil.which(command):
            raise RuntimeError(f'Required native tool unavailable: {command}; NOT RUN.')

def run(command: list[str], log: pathlib.Path) -> None:
    with log.open('w') as stream:
        stream.write(json.dumps({'stage': log.name, 'command': pathlib.Path(command[0]).name}) + '\n')
        stream.flush()
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=600)
        stream.write('\n' + json.dumps({'return_code': result.returncode}) + '\n')
        result.check_returncode()

def verify_report(report: dict) -> None:
    if report.get('status') != 'PASS_NATIVE_EXACT_ENGINE_SYNTHETIC_SQLITE':
        raise RuntimeError('Native report lacks success status.')
    cases = report.get('cases', [])
    if set(cases) != EXPECTED_CASES or len(cases) != len(EXPECTED_CASES):
        raise RuntimeError('Native report has missing, duplicate, or unexpected cases.')
    if report.get('production_coredata_validation') is not False:
        raise RuntimeError('Synthetic qualification must not claim Core Data coverage.')

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        raise SystemExit('Fresh output is required; existing evidence will not be replaced.')
    output = args.output.resolve()
    source = ROOT.resolve(strict=True)
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise SystemExit('Output must be outside the source tree.')
    output.mkdir(parents=True)
    try:
        require_native()
        paths = source_paths()
        hashes = {str(p.relative_to(ROOT)): sha(p) for p in paths}
        settings = inspect_project(ROOT)
        if settings['project_sha256'] != hashes[PROJECT]:
            raise RuntimeError('Project changed before build-setting inspection.')
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        with tempfile.TemporaryDirectory(prefix='sidestore-recovery-native-') as temporary:
            # macOS temporary roots commonly pass through /var -> /private/var.
            # Production resolve canonicalizes approved roots before NOFOLLOW opens.
            work = pathlib.Path(temporary).resolve(strict=True)
            obj, binary = work / 'shim.o', work / 'fixture'
            run(['clang', '-isysroot', sdk, '-c', str(paths[1]), '-o', str(obj)], output / 'compile-c.log')
            run(['swiftc', '-swift-version', settings['swiftc_argument'], '-sdk', sdk, str(paths[0]),
                 str(paths[2]), str(obj), '-lsqlite3', '-o', str(binary)], output / 'compile-swift.log')
            fixture_output = work / 'fixtures'
            run([str(binary), str(fixture_output)], output / 'native.log')
            report = json.loads((fixture_output / 'report.json').read_text())
            verify_report(report)
            report['schema'] = SCHEMA
            report['source_sha256'] = hashes
            report['swift_build_settings'] = settings
            report['swift_version'] = subprocess.check_output(['swiftc', '--version'], text=True).strip()
            report['platform'] = platform.platform()
            report['exact_production_sources_compiled_without_rewriting'] = True
        if {str(p.relative_to(ROOT)): sha(p) for p in paths} != hashes:
            raise RuntimeError('Production inputs changed during qualification.')
        (output / 'report.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
        print('PASS_NATIVE_EXACT_ENGINE_SYNTHETIC_SQLITE')
        return 0
    except Exception as error:
        (output / 'failure.json').write_text(json.dumps({'status': 'FAILED_OR_NOT_RUN', 'error': str(error)}, indent=2) + '\n')
        print(f'QUALIFICATION_FAILED_OR_NOT_RUN: {error}', file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
