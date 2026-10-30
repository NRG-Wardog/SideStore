@main struct Main {
 @MainActor static func main() throws {
  let run=UUID().uuidString,request=UUID().uuidString
  let facts=["refresh_failure_kind":"invalidParameters","local_precondition":"legacyProofUnavailable","refresh_target_scope":"nonHost"]
  let failure:[String:Any]=["version":1,"underlyingDomain":"none","underlyingCode":0,"operation":"refresh","stage":"command","code":"failed","sourceStep":"refreshApplication","correlationID":run,"signingContext":facts]
  let verification:[String:Any]=["version":1,"mutationDispatched":false,"installAcknowledged":false,"profileStore":"unavailable","renewal":"unknown","certificate":"unknown"]
  let row:[String:Any]=["bundle_id":"app","success":false,"failure":failure,"verification":verification]
  let manifest:[String:Any]=["schema":"LiveContainerRefreshManifestV2","requested_ids":["app","other"],"skipped_ids":[String](),"host_handoff":false,"version":2,"run_id":run,"expected_ids":["app","other"],"results":[row,["bundle_id":"other","success":true]]]
  let ledger:[String:Any]=["run_id":run,"request_id":request,"state":"failed"]
  var count=0
  func check(_ ok:Bool,_ name:String)throws{guard ok else{throw NSError(domain:name,code:1)};count+=1;print("PASS "+name)}
  @MainActor func rejects(_ operation:@MainActor () throws -> Void)->Bool { do { try operation(); return false } catch { return true } }
  @MainActor func reset(){
   app=InstalledApp();DatabaseManager.shared.team=Team();AuthManager.shared.v3IdentityIsStable=true;AuthManager.shared.v3IdentityStamp="identity"
   ALTApplication.available=true;ALTApplication.extensionIDs=["app.widget"]
   AppBundleFingerprint.digest="strict";AppBundleFingerprint.legacy="legacy";AppBundleFingerprint.calls=[]
   CertificateManager.shared.recorded=Cert();CertificateManager.shared.signer=Signer()
   V3HeadlessRuntime.shared.operations.activeMutationID=nil;V3OperationRecoveryJournal.held=nil;V3OperationRecoveryJournal.directHeld=nil
   let d=V3SharedAppGroup.defaults;for key in d.dictionaryRepresentation().keys{d.removeObject(forKey:key)}
   d.set(manifest,forKey:"liveContainerAutoRefreshVerification");d.set([run:ledger],forKey:"liveContainerAutoRefreshRunLedger")
  }
  func eligible(_ m:[String:Any],_ l:[String:Any]=ledger)->Bool{V3LegacyReplacementPolicy.eligible(manifest:m,ledger:l,runID:run,requestID:request,bundleID:"app")}
  try check(eligible(manifest),"mixed run selects failed target only")
  for (key,value) in [("request_id","wrong"),("run_id","wrong"),("state","completed")]{var l=ledger;l[key]=value;try check(!eligible(manifest,l),"ledger "+key)}
  for value in [true,2.0,1,"2"] as [Any] {var m=manifest;m["version"]=value;try check(!eligible(m),"strict manifest version \(value)")}
  for key in ["mutationDispatched","installAcknowledged"]{var v=verification;v[key]=true;var r=row;r["verification"]=v;var m=manifest;m["results"]=[r,["bundle_id":"other","success":true]];try check(!eligible(m),"reject "+key)}
  var m=manifest;m["results"]=[row];try check(!eligible(m),"partial manifest")
  var successful=row;successful["success"]=true;m=manifest;m["results"]=[successful,["bundle_id":"other","success":true]];try check(!eligible(m),"successful target refused")
  for value in [true,1.0,2,"1"] as [Any]{try check(!V3LegacyReplacementPolicy.consent(value,confirmed:true),"strict consent \(value)")}
  try check(V3LegacyReplacementPolicy.consent(1,confirmed:true),"explicit versioned consent")
  try check(!V3LegacyReplacementPolicy.consent(1,confirmed:false),"cancel consent")
  reset();let center=V3LegacyReplacementAssessments();let result=center.prepare(target:"target",runID:run,requestID:request)
  try check(result["eligible"] as? Bool == true,"read only prepare eligible")
  try check(V3OperationRecoveryJournal.held == nil && V3HeadlessRuntime.shared.operations.activeMutationID == nil,"prepare does not reserve mutation")
  let token=result["token"] as! String,session=UUID().uuidString
  try check(rejects { _ = try center.consume(token,session:session) },"unreserved token refused")
  reset();let c=V3LegacyReplacementAssessments();let t=c.prepare(target:"target",runID:run,requestID:request)["token"] as! String
  try c.reserve(t,session:session);let assessment=try c.consume(t,session:session)
  try check(assessment.binding.extensionIdentities==["app.widget":"app.TEAM.widget"],"exact extensions bound")
  try check(rejects { _ = try c.consume(t,session:session) },"double dispatch refused")
  app.refreshedDate=Date();try check(rejects { _ = try c.validate(assessment) },"changed database refused")
  let variants:[(String,()->Void)]=[
   ("other operation",{V3HeadlessRuntime.shared.operations.activeMutationID="other"}),
   ("unknown ack journal",{V3OperationRecoveryJournal.held="uncertain"}),
   ("direct journal",{V3OperationRecoveryJournal.directHeld="held"}),
   ("wrong certificate fallback",{CertificateManager.shared.signer?.x509.serialNumber="wrong"}),
   ("wrong certificate DER",{CertificateManager.shared.signer?.x509.data=Data([9])}),
   ("missing signer",{CertificateManager.shared.signer=nil}),
   ("missing recorded cert",{CertificateManager.shared.recorded=nil}),
   ("recorded serial mismatch",{app.certificateSerialNumber="other"}),
   ("unknown team",{app.team=nil}),
   ("team changed",{DatabaseManager.shared.team?.identifier="other"}),
   ("source missing",{ALTApplication.available=false}),
   ("source extension missing",{ALTApplication.extensionIDs=[]}),
   ("source extra extension",{ALTApplication.extensionIDs.append("extra")}),
   ("source symlink rejected",{AppBundleFingerprint.digest=nil}),
   ("cache association changed",{AppBundleFingerprint.legacy="other"}),
   ("host refused",{app.bundleIdentifier="host"})]
  for (name,change) in variants{reset();change();let response=V3LegacyReplacementAssessments().prepare(target:"target",runID:run,requestID:request);try check(response["eligible"] as? Bool == false && response["token"] == nil,name)}
  reset();AppBundleFingerprint.digest=nil;_ = V3LegacyReplacementAssessments().prepare(target:"target",runID:run,requestID:request)
  try check(AppBundleFingerprint.calls==["strict"],"strict hash before legacy walk")
  reset();var now=Date();let expiry=V3LegacyReplacementAssessments(now:{now});let expired=expiry.prepare(target:"target",runID:run,requestID:request)["token"] as! String;now=now.addingTimeInterval(121)
  try check(rejects { try expiry.reserve(expired,session:session) },"expired token refused")
  print("LEGACY_REPLACEMENT_POLICY_PASS cases=\(count)")
 }
}
