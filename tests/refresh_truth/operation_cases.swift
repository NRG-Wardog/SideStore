@main struct OperationCases {
 static func main() async throws {
  let now=Date(); let cert=Data([7]); var passed:[String]=[]; var failed:[String]=[]
  func diagnostic(_ value:[String:Any]) {
   let data=try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
   FileHandle.standardError.write(data + Data([10]))
  }
  let absentOwner=URL(fileURLWithPath:"/synthetic/Host.app").resolvingSymlinksInPath().standardizedFileURL
  let absentChild=absentOwner.appendingPathComponent("PlugIns/Test.appex").resolvingSymlinksInPath().standardizedFileURL
  diagnostic(["fixture":"legacy-absent-path-counterfactual",
              "parentURLMatches":absentChild.deletingLastPathComponent()==absentOwner.appendingPathComponent("PlugIns"),
              "parentPathMatches":absentChild.deletingLastPathComponent().path==absentOwner.appendingPathComponent("PlugIns").path])
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("refresh-truth-owned-"+UUID().uuidString,isDirectory:true)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
  defer { try? FileManager.default.removeItem(at:root) }
  let hostURL=root.appendingPathComponent("Host.app",isDirectory:true)
  try FileManager.default.createDirectory(at:hostURL.appendingPathComponent("PlugIns/Test.appex",isDirectory:true),withIntermediateDirectories:true)
  Bundle.Info.activeBundleURL=hostURL.resolvingSymlinksInPath().standardizedFileURL
  let outside=root.appendingPathComponent("Other.app/PlugIns/Test.appex",isDirectory:true)
  try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
  let outsideURL=outside.resolvingSymlinksInPath().standardizedFileURL
  let escaped=Bundle.Info.activeBundleURL.appendingPathComponent("PlugIns/Escaped.appex",isDirectory:true)
  try FileManager.default.createSymbolicLink(at:escaped,withDestinationURL:outsideURL)
  func profile(_ id:Int,_ offset:Double,_ bundle:String="app") -> ALTProvisioningProfile {
   ALTProvisioningProfile(uuid:UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",id))!,data:Data([UInt8(id)]),bundleIdentifier:bundle,teamIdentifier:"T",expirationDate:now.addingTimeInterval(offset),certificates:[Cert(serialNumber:"S",data:cert)])
  }
  let old=profile(1,1000), fresh=profile(2,2000), oldExt=profile(3,1000,"app.ext"), freshExt=profile(4,2000,"app.ext")
  fixtureProfiles=Dictionary(uniqueKeysWithValues:[old,fresh,oldExt,freshExt].map{($0.data,$0)})
  func setup(_ extensions:Bool=false) -> InstallAppOperationContext {
   Injection.shared.count=0; Injection.shared.failAt=0; Injection.shared.after=nil; CellularRefreshManager.shared.duringOff=nil
   let c=InstallAppOperationContext(); c.verifiedRefreshCertificate=("S",cert,now.addingTimeInterval(3000))
   c.provisioningProfiles=["app":fresh]
   if extensions { c.provisioningProfiles?["app.ext"]=freshExt; c.dbBackgroundContext.app.appExtensions=[InstalledExtension()] }
   var reads=0
   c.readInstalledProvisioningProfiles={ reads += 1; return reads==1 ? (extensions ? [old.data,oldExt.data]:[old.data]) : (extensions ? [fresh.data,freshExt.data]:[fresh.data]) }
   return c
  }
  func check(_ id:String,_ condition: @autoclosure () -> Bool) {
   if condition() { passed.append(id) } else { failed.append(id);diagnostic(["fixtureFailure":id]) }
  }
  for variant in ["valid", "distinct-prefix", "wildcard-prefix", "wrong-embedded-team", "wrong-embedded-certificate", "wrong-team", "wrong-certificate", "missing-entitlement", "unrelated-extension", "wrong-prefix", "outside-plugins", "symlink-escape", "not-host", "duplicate-extension"] {
   let c=setup(); c.useMainProfile=true
   c.dbBackgroundContext.app.bundleIdentifier=StoreApp.altstoreAppID;c.bundleIdentifier=StoreApp.altstoreAppID
   let ext=InstalledExtension();ext.bundleIdentifier=StoreApp.altstoreAppID+".ext"
   c.dbBackgroundContext.app.appExtensions=[ext]
   let prefix=variant == "distinct-prefix" ? "APP-PREFIX" : "T"
   let appID=ALTEntitlement.applicationIdentifier, teamID=ALTEntitlement(rawValue:"com.apple.developer.team-identifier")
   var expected=fresh;expected.entitlements=[appID:variant == "wildcard-prefix" ? prefix+".*" : prefix+".app"]
   c.provisioningProfiles=["app":expected]
   let host=ALTApplication();host.entitlements=[appID:prefix+".app",teamID:"T"]
   let child=ALTApplication();child.bundleIdentifier="app.ext";child.fileURL=host.fileURL.appendingPathComponent("PlugIns/Test.appex",isDirectory:true).resolvingSymlinksInPath().standardizedFileURL
   child.entitlements=[appID:prefix+".app",teamID:"T"];child.provisioningProfile=old
   host.appExtensions=[child]
   if variant == "wrong-embedded-team" { child.provisioningProfile?.teamIdentifier="OTHER" }
   if variant == "wrong-embedded-certificate" { child.provisioningProfile?.certificates=[Cert(serialNumber:"S",data:Data([99]))] }
   if variant == "wrong-team" { child.entitlements[teamID]="OTHER" }
   if variant == "missing-entitlement" { child.entitlements.removeValue(forKey:appID) }
   if variant == "unrelated-extension" { child.bundleIdentifier="other.ext" }
   if variant == "wrong-prefix" { child.entitlements[appID]="WRONG.app" }
   if variant == "outside-plugins" { child.fileURL=outsideURL }
   if variant == "symlink-escape" { child.fileURL=escaped }
   if variant == "not-host" { c.dbBackgroundContext.app.bundleIdentifier="other.original";c.bundleIdentifier="other.original";ext.bundleIdentifier="other.original.ext" }
   if variant == "duplicate-extension" { host.appExtensions=[child,child] }
   fixtureApplications=[host.fileURL:host]
   fixtureCertificates=[child.fileURL.resolvingSymlinksInPath().standardizedFileURL:Cert(serialNumber:"S",data:variant == "wrong-certificate" ? Data([99]):cert)]
   var succeeded=false;var selectionFailure:V3RefreshSelectionFailure?
   do { _=try await RefreshAppOperation(context:c).execute(parentProgress:nil);succeeded=true } catch {
    selectionFailure=error as? V3RefreshSelectionFailure
    let canonicalOwner=Bundle.Info.activeBundleURL.resolvingSymlinksInPath().standardizedFileURL
    let canonicalChild=child.fileURL.resolvingSymlinksInPath().standardizedFileURL
    diagnostic(["fixture":"legacy-"+variant,
                "ownerLookup":fixtureApplications[canonicalOwner] != nil,
                "signedIDMatches":child.entitlements[appID] as? String == host.entitlements[appID] as? String,
                "teamMatches":child.entitlements[teamID] as? String == expected.teamIdentifier,
                "parentURLMatches":canonicalChild.deletingLastPathComponent()==canonicalOwner.appendingPathComponent("PlugIns"),
                "parentPathMatches":canonicalChild.deletingLastPathComponent().path==canonicalOwner.appendingPathComponent("PlugIns").path,
                "certificateLookup":fixtureCertificates[canonicalChild] != nil,
                "mutationCount":Injection.shared.count])
   }
   let allowed=variant == "valid" || variant == "distinct-prefix" || variant == "wildcard-prefix"
   let diagnosticMatches=allowed || (selectionFailure?.reason == (variant == "not-host" ? .legacyProofUnavailable:.legacyHostProofUnavailable) && selectionFailure?.scope == (variant == "not-host" ? .nonHost:.host))
   check("legacy-host-"+variant, succeeded == allowed && Injection.shared.count == (allowed ? 1:0) && diagnosticMatches)
   fixtureApplications=[:];fixtureCertificates=[:]
  }
  let authorizationCases: [(String,String,String,TimeInterval,Data,String)] = [
   ("exact","app","S",2000,cert,"app"), ("wildcard","*","S",2000,cert,"app"),
   ("prefix","app.*","S",2000,cert,"app"), ("wrong-prefix","other.*","S",2000,cert,"app"),
   ("empty-identity","","S",2000,cert,"app"), ("malformed-wildcard","app*","S",2000,cert,"app"),
   ("empty-serial","app","",2000,cert,"app"), ("expired","app","S",-1,cert,"app"),
   ("expiry-boundary","app","S",0,cert,"app"), ("wrong-certificate","app","S",2000,Data([99]),"app")
   ,("prefix-match","app.*","S",2000,cert,"app.child")
   ,("empty-signed-id","*","S",2000,cert,"")
   ,("trailing-dot","app.*","S",2000,cert,"app.")
  ]
  for (name,pattern,serial,offset,bytes,signedID) in authorizationCases {
   let c=setup();var expected=fresh;expected.bundleIdentifier=pattern;expected.expirationDate=now.addingTimeInterval(offset)
   c.dbBackgroundContext.app.resignedBundleIdentifier=signedID
   c.provisioningProfiles=["app":expected];c.verifiedRefreshCertificate=(serial,bytes,now.addingTimeInterval(3000))
   let expectedAdmission=V3RefreshVerification.authorizes(expected,signedID:signedID,certificateSerial:serial,certificateData:bytes,now:now)
   let op=RefreshAppOperation(context:c);op.verificationNow={now};var succeeded=false
   do {_=try await op.execute(parentProgress:nil);succeeded=true}catch{}
   check("selection-authorizer-parity-"+name,succeeded==expectedAdmission && Injection.shared.count==(expectedAdmission ? 1:0))
  }
  // Actual production selection errors are finite and pre-dispatch. Legacy
  // non-host metadata is intentionally not upgraded to installed binary proof.
  let selectionCases: [(String,V3RefreshSelectionFailure.Reason,(InstallAppOperationContext)->Void)] = [
   ("profiles",.missingRefreshProfiles,{ $0.provisioningProfiles=nil }),
   ("bundle",.missingTargetAppBundle,{ $0.targetAppBundle=nil }),
   ("main",.missingMainProfile,{ $0.provisioningProfiles=[:] }),
   ("certificate",.missingVerifiedCertificate,{ $0.verifiedRefreshCertificate=nil }),
   ("main-identity",.mainProfileIdentityMismatch,{ $0.provisioningProfiles?["app"]?.bundleIdentifier="other" }),
   ("main-expiry",.mainProfileExpired,{ $0.provisioningProfiles?["app"]?.expirationDate=now.addingTimeInterval(-1) }),
   ("main-certificate",.mainProfileCertificateMismatch,{ $0.provisioningProfiles?["app"]?.certificates=[] }),
   ("extension-parent",.extensionOutsideParent,{ $0.dbBackgroundContext.app.appExtensions=[InstalledExtension()];$0.dbBackgroundContext.app.appExtensions[0].bundleIdentifier="other.ext" }),
   ("legacy-nonhost",.legacyProofUnavailable,{ $0.useMainProfile=true;$0.dbBackgroundContext.app.appExtensions=[InstalledExtension()] }),
   ("extension-missing",.missingExtensionProfile,{ $0.dbBackgroundContext.app.appExtensions=[InstalledExtension()] }),
   ("keys",.unexpectedProfileKeys,{ $0.provisioningProfiles?["extra"]=fresh })
  ]
  for (name,expected,change) in selectionCases {
   let c=setup();change(c);var observed:V3RefreshSelectionFailure?
   do { _=try await RefreshAppOperation(context:c).execute(parentProgress:nil) }
   catch let failure as V3RefreshSelectionFailure { observed=failure }
   catch {}
   check("selection-diagnostic-"+name,observed?.reason == expected && observed?.scope == .nonHost && Injection.shared.count==0 && c.refreshVerification?.mutationDispatched != true)
  }
  let extensionSelectionCases: [(String,V3RefreshSelectionFailure.Reason,(inout ALTProvisioningProfile)->Void)] = [
    ("identity",.extensionProfileIdentityMismatch,{(p:inout ALTProvisioningProfile) in p.bundleIdentifier="other"}),
    ("expiry",.extensionProfileExpired,{(p:inout ALTProvisioningProfile) in p.expirationDate=now.addingTimeInterval(-1)}),
    ("certificate",.extensionProfileCertificateMismatch,{(p:inout ALTProvisioningProfile) in p.certificates=[]}),
    ("team",.extensionTeamMismatch,{(p:inout ALTProvisioningProfile) in p.teamIdentifier="OTHER"})
  ]
  for (name,expected,change) in extensionSelectionCases {
   let c=setup(true);var modified=freshExt;change(&modified);c.provisioningProfiles?["app.ext"]=modified
   var observed:V3RefreshSelectionFailure?
   do {_=try await RefreshAppOperation(context:c).execute(parentProgress:nil)}catch let failure as V3RefreshSelectionFailure {observed=failure}catch{}
   check("selection-diagnostic-extension-"+name, observed?.reason==expected && Injection.shared.count==0)
  }
  do {
   let c=setup(true); var recorded:V3RefreshVerification?; c.recordRefreshVerification={recorded=$0}
   _=try await RefreshAppOperation(context:c).execute(parentProgress:nil)
   check("actual-main-extension-selection", c.dbBackgroundContext.app.expirationDate==fresh.expirationDate && c.dbBackgroundContext.app.appExtensions[0].expirationDate==freshExt.expirationDate)
   check("actual-once-per-profile",Injection.shared.count==2 && recorded?.renewal == .extended)
  }
  do {
   let c=setup(true); Injection.shared.failAt=2; var recorded:V3RefreshVerification?;c.recordRefreshVerification={recorded=$0}
   do { _=try await RefreshAppOperation(context:c).execute(parentProgress:nil); fatalError("expectedfailure") } catch {}
   check("partial-ack-preserved", Injection.shared.count==2 && recorded?.mutationDispatched == true && recorded?.installAcknowledged == false)
  }
  do {
   let c=setup(); var stopped=false;c.readInstalledProvisioningProfiles={stopped=true;return [old.data]}
   let op=RefreshAppOperation(context:c);op.refreshAdmission={if stopped {throw ProbeError.stopped}}
   do {_=try await op.execute(parentProgress:nil);fatalError("expectedfailure")}catch{}
   check("before-read-cancel-no-mutation",Injection.shared.count==0)
  }
  do {
   let c=setup();var stopped=false;Injection.shared.after={stopped=true}
   c.readInstalledProvisioningProfiles={if stopped {throw ProbeError.stopped};return [old.data]}
   let op=RefreshAppOperation(context:c);op.refreshAdmission={if stopped {throw ProbeError.stopped}}
   _=try await op.execute(parentProgress:nil)
   check("after-ack-owner-expiry-persists",Injection.shared.count==1 && c.refreshVerification?.profileStore == .unavailable && c.dbBackgroundContext.app.expirationDate==fresh.expirationDate)
  }
  do {
   let c=setup();c.dbBackgroundContext.failUpdate=true;var recorded:V3RefreshVerification?;c.recordRefreshVerification={recorded=$0}
   do {_=try await RefreshAppOperation(context:c).execute(parentProgress:nil);fatalError("expectedfailure")}catch{}
   check("database-update-failure-keeps-ack",Injection.shared.count==1 && recorded?.profileStore == .matched)
  }
  do {
   let c=setup();c.provisioningProfiles?["unexpected"]=fresh
   do {_=try await RefreshAppOperation(context:c).execute(parentProgress:nil);fatalError("expectedfailure")}catch{}
   check("extra-dictionary-key-rejected-before-mutation",Injection.shared.count==0)
  }
  do {
   let c=setup(true);var changed=freshExt;changed.uuid=fresh.uuid;c.provisioningProfiles?["app.ext"]=changed
   do {_=try await RefreshAppOperation(context:c).execute(parentProgress:nil);fatalError("expectedfailure")}catch{}
   check("duplicate-uuid-different-bytes-before-mutation",Injection.shared.count==0)
  }
  for changedIdentity in [false,true] {
   let c=setup(true);var common=fresh;common.bundleIdentifier="*"
   var extensionProfile=common
   if changedIdentity { extensionProfile.bundleIdentifier="app.*" }
   c.provisioningProfiles=["app":common,"app.ext":extensionProfile]
   var succeeded=false
   do { _=try await RefreshAppOperation(context:c).execute(parentProgress:nil);succeeded=true } catch {}
   check(changedIdentity ? "duplicate-uuid-identity-drift-rejected" : "duplicate-uuid-identical-accepted",
         succeeded == !changedIdentity && Injection.shared.count == (changedIdentity ? 0:2))
  }
  do {
   let c=setup();c.verifiedRefreshCertificate=nil
   do {_=try await RefreshAppOperation(context:c).execute(parentProgress:nil);fatalError("expectedfailure")}catch{}
   check("unverified-certificate-no-mutation",Injection.shared.count==0)
  }
  do {
   let c=setup();c.readInstalledProvisioningProfiles={throw ProbeError.stopped}
   _=try await RefreshAppOperation(context:c).execute(parentProgress:nil)
   check("unavailable-baseline-not-fabricated",Injection.shared.count==1 && c.refreshVerification?.renewal == .unknown)
  }
  do {
   let c=setup();Injection.shared.failAt=1;var recorded:V3RefreshVerification?;c.recordRefreshVerification={recorded=$0}
   do {_=try await RefreshAppOperation(context:c).execute(parentProgress:nil);fatalError("expectedfailure")}catch{}
   check("lost-ack-dispatch-retained",Injection.shared.count==1 && recorded?.mutationDispatched == true && recorded?.installAcknowledged == false)
  }
  do {
   let c=setup();var recorded:V3RefreshVerification?;c.recordRefreshVerification={recorded=$0}
   _=try await RefreshAppOperation(context:c).execute(parentProgress:nil)
   c.dbBackgroundContext.failSave=true
   do { try await actualRunnerPersistence(dbContext:c.dbBackgroundContext); fatalError("expectedfailure") }
   catch { check("actual-runner-save-failure-retains-evidence", error is V3PostMutationPersistenceError && recorded?.installAcknowledged == true && Injection.shared.count==1) }
  }
  do {
   let c=setup();let op=RefreshAppOperation(context:c);var clock=now
   op.verificationNow={clock};c.readInstalledProvisioningProfiles={clock=now.addingTimeInterval(4000);return [old.data]}
   do {_=try await op.execute(parentProgress:nil);fatalError("expectedfailure")}catch{}
   check("expiry-during-baseline-prevents-first-dispatch",Injection.shared.count==0)
  }
  do {
   let group=EvidenceGroup()
   group.setVerification(V3RefreshVerification(installAcknowledged:false),for:"app")
   group.setVerification(V3RefreshVerification(installAcknowledged:false,mutationDispatched:false),for:"app")
   precondition(group.verification(for:"app")?.mutationDispatched == true)
   group.setVerification(V3RefreshVerification(),for:"app")
   group.setVerification(V3RefreshVerification(installAcknowledged:false),for:"app")
   check("actual-group-evidence-monotonic",group.verificationSnapshot()["app"]?.installAcknowledged == true)
  }
  let signed=FixtureSignedBundle(allAppBundles:[FixtureSignedPiece(provisioningProfile:fresh)])
  let signing=FixtureSigningCertificate(x509:FixtureX509(serialNumber:"S",data:cert,expiryDate:now.addingTimeInterval(3000)))
  do {
   let c=setup();var reads=0;c.readInstalledProvisioningProfiles={reads+=1;return reads==1 ? []:[fresh.data]}
   try await InstallationHarness(c).runInstall(resignedAppBundle:signed,certificate:signing)
   check("actual-install-new-baseline-unknown",Injection.shared.count==1 && c.refreshVerification?.profileStore == .matched && c.refreshVerification?.renewal == .unknown)
  }
  do {
   let c=setup();var reads=0;c.readInstalledProvisioningProfiles={reads+=1;if reads==2 {throw ProbeError.stopped};return [old.data]}
   try await InstallationHarness(c).runInstall(resignedAppBundle:signed,certificate:signing)
   check("actual-install-readback-unavailable-keeps-ack",Injection.shared.count==1 && c.refreshVerification?.installAcknowledged == true && c.refreshVerification?.profileStore == .unavailable)
  }
  do {
   let c=setup();Injection.shared.failAt=1
   do {try await InstallationHarness(c).runInstall(resignedAppBundle:signed,certificate:signing);fatalError("expectedfailure")}catch{}
   check("actual-install-lost-ack-keeps-dispatch",Injection.shared.count==1 && c.refreshVerification?.mutationDispatched == true && c.refreshVerification?.installAcknowledged == false)
  }
  do {
   let c=setup();var stopped=false;c.readInstalledProvisioningProfiles={stopped=true;return [old.data]}
   c.profileMutationAdmission={if stopped {throw ProbeError.stopped}}
   do {try await InstallationHarness(c).runInstall(resignedAppBundle:signed,certificate:signing);fatalError("expectedfailure")}catch{}
   check("actual-install-baseline-cancel-before-dispatch",Injection.shared.count==0 && c.refreshVerification == nil)
  }
  let result=try JSONSerialization.data(withJSONObject:["schema":"refresh-truth-operation-v1","status":failed.isEmpty ? "PASS":"FAIL","cases":passed,"failed_cases":failed],options:[.sortedKeys])
  FileHandle.standardOutput.write(result + Data([10]))
  precondition(failed.isEmpty,"Synthetic operation fixture failures recorded above")
 }
}
