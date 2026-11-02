// Actual adapter, actual pure policy, and actual DER/XML decoder. Only CMS
// authentication is an explicit SDK-boundary double; cryptographic qualification
// runs separately against production C. These synthetic bytes are not signatures.
enum AuthenticatedAdapterCases {
 static func tlv(_ tag:UInt8,_ body:Data)->Data {
  var result=Data([tag]);let count=body.count
  if count<128 { result.append(UInt8(count)) }
  else if count<256 { result.append(contentsOf:[0x81,UInt8(count)]) }
  else { result.append(contentsOf:[0x82,UInt8(count>>8),UInt8(count&255)]) }
  result.append(body);return result
 }
 static func encode(_ value:Any)->Data {
  if let string=value as? String { return tlv(12,Data(string.utf8)) }
  if let bytes=value as? Data { return tlv(4,bytes) }
  if let date=value as? Date {
   let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(secondsFromGMT:0);f.dateFormat="yyyyMMddHHmmss'Z'"
   return tlv(24,Data(f.string(from:date).utf8))
  }
  if let number=value as? NSNumber {
   if CFGetTypeID(number)==CFBooleanGetTypeID() { return tlv(1,Data([number.boolValue ? 255:0])) }
   precondition(number.intValue>=0 && number.intValue<128);return tlv(2,Data([UInt8(number.intValue)]))
  }
  if let array=value as? [Any] { return tlv(48,array.reduce(Data()){$0+encode($1)}) }
  if let dictionary=value as? [String:Any] { return dictionaryDER(dictionary,tag:49) }
  fatalError("synthetic encoder unsupported")
 }
 static func dictionaryDER(_ fields:[String:Any],tag:UInt8)->Data {
  let pairs=fields.map { key,value -> Data in
   let encoded:Data
   if key=="Entitlements" {
    encoded=tlv(112,tlv(2,Data([1]))+dictionaryDER(value as! [String:Any],tag:176))
   } else if key=="DeveloperCertificates" {
    encoded=encode((value as! [Data]).map { Data(SHA256.hash(data:$0)) })
   } else { encoded=encode(value) }
   return tlv(48,tlv(12,Data(key.utf8))+encoded)
  }.sorted { $0.lexicographicallyPrecedes($1) }
  return tlv(tag,pairs.reduce(Data(),+))
 }
 static func run(now:Date,makeContext:()->InstallAppOperationContext,
                 execute:(InstallAppOperationContext) async throws->Void) async throws->[String] {
  let instant=Date(timeIntervalSince1970:floor(now.timeIntervalSince1970));var passed:[String]=[]
  func register(_ id:Int,_ lifetime:Double,group:String="group.existing",innerGroup:String?=nil)->ALTProvisioningProfile {
   let bytes=Data([UInt8(id)]), uuid=UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",id))!
   let expiry=instant.addingTimeInterval(lifetime)
   let p=ALTProvisioningProfile(uuid:uuid,data:bytes,bundleIdentifier:"app",teamIdentifier:"T",expirationDate:expiry,certificates:[Cert(serialNumber:"S",data:Data([7]))])
   var payload:[String:Any]=["UUID":uuid.uuidString,"Name":"synthetic","TeamName":"synthetic","Version":1,
    "CreationDate":instant.addingTimeInterval(-100),"ExpirationDate":expiry,"TimeToLive":7,
    "TeamIdentifier":["T"],"ApplicationIdentifierPrefix":["PREFIX"],"DeveloperCertificates":[Data([7])],
    "ProvisionedDevices":["synthetic"],"Platform":["iOS"],"Entitlements":["application-identifier":"PREFIX.app",
     "com.apple.developer.team-identifier":"T","com.apple.security.application-groups":[group],"get-task-allow":true]]
   var inner=payload
   if let innerGroup { var e=inner["Entitlements"] as! [String:Any];e["com.apple.security.application-groups"]=[innerGroup];inner["Entitlements"]=e }
   let nested=Data("synthetic-inner-\(id)".utf8)
   FixtureCMSBoundary.inner[nested]=dictionaryDER(inner,tag:49)
   payload["DER-Encoded-Profile"]=nested
   FixtureCMSBoundary.outer[bytes]=try! PropertyListSerialization.data(fromPropertyList:payload,format:.xml,options:0)
   fixturePayloads[bytes]=payload;fixtureProfiles[bytes]=p;return p
  }
  func prepareProfiles(_ profiles:[ALTProvisioningProfile],admission:(() throws->Void)?=nil,origin:V3AppleProfileOriginEvidence?=nil) throws->V3PreservationRefreshState.Prepared {
   try V3PreservationRefreshState.prepare(resignedBundleID:"app",teamID:"T",signerDER:Data([7]),certificateExpiration:instant.addingTimeInterval(5000),inventory:profiles.map(\.data),now:now,admission:admission,origin:origin)
  }
  func configure(_ c:InstallAppOperationContext,_ old:[ALTProvisioningProfile],_ candidate:ALTProvisioningProfile,drift:ALTProvisioningProfile?=nil) {
   PortalProbe.shared.candidate=candidate;var reads=0
   c.readInstalledProvisioningProfiles={
    reads += 1;PortalProbe.shared.calls.append("read")
    if Injection.shared.count>0 { return old.map(\.data)+[candidate.data] }
    if reads==3,let drift { return old.map(\.data)+[drift.data] }
    return old.map(\.data)
   }
  }
  for multiple in [false,true] {
   let c=makeContext();FixtureCMSBoundary.reset()
   let a=register(30,1000),b=register(31,1200),candidate=register(32,2000)
   configure(c,multiple ? [a,b]:[a],candidate)
   let oldExtension=c.installedApp!.appExtensions[0].expirationDate
   try await execute(c)
   precondition(c.preservationRefreshState?.usesAuthenticatedDER==true && FixtureCMSBoundary.calls>0)
   precondition(Injection.shared.count==1 && c.refreshVerification?.installAcknowledged==true)
   precondition(c.installedApp!.appExtensions[0].expirationDate==oldExtension)
   passed.append(multiple ? "authenticated-initial-der-equivalence-real-decoder" : "authenticated-candidate-der-equivalence-real-decoder")
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000),candidate=register(32,2000,group:"group.changed")
   configure(c,[a],candidate)
   let prepared=try prepareProfiles([a])
   do { _ = try V3PreservationRefreshState.finish(prepared:prepared,candidateData:candidate.data,now:now,admission:nil);fatalError("outer authority accepted") }
   catch let e as PreservedProfilePolicy.Failure { precondition(e == .changedAuthorization) }
   precondition(FixtureCMSBoundary.calls==0 && Injection.shared.count==0)
   passed.append("non-der-authority-rejection-never-authenticates")
  }
  for (error,detail) in [(ProfileCMSVerificationError.unsupportedSigner,"embeddedDERUnsupportedSigner"),
    (.signerTimeInvalid,"embeddedDERSignerTimeInvalid"),(.verificationFailed,"embeddedDERVerificationFailed"),
    (.unsupportedRepresentation,"embeddedDERUnsupportedRepresentation")] {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000),b=register(31,1200),candidate=register(32,2000)
   configure(c,[a,b],candidate);FixtureCMSBoundary.failure=error
   do { try await execute(c);fatalError("crypto failure accepted") }
   catch let e as V3RefreshSelectionFailure { precondition(e.reason == .preservationAuthorityConflict && e.preservationConflict==detail) }
   precondition(Injection.shared.count==0 && !PortalProbe.shared.calls.contains("lookup-existing-id"))
   passed.append("authenticated-preflight-"+detail)
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000),b=register(31,1200,innerGroup:"group.hidden"),candidate=register(32,2000)
   configure(c,[a,b],candidate)
   do { try await execute(c);fatalError("hidden inner authority accepted") }
   catch let e as V3RefreshSelectionFailure { precondition(e.preservationConflict=="embeddedDERBindingMismatch") }
   precondition(Injection.shared.count==0 && !PortalProbe.shared.calls.contains("lookup-existing-id"))
   passed.append("authenticated-hidden-inner-authority-rejected")
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000),b=register(31,1200),candidate=register(32,2000),drift=register(33,1300)
   configure(c,[a,b],candidate,drift:drift)
   let oldMain=c.installedApp!.expirationDate,oldExtension=c.installedApp!.appExtensions[0].expirationDate
   do { try await execute(c);fatalError("projected fresh drift accepted") }
   catch let e as V3RefreshSelectionFailure { precondition(e.reason == .preservationSnapshotChanged) }
   precondition(Injection.shared.count==0 && c.refreshVerification==nil)
   precondition(c.installedApp!.expirationDate==oldMain && c.installedApp!.appExtensions[0].expirationDate==oldExtension)
   precondition(FixtureCMSBoundary.calls==10) // 4 static preflight + 4 initial + 2 candidate; no changed-target fresh reauthentication.
   passed.append("authenticated-fresh-raw-drift-no-repair")
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000),b=register(31,1200),candidate=register(32,2000)
   configure(c,[a,b],candidate)
   var cancelled=false;c.profileMutationAdmission={if cancelled {throw CancellationError()} }
   FixtureCMSBoundary.duringCall={cancelled=true}
   do { try await execute(c);fatalError("cancelled authentication accepted") } catch is CancellationError {}
   precondition(Injection.shared.count==0 && !PortalProbe.shared.calls.contains("lookup-existing-id"))
   passed.append("authenticated-cancellation-before-portal-no-install")
  }
  for (label,count,allowed) in [("authenticated-count-boundary-512",512,true),("authenticated-count-boundary-513",513,false)] {
   FixtureCMSBoundary.reset();let a=register(30,1000),b=register(31,1200)
   FixtureCMSBoundary.failure = .unsupportedSigner
   let inventory=[a.data,b.data]+Array(repeating:a.data,count:count-2)
   do { _ = try V3PreservationRefreshState.prepare(resignedBundleID:"app",teamID:"T",signerDER:Data([7]),certificateExpiration:instant.addingTimeInterval(5000),inventory:inventory,now:now,admission:nil);fatalError("boundary accepted") }
   catch let e as V3RefreshSelectionFailure { precondition(!allowed && e.reason == .preservationEvidenceUnavailable) }
   catch let e as PreservedProfilePolicy.Failure { precondition(allowed && e == .embeddedDERUnsupportedSigner) }
   precondition(FixtureCMSBoundary.calls == (allowed ? 1:0));passed.append(label)
  }
  for (label,extra,oversized,allowed) in [("authenticated-byte-boundary-32mib",0,false,true),
      ("authenticated-byte-boundary-over32mib",1,false,false),("authenticated-record-boundary-over1mib",0,true,false)] {
   FixtureCMSBoundary.reset();let a=register(30,1000),b=register(31,1200)
   let largeA=Data(repeating:30,count:1_048_576+(oversized ? 1:0)),largeB=Data(repeating:31,count:1_048_576)
   fixtureProfiles[largeA]=a;fixtureProfiles[largeB]=b
   var inventory=[largeA,largeB]+Array(repeating:largeA,count:30)
   if extra>0 { inventory.append(a.data) }
   FixtureCMSBoundary.failure = .unsupportedSigner
   do { _ = try V3PreservationRefreshState.prepare(resignedBundleID:"app",teamID:"T",signerDER:Data([7]),certificateExpiration:instant.addingTimeInterval(5000),inventory:inventory,now:now,admission:nil);fatalError("byte boundary accepted") }
   catch let e as V3RefreshSelectionFailure { precondition(!allowed && e.reason == .preservationEvidenceUnavailable) }
   catch let e as PreservedProfilePolicy.Failure { precondition(allowed && e == .embeddedDERUnsupportedSigner) }
   precondition(FixtureCMSBoundary.calls == (allowed ? 1:0));passed.append(label)
   fixtureProfiles.removeValue(forKey:largeA);fixtureProfiles.removeValue(forKey:largeB)
  }
  do {
   FixtureCMSBoundary.reset();let a=register(30,1000)
   let prepared=try V3PreservationRefreshState.prepare(resignedBundleID:"app",teamID:"T",signerDER:Data([7]),certificateExpiration:instant.addingTimeInterval(5000),inventory:Array(repeating:a.data,count:513),now:now,admission:nil)
   precondition(!prepared.usesAuthenticatedDER && FixtureCMSBoundary.calls==0)
   passed.append("raw-equal-admission-unchanged-by-semantic-budget")
  }
  // Diagnostic observations must never turn an unknown signer into authority.
  for phase in ["installed", "candidate", "freshInstalled", "freshCandidate"] {
   let c=makeContext();FixtureCMSBoundary.reset()
   let a=register(30,1000),b=register(31,1200),candidate=register(32,2000)
   let old = phase == "candidate" ? [a] : [a,b]
   if !phase.hasPrefix("fresh") {
    let id = phase == "installed" ? 30 : 32
    FixtureCMSBoundary.innerFailures[Data("synthetic-inner-\(id)".utf8)] = .unsupportedSigner
   }
   FixtureCMSBoundary.diagnostic=ProfileCMSSignerEvidence(algorithmAndAttributes:.passed,pin:.failed,
    chain:.passed,temporal:.passed,signature:.passed,profileSubjectMarker:true,profileIssuerMarker:true,
    profileExtensionMarker:true,appDeveloperMarker:false,signerSHA256:String(repeating:"a",count:64))
   let beforeMain=c.installedApp!.expirationDate,beforeExtension=c.installedApp!.appExtensions[0].expirationDate
   do {
    let prepared=try prepareProfiles(old)
    let state=try V3PreservationRefreshState.finish(prepared:prepared,candidateData:candidate.data,now:now,admission:nil)
    if phase.hasPrefix("fresh") {
     let id=phase == "freshInstalled" ? 30:32
     FixtureCMSBoundary.innerFailures[Data("synthetic-inner-\(id)".utf8)] = .unsupportedSigner
     try state.validateFresh(old.map(\.data),now:now,admission:nil)
    }
    fatalError("Diagnostic accepted unknown signer")
   }
   catch let e as V3RefreshSelectionFailure {
    precondition(e.reason == .preservationAuthorityConflict && e.preservationConflict == "embeddedDERUnsupportedSigner")
    precondition(e.facts["cms_signer_diagnostic"] == "cs1|\(phase)|passed|passed|passed|passed|failed|1110|"+String(repeating:"a",count:64))
   }
   precondition(Injection.shared.count==0 && c.refreshVerification==nil && FixtureCMSBoundary.diagnosticCalls==1)
   precondition(c.installedApp!.expirationDate==beforeMain && c.installedApp!.appExtensions[0].expirationDate==beforeExtension)
   if phase == "installed" { precondition(!PortalProbe.shared.calls.contains("lookup-existing-id")) }
   passed.append("unknown-cms-signer-diagnostic-"+phase+"-no-mutation")
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000),b=register(31,1200),candidate=register(32,2000)
   configure(c,[a,b],candidate)
   FixtureCMSBoundary.innerFailures[Data("synthetic-inner-30".utf8)] = .unsupportedSigner
   FixtureCMSBoundary.diagnostic=ProfileCMSSignerEvidence(algorithmAndAttributes:.passed,pin:.failed,
    chain:.failed,temporal:.unchecked,signature:.unchecked,profileSubjectMarker:true,profileIssuerMarker:true,
    profileExtensionMarker:true,appDeveloperMarker:true,signerSHA256:"CANARY-OWNER-CERTIFICATE")
   do { _ = try prepareProfiles([a,b]);fatalError("Unverified diagnostic accepted") }
   catch let e as V3RefreshSelectionFailure {
    precondition(e.facts["cms_signer_diagnostic"] == "cs1|installed|passed|failed|unchecked|unchecked|failed|unchecked|unknown")
    precondition(!e.facts.description.contains("CANARY"))
   }
   precondition(Injection.shared.count==0 && !PortalProbe.shared.calls.contains("lookup-existing-id"))
   passed.append("unknown-cms-signer-unverified-no-fingerprint-or-role")
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000),b=register(31,1200),candidate=register(32,2000)
   configure(c,[a,b],candidate)
   FixtureCMSBoundary.innerFailures[Data("synthetic-inner-30".utf8)] = .unsupportedSigner
   var allowed=true;c.profileMutationAdmission={if !allowed {throw CancellationError()} }
   FixtureCMSBoundary.duringDiagnostic={allowed=false}
   do { _ = try prepareProfiles([a,b],admission:c.profileMutationAdmission);fatalError("Diagnostic admission revocation ignored") } catch is CancellationError {}
   precondition(FixtureCMSBoundary.diagnosticCalls==1 && Injection.shared.count==0 && !PortalProbe.shared.calls.contains("lookup-existing-id"))
   passed.append("unknown-cms-signer-diagnostic-admission-revoked")
  }
  do {
   let valid="cs1|installed|passed|passed|passed|passed|failed|1110|"+String(repeating:"a",count:64)
   for bad in ["CANARY-OWNER-PROFILE",valid+"|extra",valid.replacingOccurrences(of:"installed",with:"CANARY"),
    valid.replacingOccurrences(of:"failed",with:"passed"),valid.replacingOccurrences(of:"1110",with:"00000"),
    valid.replacingOccurrences(of:String(repeating:"a",count:64),with:String(repeating:"G",count:64))] {
    precondition(V3RefreshSelectionFailure(reason:.preservationAuthorityConflict,scope:.nonHost,preservationConflict:"embeddedDERUnsupportedSigner",cmsSignerDiagnostic:bad).facts["cms_signer_diagnostic"] == nil)
   }
   precondition(V3RefreshSelectionFailure(reason:.preservationAuthorityConflict,scope:.host,preservationConflict:"embeddedDERUnsupportedSigner",cmsSignerDiagnostic:valid).facts["cms_signer_diagnostic"] == nil)
   precondition(V3RefreshSelectionFailure(reason:.preservationAuthorityConflict,scope:.nonHost,preservationConflict:"embeddedDERDiffer",cmsSignerDiagnostic:valid).facts["cms_signer_diagnostic"] == nil)
   passed.append("unknown-cms-signer-diagnostic-producer-finite-scope")
  }
  passed += try await OriginAdapterCases.run(now:now,makeContext:makeContext,execute:execute,register:register,configure:configure)
  FixtureCMSBoundary.reset();return passed
 }
}
