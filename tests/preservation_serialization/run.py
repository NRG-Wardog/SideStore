#!/usr/bin/env python3
"""Mandatory source-extracted native lane suite; never synthesize unittest results."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('-v', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    swift = shutil.which('swiftc')
    if not swift:
        raise SystemExit('swiftc required: preservation serialization native suite NOT RUN')
    env = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'}
    def run(command, timeout=180):
        subprocess.run(command, check=True, env=env, timeout=timeout)
    suite = root / 'tests/preservation_serialization'
    run([sys.executable, '-B', str(suite / 'test_contract.py'), '--repo', str(root)])
    with tempfile.TemporaryDirectory(prefix='preservation-serialization-') as tmp:
        output = Path(tmp)
        run([sys.executable, '-B', str(suite / 'generate_fixture.py'), '--repo', str(root), '--out', str(output)])
        run([swift, '-parse-as-library', str(output / 'preservation-serialization.swift'), '-o', str(output / 'cases')])
        run([str(output / 'cases')], timeout=60)


if __name__ == '__main__':
    main()
