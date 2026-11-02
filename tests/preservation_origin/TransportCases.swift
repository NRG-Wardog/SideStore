// Fake HTTP only: real request/delegate/parser/private mint and SS consumer execute.
// Synthetic profile containers are NOT valid CMS and no platform TLS is claimed.
final class OriginGate: @unchecked Sendable {
 private let lock=NSLock();private var allowed=true
 func deny(){lock.withLock{allowed=false}}
 func check() throws {if !lock.withLock({allowed}){throw AppleProfileEvidenceError.ownershipChanged}}
}
final class OriginTaskControl: @unchecked Sendable {
 private let lock=NSLock();private var task:Task<Void,Error>?
 func set(_ value:Task<Void,Error>){lock.withLock{task=value}}
 func cancel(){lock.withLock{task?.cancel()}}
}
struct OriginStep: @unchecked Sendable {
 var body:Data
 var status=200
 var finalURL:URL?=nil
 var redirect=false
 var declaredLength:Int?=nil
 var after:(@Sendable ()->Void)?=nil
 var duringBody:(@Sendable ()->Void)?=nil
}
final class OriginWire: @unchecked Sendable {
 static let shared=OriginWire();private let lock=NSLock()
 private var steps:[OriginStep]=[];private var paths:[String]=[]
 func reset(_ values:[OriginStep]){lock.withLock{steps=values;paths=[]}}
 func take(_ request:URLRequest)->OriginStep? {
  lock.withLock { paths.append(request.url!.lastPathComponent);return steps.isEmpty ? nil:steps.removeFirst() }
 }
 var calls:[String]{lock.withLock{paths}}
}
final class OriginURLProtocol:URLProtocol,@unchecked Sendable {
 override class func canInit(with request:URLRequest)->Bool {true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
 override func startLoading(){
  guard request.url?.scheme=="https",request.url?.host=="developerservices2.apple.com",request.httpMethod=="POST",
        let step=OriginWire.shared.take(request) else {client?.urlProtocol(self,didFailWithError:URLError(.badServerResponse));return}
  var body=request.httpBody
  if body == nil,let stream=request.httpBodyStream {
   stream.open();defer{stream.close()};var collected=Data();var buffer=[UInt8](repeating:0,count:4096)
   while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:4096);precondition(n>=0);if n==0{break};collected.append(contentsOf:buffer.prefix(n))}
   body=collected
  }
  let fields=try! PropertyListSerialization.propertyList(from:body!,options:[],format:nil) as! [String:Any]
  precondition(fields["teamId"] as? String == "T" && fields["clientId"] as? String == "fixture-client" && fields["protocolVersion"] as? String == "QH65B2")
  precondition(UUID(uuidString:fields["requestId"] as! String) != nil)
  precondition(request.value(forHTTPHeaderField:"X-Apple-I-Identity-Id")=="synthetic-account" && request.value(forHTTPHeaderField:"X-Apple-GS-Token")=="not-a-token")
  precondition(request.value(forHTTPHeaderField:"Content-Type")=="text/x-xml-plist" && request.value(forHTTPHeaderField:"Cookie")==nil)
  switch request.url!.lastPathComponent {
  case "listProvisioningProfiles.action":precondition(fields["includeTeamProfiles"] as? Bool == true && fields["appIdId"]==nil && fields["provisioningProfileId"]==nil)
  case "downloadProvisioningProfile.action":precondition(fields["provisioningProfileId"] as? String == "PORTAL1" && fields["appIdId"]==nil)
  case "downloadTeamProvisioningProfile.action":precondition(fields["appIdId"] as? String == "APP1" && fields["provisioningProfileId"]==nil)
  default:fatalError("unexpected endpoint")
  }
  step.after?()
  let url=step.finalURL ?? request.url!
  var headers=["Content-Type":"text/x-xml-plist"]
  if let count=step.declaredLength {headers["Content-Length"]=String(count)}
  let response=HTTPURLResponse(url:url,statusCode:step.status,httpVersion:"HTTP/1.1",headerFields:headers)!
  if step.redirect {
   client?.urlProtocol(self,wasRedirectedTo:URLRequest(url:URL(string:"https://example.invalid/not-apple")!),redirectResponse:HTTPURLResponse(url:url,statusCode:302,httpVersion:"HTTP/1.1",headerFields:nil)!);return
  }
  client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
  if let duringBody=step.duringBody {
   client?.urlProtocol(self,didLoad:Data(step.body.prefix(1)));duringBody();return
  }
  client?.urlProtocol(self,didLoad:step.body)
  client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
}
@main @MainActor struct OriginTransportCases {
 static func plist(_ value:[String:Any])->Data {try! PropertyListSerialization.data(fromPropertyList:value,format:.xml,options:0)}
 static func profile(_ number:Int,team:String="T",bundle:String="app",suffix:String="")->Data {
  let uuid=String(format:"00000000-0000-0000-0000-%012d",number)
  return Data("synthetic-container-prefix".utf8)+plist(["Name":"synthetic","UUID":uuid,"TeamIdentifier":[team],"TeamName":"synthetic","CreationDate":Date(timeIntervalSince1970:1_700_000_000),"ExpirationDate":Date(timeIntervalSince1970:2_000_000_000),"Entitlements":["application-identifier":"PREFIX."+bundle],"LocalProvision":true,"SyntheticRestriction":suffix])
 }
 static func list(_ ids:[Int],portalID:String="PORTAL1",bundle:String="app",result:Int?=0)->Data {
  var value:[String:Any]=["provisioningProfiles":ids.map { ["provisioningProfileId":portalID,"name":"synthetic","UUID":String(format:"00000000-0000-0000-0000-%012d",$0),"dateExpire":Date(timeIntervalSince1970:2_000_000_000),"appId":["identifier":bundle],"isFreeProvisioningProfile":true] as [String:Any] }]
  if let result {value["resultCode"]=result};return plist(value)
 }
 static func download(_ bytes:Data,number:Int=1,portalID:String="PORTAL1",result:Int?=0)->Data {
  var value:[String:Any]=["provisioningProfile":["provisioningProfileId":portalID,"UUID":String(format:"00000000-0000-0000-0000-%012d",number),"encodedProfile":bytes]]
  if let result {value["resultCode"]=result};return plist(value)
 }
 static func envelope(_ bytes:Data,id:Any?,uuid:Any?)->Data {
  var details:[String:Any]=["encodedProfile":bytes]
  if let id {details["provisioningProfileId"]=id};if let uuid {details["UUID"]=uuid}
  return plist(["resultCode":0,"provisioningProfile":details])
 }
 static func operation(_ gate:OriginGate=OriginGate(),valid:Bool=true)throws->AppleProfileOperation {
  var session=Session();session.isValid=valid
  return try DeveloperPortal().makePreservationProfileOperation(team:Team(identifier:"T"),session:session,bundleIdentifier:"app",validateOwnership:{try gate.check()})
 }
 static func expectReject(expected:AppleProfileEvidenceError?=nil,_ body:() async throws->Void) async {
  do {try await body();fatalError("unexpected origin acceptance")}catch{if let expected {precondition((error as? AppleProfileEvidenceError)==expected)}}
 }
 static func main() async throws {
  AppleProfileTransportTesting.protocolClasses=[OriginURLProtocol.self]
  let old=profile(1),candidate=profile(2),uuid=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
  let listPath="listProvisioningProfiles.action",downloadPath="downloadProvisioningProfile.action",generationPath="downloadTeamProvisioningProfile.action"
  var passed:[String]=[]
  let op=try Self.operation();OriginWire.shared.reset([OriginStep(body:list([1])),OriginStep(body:download(old))])
  let existing=try await op.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app")
  try op.authorize(existing,exactCMS:old)
  precondition(OriginWire.shared.calls==[listPath,downloadPath] && existing.cmsData==old && existing.role == .existing)
  passed.append("origin-readonly-exact-list-download-mints")
  await expectReject{try op.authorize(existing,exactCMS:profile(1,suffix:"changed"))};passed.append("origin-receipt-same-uuid-changed-body-rejected")
  let other=try Self.operation();await expectReject{try other.authorize(existing,exactCMS:old)};passed.append("origin-receipt-other-operation-rejected")
  OriginWire.shared.reset([OriginStep(body:download(candidate,number:2))])
  let generated=try await op.generateCandidate(for:AppID(identifier:"APP1",bundleIdentifier:"app"))
  precondition(OriginWire.shared.calls==[generationPath] && generated.role == .candidate)
  try op.authorize(generated,exactCMS:candidate);passed.append("origin-candidate-own-response-mints")
  let origin=V3AppleProfileOriginEvidence(operation:op,candidate:generated)
  try origin.authorizeCandidate(candidate)
  passed.append("origin-candidate-consumer-own-bytes")
  await expectReject{try origin.authorizeCandidate(old)};passed.append("origin-candidate-consumer-historical-bytes-rejected")
  let wrongOperation=V3AppleProfileOriginEvidence(operation:other,candidate:generated)
  await expectReject{try wrongOperation.authorizeCandidate(candidate)};passed.append("origin-candidate-consumer-other-operation-rejected")
  await expectReject{try origin.authorizeCandidate(profile(2,suffix:"changed"))};passed.append("origin-candidate-consumer-sameuuid-changedbody-rejected")
  // Explicit override candidates may be downloaded from an existing portal
  // record, but still need their own exact operation-owned response receipt.
  let overrideOrigin=V3AppleProfileOriginEvidence(operation:op,candidate:existing)
  try overrideOrigin.authorizeCandidate(old);passed.append("origin-candidate-consumer-exact-override-receipt")
  op.invalidate();await expectReject{try origin.authorizeCandidate(candidate)};passed.append("origin-invalidated-operation-rejected")

  let listFailures:[(String,OriginStep)]=[
   ("origin-free-endpoint-denial-no-generation",OriginStep(body:list([1],result:1200))),
   ("origin-empty-list-rejected",OriginStep(body:list([]))),
   ("origin-duplicate-uuid-list-rejected",OriginStep(body:list([1,1]))),
   ("origin-duplicate-portal-id-rejected",OriginStep(body:list([1,2]))),
   ("origin-list-wrong-uuid-rejected",OriginStep(body:list([2]))),
   ("origin-list-wrong-bundle-rejected",OriginStep(body:list([1],bundle:"other"))),
   ("origin-list-missing-result-rejected",OriginStep(body:list([1],result:nil))),
   ("origin-list-non200-rejected",OriginStep(body:list([1]),status:403)),
   ("origin-list-wrong-final-origin-rejected",OriginStep(body:list([1]),finalURL:URL(string:"https://example.invalid/listProvisioningProfiles.action")!)),
   ("origin-list-wrong-final-endpoint-rejected",OriginStep(body:list([1]),finalURL:URL(string:"https://developerservices2.apple.com/services/QH65B2/ios/downloadTeamProvisioningProfile.action")!)),
   ("origin-list-redirect-rejected",OriginStep(body:Data(),redirect:true)),
   ("origin-declared-oversize-rejected",OriginStep(body:list([1]),declaredLength:4*1024*1024+1)),
   ("origin-streamed-oversize-rejected",OriginStep(body:Data(repeating:65,count:4*1024*1024+1))),
   ("origin-malformed-response-rejected",OriginStep(body:Data("not-a-plist".utf8)))
  ]
  for (name,step) in listFailures {
   let operation=try Self.operation();OriginWire.shared.reset([step])
   let expected:AppleProfileEvidenceError? = ["origin-empty-list-rejected","origin-list-wrong-uuid-rejected"].contains(name) ? .recordNotFound : (name=="origin-duplicate-uuid-list-rejected" ? .ambiguousProfile:nil)
   await expectReject(expected:expected){_ = try await operation.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app")}
   precondition(OriginWire.shared.calls==[listPath]);passed.append(name)
  }
  let downloadFailures:[(String,Data)]=[
   ("origin-download-body-mismatch-rejected",download(profile(1,suffix:"changed"))),
   ("origin-download-returned-id-mismatch-rejected",download(old,portalID:"OTHER")),
   ("origin-download-returned-uuid-mismatch-rejected",download(old,number:2)),
   ("origin-download-profile-team-mismatch-rejected",download(profile(1,team:"OTHER"))),
   ("origin-download-profile-bundle-mismatch-rejected",download(profile(1,bundle:"other"))),
   ("origin-download-profile-uuid-mismatch-rejected",download(candidate)),
   ("origin-download-provider-error-rejected",download(old,result:1200)),
   ("origin-download-missing-result-rejected",download(old,result:nil))
  ]
  for (name,body) in downloadFailures {
   let operation=try Self.operation();OriginWire.shared.reset([OriginStep(body:list([1])),OriginStep(body:body)])
   await expectReject{_ = try await operation.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app")}
   precondition(OriginWire.shared.calls==[listPath,downloadPath]);passed.append(name)
  }
  for afterDownload in [false,true] {
   let gate=OriginGate(),operation=try Self.operation(gate)
   var steps=[OriginStep(body:list([1])),OriginStep(body:download(old))]
   steps[afterDownload ? 1:0].after={gate.deny()};OriginWire.shared.reset(steps)
   await expectReject{_ = try await operation.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app")}
   precondition(OriginWire.shared.calls.count==(afterDownload ? 2:1));passed.append(afterDownload ? "origin-owner-drift-after-download-rejected":"origin-owner-drift-after-list-rejected")
  }
  do {
   let operation=try Self.operation();OriginWire.shared.reset([OriginStep(body:list([1]),after:{operation.invalidate()})])
   await expectReject{_ = try await operation.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app")}
   precondition(OriginWire.shared.calls==[listPath]);passed.append("origin-invalidated-inflight-read-rejected")
  }
  OriginWire.shared.reset([])
  await expectReject{_ = try Self.operation(valid:false)};precondition(OriginWire.shared.calls.isEmpty);passed.append("origin-expired-session-no-request")
  do {
   let operation=try Self.operation();let task=Task {
    withUnsafeCurrentTask{$0?.cancel()}
    return try await operation.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app")
   }
   await expectReject{_ = try await task.value};precondition(OriginWire.shared.calls.isEmpty);passed.append("origin-cancelled-task-no-request")
  }
  do {
   let operation=try Self.operation();await expectReject{_ = try await operation.generateCandidate(for:AppID(identifier:"APP2",bundleIdentifier:"other"))}
   precondition(OriginWire.shared.calls.isEmpty);passed.append("origin-candidate-wrong-target-no-request")
  }
  // Optional envelope metadata is not the embedded identity authority.
  let uuidText=uuid.uuidString
  for (label,id,returnedUUID) in [("missing-id",nil as String?,uuidText as String?), ("missing-uuid","PORTAL1" as String?,nil as String?), ("missing-both",nil as String?,nil as String?)] {
   let operation=try Self.operation()
   OriginWire.shared.reset([OriginStep(body:list([1])),OriginStep(body:envelope(old,id:id,uuid:returnedUUID))])
   let evidence=try await operation.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app")
   try operation.authorize(evidence,exactCMS:old)
   precondition(OriginWire.shared.calls==[listPath,downloadPath]);passed.append("origin-existing-envelope-"+label+"-accepted")
   OriginWire.shared.reset([OriginStep(body:envelope(old,id:id,uuid:returnedUUID))])
   let renewed=try await operation.generateCandidate(for:AppID(identifier:"APP1",bundleIdentifier:"app"))
   try operation.authorize(renewed,exactCMS:old)
   precondition(OriginWire.shared.calls==[generationPath]);passed.append("origin-candidate-envelope-"+label+"-accepted")
  }
  let malformedEnvelopes:[(String,Data)]=[
   ("empty-id",envelope(old,id:"",uuid:uuidText)),
   ("nonascii-id",envelope(old,id:"é",uuid:uuidText)),
   ("empty-uuid",envelope(old,id:"PORTAL1",uuid:"")),
   ("malformed-uuid",envelope(old,id:"PORTAL1",uuid:"not-a-uuid")),
   ("wrongtype-id",envelope(old,id:123,uuid:uuidText)),
   ("wrongtype-uuid",envelope(old,id:"PORTAL1",uuid:123))
  ]
  for (label,body) in malformedEnvelopes {
   let operation=try Self.operation();OriginWire.shared.reset([OriginStep(body:list([1])),OriginStep(body:body)])
   await expectReject{_ = try await operation.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app")}
   precondition(OriginWire.shared.calls==[listPath,downloadPath]);passed.append("origin-existing-envelope-"+label+"-rejected")
   OriginWire.shared.reset([OriginStep(body:body)])
   await expectReject{_ = try await operation.generateCandidate(for:AppID(identifier:"APP1",bundleIdentifier:"app"))}
   precondition(OriginWire.shared.calls==[generationPath]);passed.append("origin-candidate-envelope-"+label+"-rejected")
  }
  do {
   let operation=try Self.operation();OriginWire.shared.reset([OriginStep(body:list([1])),OriginStep(body:envelope(candidate,id:nil,uuid:nil))])
   await expectReject{_ = try await operation.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app")}
   passed.append("origin-envelope-absent-embedded-uuid-mismatch-rejected")
  }
  do {
   let operation=try Self.operation(),control=OriginTaskControl()
   OriginWire.shared.reset([OriginStep(body:list([1]),duringBody:{control.cancel()})])
   let task=Task { _ = try await operation.corroborateExisting(installedCMS:old,uuid:uuid,bundleIdentifier:"app") }
   control.set(task)
   await expectReject(expected:.cancelled){try await task.value}
   precondition(OriginWire.shared.calls==[listPath]);passed.append("origin-task-cancelled-midstream-no-generation")
  }
  precondition(passed.count==58 && Set(passed).count==58)
  let report:[String:Any]=["schema":"preservation-origin-transport-v1","status":"PASS","cases":passed,"network_executed":false,"platform_tls_executed":false,"cms_verified":false,"device_executed":false]
  print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
 }
}
