"""Portable source contracts for the preserved headless pipeline.

These checks inspect maintained sources only. They neither execute Swift/native
fixtures nor establish that the application compiles or works on a real device.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(relative):
    return (ROOT / relative).read_text()


def project_objects(section):
    project = source("AltStore.xcodeproj/project.pbxproj")
    text = project.split(f"/* Begin {section} section */", 1)[1].split(
        f"/* End {section} section */", 1)[0]
    return dict(re.findall(
        r"^\t\t([A-F0-9]{24})[^\n]*? = \{(.*?)(?=^\t\t[A-F0-9]{24}|\Z)",
        text, re.M | re.S))


def target_membership():
    targets = project_objects("PBXNativeTarget")
    target = next(key for key, body in targets.items()
                  if re.search(r"\bname = SideStore;", body))
    groups = project_objects("PBXFileSystemSynchronizedRootGroup")
    exceptions = project_objects("PBXFileSystemSynchronizedBuildFileExceptionSet")
    included, excluded = set(), set()
    for key, body in groups.items():
        if key not in targets[target]:
            continue
        root = re.search(r"\bpath = ([^;]+);", body).group(1).strip('"')
        excluded_paths = set()
        for exception_key, exception in exceptions.items():
            if exception_key not in body or f"target = {target}" not in exception:
                continue
            match = re.search(r"membershipExceptions = \((.*?)\);", exception, re.S)
            if match:
                excluded_paths.update(line.strip().rstrip(',').strip('"')
                                      for line in match.group(1).splitlines() if line.strip())
        for file in (ROOT / root).rglob("*.swift"):
            relative = file.relative_to(ROOT).as_posix()
            if file.relative_to(ROOT / root).as_posix() in excluded_paths:
                excluded.add(relative)
            else:
                included.add(relative)
    return included, excluded


class HeadlessPipelineCompatibility(unittest.TestCase):
    def test_legacy_ui_and_alternate_flows_are_excluded(self):
        included, excluded = target_membership()
        self.assertTrue(included)
        self.assertTrue(excluded)
        for path in [
            "SideStore/Core/Auth/Flows/CertificateProvisioningFlow.swift",
            "SideStore/Core/Auth/Flows/CodeSignValidationFlow.swift",
            "SideStore/Core/Auth/Flows/DeviceRegistrationFlow.swift",
            "SideStore/Handlers/SignInFlowHandler.swift",
            "SideStore/DeepLinks/InstallAppDialog.swift",
            "SideStore/DeepLinks/ExportPairingFileHandler.swift",
            "SideStore/DeepLinks/FileImportHandler.swift",
        ]:
            self.assertIn(path, excluded)
        self.assertFalse([path for path in included if path.startswith("SideStore/Views/")])
        self.assertIn("SideStore/Core/Operations/UserCustomizationTargets.swift", included)

    def test_non_ui_values_have_single_included_definitions(self):
        included, _ = target_membership()
        values = source("SideStore/Core/Operations/UserCustomizationTargets.swift")
        self.assertIn("import SideSign", values)
        self.assertIn("case prompt = \"prompt\"", values)
        for name in ["InfoPlistTarget", "EntitlementsTarget", "AppImportSourceMode"]:
            pattern = rf"\b(?:struct|enum)\s+{name}\b"
            owners = [path for path in included if re.search(pattern, source(path))]
            self.assertEqual(owners, ["SideStore/Core/Operations/UserCustomizationTargets.swift"], name)

    def test_new_customizations_do_not_implicitly_approve(self):
        handler = source("SideStore/Core/Operations/PipelineExecutionHandler.swift")
        defaults = handler.split("extension UserCustomizationHandler {", 1)[1]
        self.assertEqual(defaults.count("requires a supported host prompt."), 6)
        self.assertEqual(defaults.count("throw OperationError.invalidParameters("), 6)
        self.assertNotIn("return nil", defaults)
        self.assertNotIn("return true", defaults)

    def test_provisioning_skip_and_certificate_creation_remain_fail_closed(self):
        operation = source("SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift")
        branch = operation.split("case .cancel, .skip:", 1)[1].split("private func silentSignIn", 1)[0]
        self.assertIn("throw OperationError.cancelled", branch)
        self.assertIn("diagnosticError.requiresReconciliation || diagnosticError.portalSessionRejected", branch)
        self.assertNotIn("return", branch)
        self.assertIn("purpose: .provisioning", operation)
        self.assertIn("reconcilePendingCertificateCreation", operation)
        self.assertNotIn("CertificateProvisioningFlow(", operation)

    def test_refresh_group_retains_one_mutable_context(self):
        group = source("SideStore/Core/Operations/RefreshGroup.swift")
        self.assertIn("let context: StandaloneOperationContext", group)
        self.assertIn("var dbContext: NSManagedObjectContext { context.dbBackgroundContext }", group)
        self.assertIn("set { context.error = newValue }", group)
        self.assertNotIn("var context: StandaloneOperationContext {", group)

    def test_profile_customization_and_install_logs_redact_identities(self):
        for path in [
            "SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift",
            "SideStore/Core/Operations/PipelineOperations/UserCustomizationOperation.swift",
            "SideStore/Core/Operations/PipelineOperations/InstallAppOperation.swift",
            "SideStore/Core/Profiles/ProfileManager.swift",
        ]:
            text = source(path)
            for line in text.splitlines():
                if "debugLog(" not in line and "verboseLog(" not in line:
                    continue
                for forbidden in [".identifier", ".bundleIdentifier", ".groupIdentifier", ".uuid",
                                  ".name)", ".path)", "\\(error", "\\(teamID", "\\(resolvedID",
                                  "\\(applicationGroups)", "\\(groupIDs)", "\\(Array("]:
                    self.assertNotIn(forbidden, line, path)
            self.assertNotIn("Extension Bundle Mapping:", text)
            self.assertNotIn("verboseLog(targetAppBundle.dumpMachOInfo())", text)

    def test_certificate_lookup_logs_no_paths_or_account_identity(self):
        certificate = source("SideStore/Core/Certificates/CertificateManager.swift")
        for line in certificate.splitlines():
            if "debugLog(" not in line and "verboseLog(" not in line:
                continue
            for forbidden in ["\\(error", ".path)", ".lastPathComponent)",
                              ".serialNumber", ".name)", "\\(bundleID)"]:
                self.assertNotIn(forbidden, line)


if __name__ == "__main__":
    unittest.main()
