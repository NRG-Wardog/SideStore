// Actual fetch/state/decoder/refresh with explicit portal/CMS SDK doubles.
// Actual transport/private receipt minting is separately covered by preservation_origin.
enum OriginAdapterCases {
 static func run(now:Date,makeContext:()->InstallAppOperationContext,
  execute:(InstallAppOperationContext) async throws->Void,
  register:(Int,Double,String,String?)->ALTProvisioningProfile,
  configure:(InstallAppOperationContext,[ALTProvisioningProfile],ALTProvisioningProfile,ALTProvisioningProfile?)->Void) async throws->[String] {
  var passed:[String]=[]
  func unknown(_ p:ALTProvisioningProfile) { FixtureCMSBoundary.innerFailures[fixturePayloads[p.data]!["DER-Encoded-Profile"] as! Data] = .unsupportedSigner }
  func setup(oldUnknown:Bool=true,candidateUnknown:Bool=true,hidden:String?=nil)->(InstallAppOperationContext,ALTProvisioningProfile,ALTProvisioningProfile) {
   let c=makeContext();FixtureCMSBoundary.reset()
   let old=register(40,1000,"group.existing",hidden),candidate=register(41,2000,"group.existing",nil)
   if oldUnknown {unknown(old)};if candidateUnknown {unknown(candidate)}
   PortalProbe.shared.existingProfiles=[old.uuid:old]
   configure(c,[old],candidate,nil);return(c,old,candidate)
  }
  func rejected(_ c:InstallAppOperationContext,beforeGeneration:Bool) async {
   let main=c.installedApp!.expirationDate,ext=c.installedApp!.appExtensions[0].expirationDate
   do {try await execute(c);fatalError("unbound origin accepted")}catch{}
   precondition(Injection.shared.count==0 && c.installedApp!.expirationDate==main && c.installedApp!.appExtensions[0].expirationDate==ext)
   precondition(PortalProbe.shared.calls.contains("generate-existing-id-profile") == !beforeGeneration)
   if let operation=PortalProbe.shared.lastOriginOperation {precondition(!operation.active)}
  }
  for (name,oldUnknown,candidateUnknown) in [
   ("origin-fullflow-exact-installed-and-candidate-receipts",true,true),
   ("origin-pinned-baseline-unknown-candidate-own-receipt",false,true),
   ("origin-unknown-baseline-pinned-candidate-preserved",true,false)] {
   let(c,_,_)=setup(oldUnknown:oldUnknown,candidateUnknown:candidateUnknown)
   try await execute(c)
   precondition(Injection.shared.count==1 && c.refreshVerification?.installAcknowledged==true && c.refreshVerification?.profileStore == .matched)
   precondition(FixtureCMSBoundary.inspectionCalls>0 && PortalProbe.shared.originInvalidations==1 && PortalProbe.shared.lastOriginOperation?.active==false)
   if oldUnknown {
    let list=PortalProbe.shared.calls.firstIndex(of:"list-existing-profiles")!,download=PortalProbe.shared.calls.firstIndex(of:"download-exact-existing-profile")!,generation=PortalProbe.shared.calls.firstIndex(of:"generate-existing-id-profile")!
    precondition(list<download && download<generation)
   } else {precondition(!PortalProbe.shared.calls.contains("list-existing-profiles"))}
   passed.append(name)
  }
  do {
   let(c,old,candidate)=setup();let second=register(42,1200,"group.existing",nil);unknown(second)
   PortalProbe.shared.existingProfiles[second.uuid]=second;configure(c,[old,second],candidate,nil)
   try await execute(c);precondition(Injection.shared.count==1 && PortalProbe.shared.calls.filter{$0=="download-exact-existing-profile"}.count==2)
   passed.append("origin-each-installed-profile-needs-own-receipt")
  }
  for mode in ["unsupported","missing","mismatched"] {
   let(c,old,_)=setup()
   if mode=="unsupported" {PortalProbe.shared.failCorroboration=true}
   if mode=="missing" {PortalProbe.shared.existingProfiles=[:]}
   if mode=="mismatched" {
    PortalProbe.shared.existingProfiles[old.uuid]=ALTProvisioningProfile(uuid:old.uuid,data:Data([99]),bundleIdentifier:"app",teamIdentifier:"T",expirationDate:old.expirationDate,certificates:old.certificates)
   }
   await rejected(c,beforeGeneration:true);passed.append("origin-"+mode+"-existing-evidence-no-generation")
  }
  for(error,label) in [(ProfileCMSVerificationError.signerTimeInvalid,"expired"),(.verificationFailed,"body-bitflip"),(.unsupportedRepresentation,"malformed")] {
   let(c,old,_)=setup();FixtureCMSBoundary.inspectionFailures[fixturePayloads[old.data]!["DER-Encoded-Profile"] as! Data]=error
   await rejected(c,beforeGeneration:true);precondition(FixtureCMSBoundary.inspectionCalls>0)
   passed.append("origin-installed-"+label+"-no-generation")
  }
  do {
   let(c,_,_)=setup(hidden:"group.hidden");await rejected(c,beforeGeneration:true)
   passed.append("origin-installed-inner-binding-mismatch-no-generation")
  }
  for stage in ["list","download"] {
   let(c,_,_)=setup();var allowed=true;c.profileMutationAdmission={if !allowed {throw CancellationError()} }
   if stage=="list" {PortalProbe.shared.afterList={allowed=false}}else{PortalProbe.shared.afterExisting={allowed=false}}
   await rejected(c,beforeGeneration:true);passed.append("origin-admission-revoked-after-"+stage+"-no-generation")
  }
  do {
   let(c,_,_)=setup();PortalProbe.shared.wrongCandidateOperation=true;await rejected(c,beforeGeneration:false)
   passed.append("origin-candidate-other-operation-receipt-no-install")
  }
  do {
   let(c,old,_)=setup();let changed=register(43,2100,"group.changed",nil);unknown(changed);configure(c,[old],changed,nil)
   await rejected(c,beforeGeneration:false);passed.append("origin-candidate-authority-change-no-install")
  }
  do {
   let(c,_,candidate)=setup();FixtureCMSBoundary.inspectionFailures[fixturePayloads[candidate.data]!["DER-Encoded-Profile"] as! Data] = .signerTimeInvalid
   await rejected(c,beforeGeneration:false);passed.append("origin-candidate-expired-crypto-no-install")
  }
  do {
   let(c,old,candidate)=setup();let unrelated=register(44,1300,"group.existing",nil);unknown(unrelated)
   configure(c,[old],candidate,unrelated);await rejected(c,beforeGeneration:false)
   passed.append("origin-same-leaf-unrelated-fresh-profile-no-install")
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
   await rejected(c,beforeGeneration:false);precondition(reads>=3 && hookDidRun);passed.append("origin-revoked-after-fresh-"+stage+"-no-install")
  }
  FixtureCMSBoundary.reset();return passed
 }
}
