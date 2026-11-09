"""Compile exact production diagnostic declarations; no behavioral substitutes."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
OWNER = ROOT / "AltStore/AppDelegate.swift"
NAMES = ("V3TemporaryADIConsumption", "V3ProvisioningCauseDiagnostic",
         "V3AuthenticationRequestSnapshot", "V3AuthenticationHeaderProvenance",
         "V3AuthenticationProviderObservation", "V3AuthenticationDiagnostics",
         "V3LoginDiagnosticSnapshot", "V3TemporaryAnisetteTrace")


def production_source():
    text = OWNER.read_text()
    declarations = []
    for name in NAMES:
        kind = "enum" if name == "V3AuthenticationDiagnostics" else "struct"
        anchor = f"public {kind} {name}"
        assert text.count(anchor) == 1, anchor
        start = text.index(anchor)
        opening = text.index("{", start)
        depth = 0
        for end in range(opening, len(text)):
            if text[end] == "{": depth += 1
            elif text[end] == "}": depth -= 1
            if depth == 0:
                declarations.append(text[start:end + 1])
                break
        else:
            raise AssertionError(f"Unclosed declaration: {name}")
    return "import Foundation\n" + "\n".join(declarations)


class DiagnosticBoundingTests(unittest.TestCase):
    def compile_and_run(self, source):
        compiler = shutil.which("swiftc")
        self.assertIsNotNone(compiler, "Native Swift toolchain is required; do not skip")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "main.swift"
            binary = Path(directory) / "diagnostics"
            path.write_text(source + "\n" + (ROOT / "tests/authentication/diagnostic_bounding.swift").read_text())
            result = subprocess.run([compiler, str(path), "-o", str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            return subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)

    def test_actual_owner_preserves_lossless_state_and_bounds(self):
        result = self.compile_and_run(production_source())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS diagnostic bounds: 8 cases", result.stdout)

    def test_regression_mutant_is_detected(self):
        source = production_source()
        fixed = 'var trimmed = fields != raw\n        if fields[stateKey] == nil { fields[stateKey] = "recorded" }'
        broken = 'if fields[stateKey] == nil { fields[stateKey] = "recorded" }\n        var trimmed = fields != raw'
        self.assertEqual(source.count(fixed), 1)
        result = self.compile_and_run(source.replace(fixed, broken))
        self.assertNotEqual(result.returncode, 0, "Original bookkeeping bug must fail")
        self.assertIn("lossless state", result.stderr)
