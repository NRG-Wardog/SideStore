"""Historical run-bound transport proof, not a live/device connection test."""
import os, shutil, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
class TransportObservationTests(unittest.TestCase):
    def test_manifest_bound_before_queue_and_preserved_on_failure(self):
        source = (ROOT/'SideStore/Core/Operations/StandaloneOperations/BackgroundRefreshAppsOperation.swift').read_text()
        self.assertIn('self.refresh(filteredApps, runID: expectedRunID ?? refreshIdentifier)', source)
        self.assertLess(source.index('group.bindTransportObservation(to: runID)'), source.index('AppManager.shared.refresh(apps'))
        body = source.split('private func persistAutomaticRefreshVerification',1)[1].split('private func startListening',1)[0]
        self.assertIn('?? refreshIdentifier) == runID',body)
        self.assertIn('"run_id": runID',body)
        self.assertIn('manifest["transport_observation"] = observation',body)
        self.assertLess(body.index('case .failure'),body.index('group.transportObservationWire'))
        self.assertNotIn('installAcknowledged',body)
    def test_native_observation_requires_real_success_and_private_snapshot(self):
        runner=(ROOT/'SideStore/Core/Operations/PipelineRunner.swift').read_text()
        body=runner.split('let transportObservationConfiguration =',1)[1].split('try checkReadinessOwnership()\n        } catch',1)[0]
        self.assertEqual(body.count('try group.recordTransportReady('),2)
        self.assertEqual(body.count('configurationUnchanged: transportObservationConfiguration == .capture()'),2)
        self.assertIn('if case .success(true) = nativeResult',body)
        self.assertIn('case .success(true):\n                        try group.recordTransportReady',body)
        self.assertIn('if !CellularRefreshManager.shared.isEnabled {\n                let transportObservationConfiguration',runner)
        snapshot=runner.split('private struct V3TransportObservationConfiguration',1)[1].split('// V3_OWNED_REFRESH_READINESS_WAIT_V1:',1)[0]
        for field in ('gateway','core','startupGeneration','localVPN','peerOverride','remoteServer','remotePort','cellularEnabled'):
            self.assertIn(field,snapshot)
        self.assertNotIn('debugLog',snapshot)
    def test_actual_source_recording_and_native_return_boundaries(self):
        swift=shutil.which('swiftc')
        if not swift:
            if os.environ.get('REQUIRE_SWIFT_COLD_VPN_TESTS')=='1':self.fail('swiftc required')
            self.skipTest('swiftc unavailable; source checks only')
        group=(ROOT/'SideStore/Core/Operations/RefreshGroup.swift').read_text()
        observation=group.split('// V3_OWNED_TRANSPORT_OBSERVATION_V1:',1)[1].split('// V3_OWNED_TRANSPORT_OBSERVATION_END',1)[0]
        observation=observation[observation.index('struct V3OwnedTransportObservation'):]
        runner=(ROOT/'SideStore/Core/Operations/PipelineRunner.swift').read_text()
        config='private struct V3TransportObservationConfiguration'+runner.split('private struct V3TransportObservationConfiguration',1)[1].split('// V3_OWNED_REFRESH_READINESS_WAIT_V1:',1)[0]
        native='let nativeResult ='+runner.split('                    let nativeResult =',1)[1].split('                } else {',1)[0]
        source='import Foundation\n'+observation+'\n'+config+'\n'+(ROOT/'tests/cold_vpn_readiness/transport_observation_cases.swift').read_text()
        source=source.replace('// EXACT_NATIVE_BRANCH',native)
        remote=runner.split('// Remote and unconfigured routes retain',1)[1]
        remote='let nativeResult ='+remote.split('                    let nativeResult =',1)[1].split('\n                }\n            }',1)[0]
        source=source.replace('// EXACT_REMOTE_BRANCH',remote)
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp).resolve();(p/'main.swift').write_text(source)
            subprocess.run([swift,'-parse-as-library',str(p/'main.swift'),'-o',str(p/'fixture')],check=True)
            subprocess.run([str(p/'fixture')],check=True,timeout=30)
