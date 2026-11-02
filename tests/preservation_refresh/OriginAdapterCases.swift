// Real fetch/state/decoder/refresh; explicit portal and cryptography SDK doubles.
// This establishes control flow only, not TLS/CMS/device execution.
enum OriginAdapterCases {
 static func run(now:Date,makeContext:()->InstallAppOperationContext,
  execute:(InstallAppOperationContext) async throws->Void) async throws->[String] {
  var passed:[String]=[]
  func setup(oldUnknown:Bool=true,candidateUnknown:Bool=true)->(InstallAppOperationContext,ALTProvisioningProfile,ALTProvisioningProfile) {
   let c=makeContext();FixtureCMSBoundary.reset()
   let old=AuthenticatedAdapterCases.register(40,1000,now:now),candidate=AuthenticatedAdapterCases.register(41,2000,now:now)
   if oldUnknown {FixtureCMSBoundary.innerFailures[fixturePayloads[old.data]!["DER-Encoded-Profile"] as! Data] = .unsupportedSigner}
   if candidateUnknown {FixtureCMSBoundary.innerFailures[fixturePayloads[candidate.data]!["DER-Encoded-Profile"] as! Data] = .unsupportedSigner}
   PortalProbe.shared.existingProfiles=[:];PortalProbe.shared.failCorroboration=true;PortalProbe.shared.candidate=candidate
   c.readInstalledProvisioningProfiles={PortalProbe.shared.calls.append("read");return Injection.shared.count>0 ? [old.data,candidate.data]:[old.data]}
   return(c,old,candidate)
  }
  func rejected(_ c:InstallAppOperationContext,allowCandidateLookup:Bool=false) async {
   let main=c.installedApp!.expirationDate,ext=c.installedApp!.appExtensions[0].expirationDate
   do {try await execute(c);fatalError("candidate without independent authority accepted")}catch{}
   precondition(Injection.shared.count==0 && c.installedApp!.expirationDate==main && c.installedApp!.appExtensions[0].expirationDate==ext)
   if !allowCandidateLookup {precondition(!PortalProbe.shared.calls.contains("list-existing-profiles") && !PortalProbe.shared.calls.contains("download-exact-existing-profile"))}
   if let operation=PortalProbe.shared.lastOriginOperation {precondition(!operation.active)}
  }
  for (name,oldUnknown,candidateUnknown) in [
   ("origin-unknown-old-not-listed-candidate-own-receipt",true,true),
   ("origin-pinned-baseline-unknown-candidate-own-receipt",false,true),
   ("origin-unknown-baseline-pinned-candidate-preserved",true,false),
   ("origin-pinned-old-pinned-candidate-still-own-receipt",false,false)] {
   let(c,_,_)=setup(oldUnknown:oldUnknown,candidateUnknown:candidateUnknown)
   try await execute(c)
   precondition(Injection.shared.count==1 && c.refreshVerification?.installAcknowledged==true && c.refreshVerification?.profileStore == .matched)
   precondition(PortalProbe.shared.calls.contains("origin-operation") && PortalProbe.shared.calls.filter{$0=="generate-existing-id-profile"}.count==1)
   precondition(FixtureCMSBoundary.inspectionCalls>0 && PortalProbe.shared.originInvalidations==1 && PortalProbe.shared.lastOriginOperation?.active==false)
   precondition(!PortalProbe.shared.calls.contains("list-existing-profiles") && !PortalProbe.shared.calls.contains("download-exact-existing-profile"))
   passed.append(name)
  }
  for oldUnknown in [false,true] {
   let(c,_,_)=setup(oldUnknown:oldUnknown,candidateUnknown:false)
   PortalProbe.shared.wrongCandidateOperation=true;await rejected(c)
   passed.append(oldUnknown ? "origin-candidate-other-operation-receipt-no-install":"origin-pinned-candidate-other-operation-receipt-no-install")
  }
  do {
   let(c,_,_)=setup();PortalProbe.shared.failDownload=true;await rejected(c)
   precondition(PortalProbe.shared.calls.filter{$0=="generate-existing-id-profile"}.count==1)
   passed.append("origin-candidate-response-unavailable-no-fallback")
  }
  do {
   let(c,_,candidate)=setup();FixtureCMSBoundary.inspectionFailures[fixturePayloads[candidate.data]!["DER-Encoded-Profile"] as! Data] = .signerTimeInvalid
   await rejected(c);passed.append("origin-candidate-expired-crypto-no-install")
  }
  do {
   let(c,_,_)=setup();var allowed=true;c.profileMutationAdmission={if !allowed {throw CancellationError()}}
   PortalProbe.shared.afterGeneration={allowed=false};await rejected(c)
   passed.append("origin-admission-revoked-after-generation-no-install")
  }
  for stage in ["crypto","database"] {
   let(c,old,candidate)=setup();var reads=0;var hookDidRun=false
   c.readInstalledProvisioningProfiles={
    reads += 1;PortalProbe.shared.calls.append("read")
    if reads==3 {
     if stage=="crypto" {FixtureCMSBoundary.duringInspection={hookDidRun=true;PortalProbe.shared.lastOriginOperation?.invalidate()}}
     else {c.dbBackgroundContext.afterPerform={hookDidRun=true;PortalProbe.shared.lastOriginOperation?.invalidate();c.dbBackgroundContext.afterPerform=nil}}
    }
    return Injection.shared.count>0 ? [old.data,candidate.data]:[old.data]
   }
   await rejected(c);precondition(reads>=3 && hookDidRun)
   passed.append("origin-revoked-after-fresh-"+stage+"-no-install")
  }
  // A supplied profile is not a fresh generation response, even if its signer
  // has a known pin. No old profile listing may be used as a substitute.
  do {
   let(c,_,candidate)=setup(oldUnknown:false,candidateUnknown:false);c.overrideProvisioningProfile=candidate
   await rejected(c,allowCandidateLookup:true);precondition(PortalProbe.shared.corroboratedUUIDs==[candidate.uuid]);passed.append("origin-supplied-static-profile-without-fresh-receipt-rejected")
  }
  do {
   let(c,_,candidate)=setup(oldUnknown:true,candidateUnknown:true);c.overrideProvisioningProfile=candidate
   PortalProbe.shared.failCorroboration=false;PortalProbe.shared.existingProfiles=[candidate.uuid:candidate]
   try await execute(c)
   precondition(Injection.shared.count==1 && PortalProbe.shared.corroboratedUUIDs==[candidate.uuid])
   precondition(!PortalProbe.shared.calls.contains("generate-existing-id-profile") && c.refreshVerification?.profileStore == .matched)
   passed.append("origin-supplied-candidate-exact-own-receipt-no-old-lookup")
  }
  FixtureCMSBoundary.reset();return passed
 }
}
