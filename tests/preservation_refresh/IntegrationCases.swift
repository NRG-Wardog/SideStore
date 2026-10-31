@main struct PreservationIntegrationCases {
 static func main() async throws {
  let now=Date(); let der=Data([7]); var passed:[String]=[]
  func profile(_ number:Int,_ lifetime:Double,_ group:String="group.existing") -> ALTProvisioningProfile {
   let p=ALTProvisioningProfile(uuid:UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",number))!,data:Data([UInt8(number)]),bundleIdentifier:"app",teamIdentifier:"T",expirationDate:now.addingTimeInterval(lifetime),certificates:[Cert(serialNumber:"S",data:der)])
   fixtureProfiles[p.data]=p
   fixturePayloads[p.data]=["UUID":p.uuid.uuidString,"CreationDate":now.addingTimeInterval(-100),"ExpirationDate":p.expirationDate,"TimeToLive":7,"TeamIdentifier":["T"],"ApplicationIdentifierPrefix":["PREFIX"],"DeveloperCertificates":[der],"ProvisionedDevices":["synthetic"],"Platform":["iOS"],"Entitlements":["application-identifier":"PREFIX.app","com.apple.developer.team-identifier":"T","keychain-access-groups":["PREFIX.app","PREFIX.shared"],"com.apple.security.application-groups":[group],"get-task-allow":true]]
   return p
  }
  let old=profile(1,1000), fresh=profile(2,2000), changed=profile(3,2000,"group.changed"), concurrent=profile(4,1500)
  func setup(changedAtFreshRead:Bool=false, missing:Bool=false, rebindAtFreshRead:Bool=false, postread:String="matched") -> InstallAppOperationContext {
   Injection.shared.count=0;Injection.shared.failAt=0;Injection.shared.after=nil
   CellularRefreshManager.shared.duringOff=nil
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
   precondition(PortalProbe.shared.calls==["read","team","lookup-existing-id","generate-existing-id-profile","read","read","read"])
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
   try await run(c)
   precondition(!PortalProbe.shared.calls.contains("lookup-existing-id") && Injection.shared.count==1)
   passed.append("provided-profile-same-authority-no-portal")
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
   try await run(c)
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
  precondition(passed.count==18)
  print(String(data:try JSONSerialization.data(withJSONObject:["schema":"preservation-refresh-integration-v1","status":"PASS","cases":passed,"device_executed":false],options:[.sortedKeys]),encoding:.utf8)!)
 }
}
