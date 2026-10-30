#!/usr/bin/env python3
"""Offline generator contract tests. These do not claim Swift compilation/runtime."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("remote_identity_generator", HERE / "generate_fixture.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GeneratorTests(unittest.TestCase):
    def test_production_diagnostic_policy_closure(self):
        production = (HERE.parents[1] / "SideStore/Core/Anisette/V3DiagnosticProviderSequence.swift").read_text()
        declarations = "\n".join(module.extract(production, anchor) for anchor in
                                 ["enum V3DiagnosticProvider:", "enum V3DiagnosticProviderRoute {"])
        projection = declarations + "\nlet selected = V3DiagnosticProviderRoute.current"
        module.validate_diagnostic_policy_closure(projection, production)
        for invalid in ["let selected = V3DiagnosticProviderRoute.current",
                        projection + declarations,
                        projection.replace("case remoteMac, onDevice, remoteServer", "case remoteMac"),
                        projection + "\nlet missing: V3DiagnosticNewPolicy"]:
            with self.assertRaises(ValueError):
                module.validate_diagnostic_policy_closure(invalid, production)
        self.assertEqual(module.CANDIDATE_ONLY_SOURCES, {"diagnostic_policy"})
        self.assertEqual(module.SOURCE_PATHS["diagnostic_policy"],
                         "SideStore/SideStore/Core/Anisette/V3DiagnosticProviderSequence.swift")

    def test_background_run_binding_boundary_closure(self):
        root = HERE.parents[2]
        sources = {name: module.read(root, path) for name, path in module.SOURCE_PATHS.items()}
        generated = module.runtime_projection(sources, []).decode()
        actual = module.extract(sources['background'].decode(), 'private func refresh(_ apps:')
        self.assertIn(actual, generated)
        self.assertIn('refresh(apps, runID: "11111111-2222-3333-4444-555555555555")', generated)
        doubles = (HERE / 'RuntimeDoubles.swift').read_text()
        self.assertIn('func bindTransportObservation(to runID: String) { boundTransportRunID = runID }', doubles)
        self.assertIn('group: RefreshGroup, runID: String)', doubles)
        self.assertIn('persistedRunID = runID', doubles)
        cases = (HERE / 'RuntimeCases.swift').read_text()
        self.assertIn('operation.persistedVerificationGroup?.boundTransportRunID == operation.persistedRunID', cases)

    def test_braces_inside_comments_and_strings(self):
        source = 'func actual() { let x = "}"; /* nested { /* } */ */ if true { print(x) } }\nfunc next() {}'
        self.assertEqual(module.extract(source, "func actual()"), source.split("\n")[0])

    def test_duplicate_anchor_is_rejected(self):
        with self.assertRaises(ValueError):
            module.extract("func f() {}\nfunc f() {}", "func f()")

    def test_unterminated_declaration_is_rejected(self):
        with self.assertRaises(ValueError):
            module.extract("func f() {", "func f()")

    def test_exact_marker_bytes_are_preserved(self):
        source = "before\n// X_BEGIN\n// {}\nlet value = 1\n// X_END\nafter"
        self.assertEqual(module.marked(source, "X"), "// X_BEGIN\n// {}\nlet value = 1\n// X_END")

    def test_duplicate_marker_is_rejected(self):
        with self.assertRaises(ValueError):
            module.marked("// X_BEGIN\n// X_END\n// X_END", "X")

    def test_missing_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                module.read(Path(temporary), "missing.swift")

    def test_symlink_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / "real").write_text("real")
            (root / "link").symlink_to("real")
            with self.assertRaises(ValueError):
                module.read(root, "link")

    def test_read_returns_actual_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); path = root / "source"
            path.write_bytes(b"one\r\n"); self.assertEqual(module.read(root, "source"), b"one\r\n")
            path.write_bytes(b"two\n"); self.assertEqual(module.read(root, "source"), b"two\n")


if __name__ == "__main__":
    unittest.main()
