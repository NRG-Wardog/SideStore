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
 static func register(_ id:Int,_ lifetime:Double,now:Date,group:String="group.existing",innerGroup:String?=nil,
                      bundle:String="app",team:String="T",certificate:Data=Data([7])) -> ALTProvisioningProfile {
  let instant=Date(timeIntervalSince1970:floor(now.timeIntervalSince1970))
  let bytes=Data([UInt8(id)]),uuid=UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",id))!
  let expiry=instant.addingTimeInterval(lifetime)
  let p=ALTProvisioningProfile(uuid:uuid,data:bytes,bundleIdentifier:bundle,teamIdentifier:team,expirationDate:expiry,certificates:[Cert(serialNumber:"S",data:certificate)])
  var payload:[String:Any]=["UUID":uuid.uuidString,"Name":"synthetic","TeamName":"synthetic","Version":1,
   "CreationDate":instant.addingTimeInterval(-10000),"ExpirationDate":expiry,"TimeToLive":7,
   "TeamIdentifier":[team],"ApplicationIdentifierPrefix":["PREFIX"],"DeveloperCertificates":[certificate],
   "ProvisionedDevices":["synthetic"],"Platform":["iOS"],"Entitlements":["application-identifier":"PREFIX."+bundle,
    "com.apple.developer.team-identifier":team,"keychain-access-groups":["PREFIX.app","PREFIX.shared"],
    "com.apple.security.application-groups":[group],"get-task-allow":true]]
  var inner=payload
  if let innerGroup { var e=inner["Entitlements"] as! [String:Any];e["com.apple.security.application-groups"]=[innerGroup];inner["Entitlements"]=e }
  let nested=Data("synthetic-inner-\(id)".utf8)
  FixtureCMSBoundary.inner[nested]=dictionaryDER(inner,tag:49)
  payload["DER-Encoded-Profile"]=nested
  FixtureCMSBoundary.outer[bytes]=try! PropertyListSerialization.data(fromPropertyList:payload,format:.xml,options:0)
  fixturePayloads[bytes]=payload;fixtureProfiles[bytes]=p;return p
 }
 static func rewrite(_ profile:ALTProvisioningProfile,_ transform:(inout [String:Any])->Void) {
  var payload=fixturePayloads[profile.data]!;let nested=payload.removeValue(forKey:"DER-Encoded-Profile") as! Data
  transform(&payload)
  FixtureCMSBoundary.inner[nested]=dictionaryDER(payload,tag:49)
  payload["DER-Encoded-Profile"]=nested;fixturePayloads[profile.data]=payload
  FixtureCMSBoundary.outer[profile.data]=try! PropertyListSerialization.data(fromPropertyList:payload,format:.xml,options:0)
 }
 static func run(now:Date,makeContext:()->InstallAppOperationContext,
                 execute:(InstallAppOperationContext) async throws->Void) async throws->[String] {
  var passed:[String]=[]
  func configure(_ c:InstallAppOperationContext,_ old:[ALTProvisioningProfile],_ candidate:ALTProvisioningProfile,
                 fresh:@escaping ([Data])->[Data] = {$0},after:@escaping ([Data])->[Data] = {$0}) {
   PortalProbe.shared.candidate=candidate;var reads=0
   c.readInstalledProvisioningProfiles={
    reads += 1;PortalProbe.shared.calls.append("read")
    if Injection.shared.count>0 {return after(old.map(\.data)+[candidate.data])}
    return reads==3 ? fresh(old.map(\.data)):old.map(\.data)
   }
  }
  func prepare(_ profiles:[ALTProvisioningProfile]) throws->V3PreservationRefreshState.Prepared {
   try V3PreservationRefreshState.prepare(resignedBundleID:"app",teamID:"T",signerDER:Data([7]),certificateExpiration:now.addingTimeInterval(5000),inventory:profiles.map(\.data),now:now,admission:nil)
  }
  func noOldPortal() {
   precondition(!PortalProbe.shared.calls.contains("list-existing-profiles") && !PortalProbe.shared.calls.contains("download-exact-existing-profile"))
  }
  func reject(_ c:InstallAppOperationContext,beforeGeneration:Bool=false) async {
   let main=c.installedApp!.expirationDate,ext=c.installedApp!.appExtensions[0].expirationDate
   do {try await execute(c);fatalError("historical constraints expanded authority")}catch{}
   precondition(Injection.shared.count==0 && c.refreshVerification==nil)
   precondition(c.installedApp!.expirationDate==main && c.installedApp!.appExtensions[0].expirationDate==ext)
   if beforeGeneration {precondition(!PortalProbe.shared.calls.contains("generate-existing-id-profile"))}
   noOldPortal()
  }
  for (name,multiple,expired) in [("authenticated-candidate-der-equivalence-real-decoder",false,false),
   ("authenticated-initial-der-equivalence-real-decoder",true,false),("historical-expired-profile-current-cms-renews",false,true)] {
   let c=makeContext();FixtureCMSBoundary.reset()
   let a=register(30,expired ? -1000:1000,now:now),b=register(31,1200,now:now),candidate=register(32,2000,now:now)
   configure(c,multiple ? [a,b]:[a],candidate)
   for p in [a,b] {FixtureCMSBoundary.innerFailures[fixturePayloads[p.data]!["DER-Encoded-Profile"] as! Data] = .unsupportedSigner}
   PortalProbe.shared.failCorroboration=true;PortalProbe.shared.existingProfiles=[:]
   let ext=c.installedApp!.appExtensions[0].expirationDate
   try await execute(c)
   precondition(Injection.shared.count==1 && c.refreshVerification?.installAcknowledged==true && c.refreshVerification?.profileStore == .matched)
   precondition(FixtureCMSBoundary.inspectionCalls>0 && c.installedApp!.appExtensions[0].expirationDate==ext)
   noOldPortal();passed.append(name)
  }
  for (name,error) in [("historical-current-cms-time-invalid-no-generation",ProfileCMSVerificationError.signerTimeInvalid),
   ("historical-bad-cms-math-no-generation",.verificationFailed),("historical-malformed-cms-no-generation",.unsupportedRepresentation)] {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),candidate=register(32,2000,now:now)
   configure(c,[a],candidate);FixtureCMSBoundary.inspectionFailures[fixturePayloads[a.data]!["DER-Encoded-Profile"] as! Data]=error
   await reject(c,beforeGeneration:true);passed.append(name)
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now,innerGroup:"group.hidden"),candidate=register(32,2000,now:now)
   configure(c,[a],candidate);await reject(c,beforeGeneration:true);passed.append("authenticated-hidden-inner-authority-rejected")
  }
  for mode in ["malformed","unknown-field","contradictory"] {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),b=register(31,1200,now:now,group:mode=="contradictory" ? "group.changed":"group.existing"),candidate=register(32,2000,now:now)
   if mode=="malformed" {rewrite(a){$0.removeValue(forKey:"DeveloperCertificates")}}
   if mode=="unknown-field" {rewrite(a){$0["UnrecognizedGrant"]="must-not-drop"}}
   configure(c,mode=="contradictory" ? [a,b]:[a],candidate)
   await reject(c,beforeGeneration:mode != "unknown-field");passed.append("historical-"+mode+"-constraints-fail-closed")
  }
  for variant in ["team","app","certificate","entitlements","unknown-field"] {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now)
   let candidate=register(32,2000,now:now,group:variant=="entitlements" ? "group.changed":"group.existing",
    bundle:variant=="app" ? "different":"app",team:variant=="team" ? "OTHER":"T",certificate:variant=="certificate" ? Data([99]):Data([7]))
   if variant=="unknown-field" {rewrite(candidate){$0["UnrecognizedGrant"]="new"}}
   configure(c,[a],candidate);await reject(c);passed.append("candidate-independent-"+variant+"-mismatch-no-install")
  }
  for (name,error) in [("candidate-crypto-time-invalid-no-install",ProfileCMSVerificationError.signerTimeInvalid),
   ("candidate-crypto-signature-invalid-no-install",.verificationFailed),("candidate-crypto-malformed-no-install",.unsupportedRepresentation)] {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),candidate=register(32,2000,now:now)
   configure(c,[a],candidate);FixtureCMSBoundary.inspectionFailures[fixturePayloads[candidate.data]!["DER-Encoded-Profile"] as! Data]=error
   FixtureCMSBoundary.innerFailures[fixturePayloads[candidate.data]!["DER-Encoded-Profile"] as! Data]=error
   await reject(c);passed.append(name)
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),candidate=register(32,2000,now:now,innerGroup:"group.hidden")
   configure(c,[a],candidate);await reject(c);passed.append("candidate-inner-outer-binding-mismatch-no-install")
  }
  for mode in ["target","unrelated"] {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),other=register(31,1200,now:now,bundle:"other"),candidate=register(32,2000,now:now)
   rewrite(candidate){$0["UUID"]=(mode=="target" ? a:other).uuid.uuidString}
   var collision=candidate;collision.uuid=(mode=="target" ? a:other).uuid;fixtureProfiles[candidate.data]=collision
   configure(c,[a,other],collision);await reject(c);passed.append("candidate-any-old-uuid-collision-"+mode+"-no-install")
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),candidate=register(32,2000,now:now)
   let prepared=try prepare([a]);do {_ = try V3PreservationRefreshState.finish(prepared:prepared,candidateData:candidate.data,now:now,admission:nil);fatalError("candidate without provenance accepted")}
   catch let error as V3RefreshSelectionFailure { precondition(error.facts["preservation_evidence"] == "missingOrigin") }
   let operation=AppleProfileOperation(target:"app",admission:{})
   let evidence=AppleProfileEvidence(profile:candidate,role:.candidate,operationID:operation.id)
   let origin=V3AppleProfileOriginEvidence(operation:operation,candidate:evidence)
   do { try origin.authorizeCandidate(a.data);fatalError("mismatched candidate bytes admitted") }
   catch let error as V3RefreshSelectionFailure { precondition(error.facts["preservation_evidence"] == "candidateMismatch") }
   precondition(Injection.shared.count==0);passed.append("candidate-static-pin-without-own-origin-rejected")
  }
  for mode in ["unrelated-addition","old-pruned","old-byte-drift","multiplicity"] {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),other=register(31,1200,now:now,bundle:"other"),candidate=register(32,2000,now:now),extra=register(33,1300,now:now,bundle:"extra")
   configure(c,[a,other],candidate,fresh:{ old in
    switch mode {case "unrelated-addition":return old+[extra.data];case "old-pruned":return [a.data];case "old-byte-drift":return [a.data,extra.data];default:return old+[other.data]}
   })
   await reject(c);passed.append("historical-all-inventory-fresh-"+mode+"-no-install")
  }
  for mode in ["old-target-pruned","unrelated-pruned","old-byte-replaced","candidate-missing","extra-target","extra-unrelated"] {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),other=register(31,1200,now:now,bundle:"other"),candidate=register(32,2000,now:now),replacement=register(33,1300,now:now,bundle:"other")
   configure(c,[a,other],candidate,after:{ all in
    switch mode {case "old-target-pruned":return [other.data,candidate.data];case "unrelated-pruned":return [a.data,candidate.data];case "old-byte-replaced":return [a.data,replacement.data,candidate.data];case "extra-target":return all+[a.data];case "extra-unrelated":return all+[replacement.data];default:return [a.data,other.data]}
   })
   let oldExpiry=c.installedApp!.expirationDate
   do { try await execute(c);fatalError("changed post-dispatch inventory reported success") }
   catch V3PreservationPostDispatchFailure.verificationMismatch {}
   precondition(Injection.shared.count==1 && c.refreshVerification?.installAcknowledged==true && c.refreshVerification?.profileStore == .mismatch)
   precondition(c.refreshVerification?.renewal != .extended && c.installedApp!.expirationDate==oldExpiry)
   passed.append("historical-postack-"+mode+"-not-green")
  }
  for (name,count,accepted) in [("authenticated-count-boundary-512",512,true),("authenticated-count-boundary-513",513,false)] {
   _=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now)
   do {_ = try prepare(Array(repeating:a,count:count));precondition(accepted)}catch{precondition(!accepted)}
   passed.append(name)
  }
  for (name,extra,oversized,accepted) in [("authenticated-byte-boundary-32mib",0,false,true),("authenticated-byte-boundary-over32mib",1,false,false),("authenticated-record-boundary-over1mib",0,true,false)] {
   _=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now)
   let large=Data(repeating:30,count:1_048_576+(oversized ? 1:0));var p=a;p.data=large
   fixtureProfiles[large]=p;fixturePayloads[large]=fixturePayloads[a.data];FixtureCMSBoundary.outer[large]=FixtureCMSBoundary.outer[a.data]
   var inputs=Array(repeating:p,count:32);if extra>0{inputs.append(a)}
   do {_ = try prepare(inputs);precondition(accepted)}catch{precondition(!accepted)}
   passed.append(name)
  }
  for mode in ["count","bytes"] {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),candidate=register(32,2000,now:now)
   var records:[ALTProvisioningProfile]
   if mode=="count" {records=Array(repeating:a,count:512)} else {
    let large=Data(repeating:30,count:1_048_576);var p=a;p.data=large
    fixtureProfiles[large]=p;fixturePayloads[large]=fixturePayloads[a.data];FixtureCMSBoundary.outer[large]=FixtureCMSBoundary.outer[a.data]
    records=Array(repeating:p,count:32)
   }
   configure(c,records,candidate);await reject(c)
   passed.append("historical-plus-candidate-"+mode+"-budget-no-install")
  }
  func xmlOnly(_ p:ALTProvisioningProfile) {
   fixturePayloads[p.data]!.removeValue(forKey:"DER-Encoded-Profile")
   FixtureCMSBoundary.outer[p.data]=try! PropertyListSerialization.data(fromPropertyList:fixturePayloads[p.data]!,format:.xml,options:0)
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),candidate=register(32,2000,now:now)
   xmlOnly(a);xmlOnly(candidate);configure(c,[a],candidate)
   try await execute(c)
   precondition(Injection.shared.count==1 && c.refreshVerification?.profileStore == .matched && c.refreshVerification?.renewal == .extended)
   precondition(FixtureCMSBoundary.inspectionCalls==0 && FixtureCMSBoundary.calls>0)
   precondition(PortalProbe.shared.calls.contains("origin-operation"));noOldPortal()
   passed.append("historical-xml-only-candidate-own-origin-success")
  }
  do {
   for malformed in [Data() as Any,"not-data" as Any,Data([0x30,0x00]) as Any] {
    let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),candidate=register(32,2000,now:now)
    fixturePayloads[a.data]!["DER-Encoded-Profile"]=malformed
    FixtureCMSBoundary.outer[a.data]=try! PropertyListSerialization.data(fromPropertyList:fixturePayloads[a.data]!,format:.xml,options:0)
    configure(c,[a],candidate);await reject(c,beforeGeneration:true)
   }
   passed.append("historical-present-malformed-der-never-xml-fallback")
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),candidate=register(32,2000,now:now,group:"group.changed")
   xmlOnly(a);xmlOnly(candidate);configure(c,[a],candidate);await reject(c)
   passed.append("historical-xml-authorization-change-no-install")
  }
  do {
   let c=makeContext();FixtureCMSBoundary.reset();let a=register(30,1000,now:now),candidate=register(32,2000,now:now)
   xmlOnly(a);configure(c,[a],candidate);await reject(c)
   passed.append("historical-mixed-xml-der-format-no-install")
  }
  passed += try await OriginAdapterCases.run(now:now,makeContext:makeContext,execute:execute)
  FixtureCMSBoundary.reset();return passed
 }
}

