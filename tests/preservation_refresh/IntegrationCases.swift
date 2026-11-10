@main struct PreservationIntegrationCases {
 static func main() async throws {
  let now=Date(); let der=Data([7]); var passed:[String]=[]
  func profile(_ number:Int,_ lifetime:Double,_ group:String="group.existing") -> ALTProvisioningProfile {
   AuthenticatedAdapterCases.register(number,lifetime,now:now,group:group)
  }
  let old=profile(1,1000), fresh=profile(2,2000), changed=profile(3,2000,"group.changed"), concurrent=profile(4,1500)
  func setup(changedAtFreshRead:Bool=false, missing:Bool=false, rebindAtFreshRead:Bool=false, postread:String="matched") -> InstallAppOperationContext {
   FixturePreservationTransport.reset()
   Injection.shared.count=0;Injection.shared.failAt=0;Injection.shared.after=nil
   CellularRefreshManager.shared.duringOff=nil
   FixtureCMSBoundary.calls=0;FixtureCMSBoundary.failure=nil;FixtureCMSBoundary.innerFailures=[:]
   FixtureCMSBoundary.duringCall=nil;FixtureCMSBoundary.inspectionCalls=0;FixtureCMSBoundary.inspectionFailures=[:];FixtureCMSBoundary.duringInspection=nil
   PortalProbe.shared.resetOrigin()
   PortalProbe.shared.calls=[];PortalProbe.shared.appIDs=[FixtureAppID(bundleIdentifier:"app")];PortalProbe.shared.candidate=fresh;PortalProbe.shared.failDownload=false
   let c=InstallAppOperationContext();c.isPreservationRefresh=true;c.useMainProfile=true;c.installedApp!.useMainProfile=true;c.targetAppBundle=nil
   c.verifiedRefreshCertificate=("S",der,now.addingTimeInterval(5000))
   let ext=InstalledExtension();ext.expirationDate=now.addingTimeInterval(800);c.installedApp!.appExtensions=[ext]
   var reads=0
   c.readInstalledProvisioningProfiles={
    reads += 1;PortalProbe.shared.calls.append("read")
    if missing { return [] }
    if rebindAtFreshRead && reads==3 { c.installedApp!.bundleIdentifier="different.original" }
    if changedAtFreshRead && reads==3 { return [concurrent.data] }
    if Injection.shared.count>0 {
     if postread=="unavailable" { throw ProbeError.stopped }
     if postread=="mismatch" { return [old.data] }
     return [old.data,fresh.data]
    }
    return [old.data]
   }
   c.profileMutationAdmission={ try Task.checkCancellation() }
   return c
  }
  func run(_ c:InstallAppOperationContext) async throws {
   c.provisioningProfiles=try await FetchHarness(context:c).run()
   let op=RefreshAppOperation(context:c);op.verificationNow={now};op.refreshAdmission=c.profileMutationAdmission
   _=try await op.execute(parentProgress:nil)
   let metadata=MetadataHarness(context:c)
   try await metadata.execute(parentProgress:nil)
   precondition(metadata.progress.completedUnitCount==100)
  }
  do {
   let c=setup();let expiry=c.installedApp!.appExtensions[0].expirationDate
   try await run(c)
   precondition(Injection.shared.count==1)
   precondition(PortalProbe.shared.calls==["read","team","lookup-existing-id","origin-operation","generate-existing-id-profile","read","read","read"])
   precondition(c.refreshVerification?.installAcknowledged==true)
   precondition(c.refreshVerification?.profileStore == .matched)
   precondition(c.refreshVerification?.renewal == .extended)
   precondition(c.refreshVerification?.preservation == "authorizationPreserved")
   precondition(c.refreshVerification?.certificate == "valid")
   precondition(c.installedApp!.expirationDate == fresh.expirationDate)
   precondition(c.installedApp!.appExtensions[0].expirationDate==expiry)
   passed.append("actual-fetch-refresh-preserves-identity-and-extension-metadata")
  }
  do {
   let c=setup(changedAtFreshRead:true)
   do { try await run(c);fatalError("changed snapshot accepted") }
   catch let e as V3RefreshSelectionFailure { precondition(e.reason == .preservationSnapshotChanged) }
   precondition(Injection.shared.count==0);passed.append("changed-snapshot-no-install")
  }
  do {
   let c=setup();Injection.shared.failAt=1
   do { try await run(c);fatalError("lost ACK accepted") } catch {}
   precondition(Injection.shared.count==1 && c.refreshVerification?.installAcknowledged==false)
   precondition(c.installedApp!.expirationDate==Date(timeIntervalSince1970:0))
   passed.append("lost-ack-single-dispatch-no-replay-no-bookkeeping")
  }
  do {
   let c=setup(missing:true)
   do { try await run(c);fatalError("missing inventory accepted") } catch {}
   precondition(!PortalProbe.shared.calls.contains("lookup-existing-id") && Injection.shared.count==0)
   passed.append("missing-evidence-no-portal-generation")
  }
  do {
   let c=setup();PortalProbe.shared.candidate=changed
   do { try await run(c);fatalError("changed groups accepted") } catch {}
   precondition(Injection.shared.count==0);passed.append("changed-app-groups-no-install")
  }
  do {
   let c=setup();PortalProbe.shared.appIDs=[]
   do { try await run(c);fatalError("missing portal identity accepted") } catch {}
   precondition(!PortalProbe.shared.calls.contains("generate-existing-id-profile") && Injection.shared.count==0)
   passed.append("missing-existing-id-no-registration")
  }
  do {
   let c=setup();PortalProbe.shared.appIDs += PortalProbe.shared.appIDs
   do { try await run(c);fatalError("duplicate portal identity accepted") } catch {}
   precondition(!PortalProbe.shared.calls.contains("generate-existing-id-profile") && Injection.shared.count==0)
   passed.append("ambiguous-existing-id-no-generation")
  }
  do {
   let c=setup();c.overrideProvisioningProfile=fresh
   do { try await run(c);fatalError("supplied profile without fresh origin accepted") } catch {}
   precondition(!PortalProbe.shared.calls.contains("lookup-existing-id") && Injection.shared.count==0)
   precondition(PortalProbe.shared.corroboratedUUIDs==[fresh.uuid])
   precondition(c.refreshVerification==nil && c.installedApp!.expirationDate==Date(timeIntervalSince1970:0))
   passed.append("provided-profile-no-fresh-origin-rejected")
  }
  do {
   let c=setup();c.profileMutationAdmission={throw CancellationError()}
   do { try await run(c);fatalError("cancelled accepted") } catch {}
   precondition(PortalProbe.shared.calls.isEmpty && Injection.shared.count==0)
   passed.append("cancelled-before-observation")
  }
  for variant in ["db-serial", "missing-serial", "db-team", "history-der"] {
   let c=setup()
   switch variant {
   case "db-serial": c.installedApp!.certificateSerialNumber="OTHER"
   case "missing-serial": c.verifiedRefreshCertificate=("",der,now.addingTimeInterval(5000))
   case "db-team": c.installedApp!.team=FixtureStoredTeam(identifier:"OTHER")
   default:
    c.acknowledgedReuseMainIdentity=V3ValidatedReuseMainRegistry.AcknowledgedIdentity(
     original:"app",resigned:"app",sourceFingerprint:"synthetic",sourceDigest:"synthetic",profileUUID:old.uuid,
     generation:UUID().uuidString,teamID:"T",certificateDER:Data([99]),extensionIdentities:[:],reusedExtensionIdentifiers:[])
   }
   do { try await run(c);fatalError("contradictory historical identity accepted") } catch {}
   precondition(!PortalProbe.shared.calls.contains("lookup-existing-id") && Injection.shared.count==0)
   passed.append("reject-"+variant+"-before-portal")
  }
  do {
   let c=setup(rebindAtFreshRead:true)
   do { try await run(c);fatalError("fresh DB original identity drift accepted") }
   catch let e as V3RefreshSelectionFailure { precondition(e.reason == .preservationIdentityUnavailable) }
   precondition(Injection.shared.count==0)
   passed.append("fresh-read-db-original-identity-drift-no-install")
  }
  for outcome in ["unavailable", "mismatch"] {
   let c=setup(postread:outcome)
   c.installedApp!.expirationDate=old.expirationDate
   let oldMain=c.installedApp!.expirationDate, oldExtension=c.installedApp!.appExtensions[0].expirationDate
   do { try await run(c);fatalError("unverified preservation reported success") }
   catch let failure as V3PreservationPostDispatchFailure {
    switch (outcome,failure) {
    case ("unavailable",.verificationUnavailable),("mismatch",.verificationMismatch): break
    default: fatalError("wrong preservation post-dispatch failure")
    }
   }
   precondition(Injection.shared.count==1 && c.refreshVerification?.installAcknowledged==true)
   precondition(c.refreshVerification?.profileStore == (outcome=="unavailable" ? .unavailable : .mismatch))
   precondition(c.refreshVerification?.renewal == .unknown)
   precondition(c.installedApp!.expirationDate==oldMain && c.installedApp!.appExtensions[0].expirationDate==oldExtension)
   passed.append("postread-"+outcome+"-preserves-main-and-extension-expiry")
  }
  do {
   let c=setup();var admissionRevoked=false
   c.profileMutationAdmission={ if admissionRevoked { throw CancellationError() } }
   CellularRefreshManager.shared.duringOff={ admissionRevoked=true }
   let oldMain=c.installedApp!.expirationDate, oldExtension=c.installedApp!.appExtensions[0].expirationDate
   do { try await run(c);fatalError("expired injection admission accepted") }
   catch is CancellationError {}
   precondition(PortalProbe.shared.calls.contains("generate-existing-id-profile"))
   precondition(Injection.shared.count==0 && c.refreshVerification==nil)
   precondition(c.installedApp!.expirationDate==oldMain && c.installedApp!.appExtensions[0].expirationDate==oldExtension)
   passed.append("admission-revoked-after-preflight-before-injection")
  }
  do {
   // Normal active-certificate installs intentionally persist no override serial.
   // The verified cached signer DER remains mandatory; a conflicting NONNIL
   // recorded serial is tested independently above.
   let c=setup();c.installedApp!.certificateSerialNumber=nil
   let oldExtension=c.installedApp!.appExtensions[0].expirationDate
   try await run(c)
   precondition(Injection.shared.count==1 && c.refreshVerification?.installAcknowledged==true)
   precondition(c.refreshVerification?.profileStore == .matched && c.refreshVerification?.renewal == .extended)
   precondition(c.refreshVerification?.preservation == "authorizationPreserved")
   precondition(c.installedApp!.expirationDate==fresh.expirationDate)
   precondition(c.installedApp!.appExtensions[0].expirationDate==oldExtension)
   precondition(c.installedApp!.certificateSerialNumber==nil)
   passed.append("normal-install-nil-recorded-serial-preserved-refresh")
  }
  do {
   let c=setup()
   c.readInstalledProvisioningProfiles={ PortalProbe.shared.calls.append("read"); return [old.data,changed.data] }
   let oldMain=c.installedApp!.expirationDate, oldExtension=c.installedApp!.appExtensions[0].expirationDate
   do { try await run(c);fatalError("conflicting baseline accepted") }
   catch let e as V3RefreshSelectionFailure {
    precondition(e.reason == .preservationAuthorityConflict && e.scope == .nonHost)
    precondition(e.preservationConflict == "entitlementsDiffer")
    precondition(e.facts["preservation_conflict"] == "entitlementsDiffer")
   }
   precondition(PortalProbe.shared.calls == ["read","team"])
   precondition(Injection.shared.count==0 && c.refreshVerification==nil)
   precondition(c.installedApp!.expirationDate==oldMain && c.installedApp!.appExtensions[0].expirationDate==oldExtension)
   passed.append("conflict-detail-preflight-read-only-no-portal-no-install")
  }
  do {
   for reason in [PreservedProfilePolicy.Failure.multipleIdentities, .alternateIdentity, .teamMismatch,
       .prefixMismatch, .signerMissing, .entitlementsDiffer, .certificatesDiffer, .devicesDiffer,
       .platformsDiffer, .embeddedDERDiffer, .displayMetadataDiffer, .otherAuthorityDiffer] {
    let mapped=V3PreservationRefreshState.map(reason)
    precondition(mapped.reason == .preservationAuthorityConflict)
    precondition(mapped.facts["preservation_conflict"] == reason.rawValue)
   }
   precondition(V3PreservationRefreshState.map(PreservedProfilePolicy.Failure.conflictingInstalledAuthority).facts["preservation_conflict"]==nil)
   precondition(V3RefreshSelectionFailure(reason:.preservationAuthorityConflict,scope:.nonHost,preservationConflict:"private raw text").facts["preservation_conflict"]==nil)
   precondition(V3RefreshSelectionFailure(reason:.preservationAuthorityConflict,scope:.host,preservationConflict:"teamMismatch").facts["preservation_conflict"]==nil)
   precondition(V3RefreshSelectionFailure(reason:.preservationIdentityUnavailable,scope:.nonHost,preservationConflict:"teamMismatch").facts["preservation_conflict"]==nil)
   passed.append("conflict-detail-finite-map-and-scope")
  }
  for (detail,label) in [("alternateIdentity","fresh-alternate-identity-snapshot-drift-no-install"),
                          ("entitlementsDiffer","fresh-entitlements-snapshot-drift-no-install")] {
   let c=setup();var reads=0
   let oldMain=c.installedApp!.expirationDate, oldExtension=c.installedApp!.appExtensions[0].expirationDate
   let alternate=profile(5,1500)
   var payload=fixturePayloads[alternate.data]!
   var entitlement=payload["Entitlements"] as! [String:Any]
   entitlement["application-identifier"]="OTHER.app";payload["Entitlements"]=entitlement
   payload["ApplicationIdentifierPrefix"]=["OTHER"];fixturePayloads[alternate.data]=payload
   c.readInstalledProvisioningProfiles={
    reads += 1;PortalProbe.shared.calls.append("read")
    return reads==3 ? [old.data,detail=="alternateIdentity" ? alternate.data:changed.data] : [old.data]
   }
   do { try await run(c);fatalError("fresh conflict accepted") }
   catch let e as V3RefreshSelectionFailure {
    precondition(e.reason == .preservationSnapshotChanged)
   }
   precondition(reads==3 && Injection.shared.count==0 && c.refreshVerification==nil)
   precondition(c.installedApp!.expirationDate==oldMain && c.installedApp!.appExtensions[0].expirationDate==oldExtension)
   passed.append(label)
  }
  for mode in ["lost-ack","port-change-eligible"] {
   let c=setup();FixturePreservationTransport.failure = mode=="lost-ack" ? ProbeError.installFailed:MinimuxerError.notReachable
   precondition(isRetriableRemotePairingError(FixturePreservationTransport.failure!))
   do {try await run(c);fatalError("uncertain dispatch retried")}catch{}
   precondition(FixturePreservationTransport.coreCalls==1 && Injection.shared.count==1)
   precondition(FixturePreservationTransport.retryEntries==0 && FixturePreservationTransport.portChanges==0)
   precondition(c.refreshVerification?.installAcknowledged==false && c.installedApp!.expirationDate==Date(timeIntervalSince1970:0))
   passed.append("preservation-actual-wrapper-"+mode+"-single-attempt")
  }
  passed += try await AuthenticatedAdapterCases.run(now:now,makeContext:{ setup() },execute:run)
  for (ids,detail) in [([],"emptyList"),(["other"],"noExactMatch"),(["app","app"],"ambiguousMatch"),(["APP"],"caseOnlyMatch")] {
   let c=setup();PortalProbe.shared.appIDs=ids.map { FixtureAppID(bundleIdentifier:$0) }
   do { try await run(c);fatalError("unmatched identity accepted") }
   catch let error as V3RefreshSelectionFailure {
    precondition(error.reason == .preservationPortalIdentityUnavailable && error.scope == .nonHost)
    precondition(error.facts["preservation_portal_identity"]==detail)
   }
   precondition(PortalProbe.shared.calls==["read","team","lookup-existing-id"])
   precondition(Injection.shared.count==0 && c.refreshVerification==nil)
   precondition(c.installedApp!.expirationDate==Date(timeIntervalSince1970:0))
   passed.append("portal-identity-"+detail+"-no-mutation")
  }
  for failure in AppIDLookupError.allCases {
   let c=setup();PortalProbe.shared.lookupFailure=failure
   do { try await run(c);fatalError("invalid lookup response accepted") }
   catch let error as V3RefreshSelectionFailure {
    precondition(error.reason == .preservationPortalIdentityUnavailable)
    precondition(error.facts["preservation_portal_identity"]==failure.rawValue)
   }
   precondition(PortalProbe.shared.calls==["read","team","lookup-existing-id"] && Injection.shared.count==0)
   precondition(c.refreshVerification==nil && c.installedApp!.expirationDate==Date(timeIntervalSince1970:0))
   passed.append("portal-lookup-"+failure.rawValue+"-no-mutation")
  }
  do {
   let c=setup();PortalProbe.shared.appIDs=[FixtureAppID(bundleIdentifier:"other"),FixtureAppID(bundleIdentifier:"app")]
   try await run(c);precondition(Injection.shared.count==1 && c.refreshVerification?.renewal == .extended)
   passed.append("portal-exact-match-among-unrelated-ids-renews")
  }
  do {
   let c=setup();var admitted=true
   c.profileMutationAdmission={ if !admitted { throw CancellationError() } }
   PortalProbe.shared.afterIDLookup={ admitted=false }
   do { try await run(c);fatalError("revoked lookup admitted") } catch is CancellationError {}
   precondition(PortalProbe.shared.calls==["read","team","lookup-existing-id"] && Injection.shared.count==0)
   passed.append("portal-lookup-revoked-before-generation")
  }
  do {
   let c=setup();PortalProbe.shared.lookupFailure=ProbeError.stopped
   do { try await run(c);fatalError("unknown lookup failure accepted") }
   catch is V3RefreshSelectionFailure { fatalError("unknown failure mislabeled as missing identity") }
   catch {}
   precondition(PortalProbe.shared.calls==["read","team","lookup-existing-id"] && Injection.shared.count==0)
   passed.append("portal-unknown-error-retains-original-classification")
  }
  do {
   for detail in V3RefreshSelectionFailure.portalIdentityKinds {
    precondition(V3RefreshSelectionFailure(reason:.preservationPortalIdentityUnavailable,scope:.nonHost,portalIdentity:detail).facts["preservation_portal_identity"]==detail)
    precondition(V3RefreshSelectionFailure(reason:.preservationPortalIdentityUnavailable,scope:.host,portalIdentity:detail).facts["preservation_portal_identity"]==nil)
    precondition(V3RefreshSelectionFailure(reason:.preservationIdentityUnavailable,scope:.nonHost,portalIdentity:detail).facts["preservation_portal_identity"]==nil)
   }
   for invalid in ["", "private.account@example.test", String(repeating:"x",count:64)] {
    precondition(V3RefreshSelectionFailure(reason:.preservationPortalIdentityUnavailable,scope:.nonHost,portalIdentity:invalid).facts["preservation_portal_identity"]==nil)
   }
   passed.append("portal-identity-detail-finite-scoped-no-identifiers")
  }
  for expected in AppIDLookupError.allCases {
   do {
    let _: Void = try await lcPortalSigningRequest(sourceStep:"appIDLookup", facts:[:]) { throw expected }
    fatalError("typed lookup failure swallowed")
   } catch let actual as AppIDLookupError { precondition(actual == expected) }
  }
  passed.append("portal-typed-errors-survive-request-observation")
  precondition(passed.count==98 && Set(passed).count==98)
  print(String(data:try JSONSerialization.data(withJSONObject:["schema":"preservation-refresh-integration-v1","status":"PASS","cases":passed,"device_executed":false,"cms_verified":false,"platform_tls_executed":false,"portal_executed":false],options:[.sortedKeys]),encoding:.utf8)!)
 }
}
