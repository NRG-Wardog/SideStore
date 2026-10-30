@main struct Main {
 static func main() async throws {
  var cases:[String]=[]
  let binding=V3LegacyReplacementBinding(originalBundleID:"original.app",resignedBundleID:"signed.app",customBundleID:nil,teamID:"T",certificateSerial:"S",certificateDER:Data([1]),sourceFingerprint:"cache",sourceTreeDigest:"tree",extensionIdentities:[:],recordDigest:"record")
  func context()->FixtureContext {let c=FixtureContext();c.legacyReplacementBinding=binding;c.handler.legacyReplacementBinding=binding;return c}
  let admissionCases:[(String,(FixtureContext)->Void,Bool)] = [
   ("exact",{_ in},true), ("global-reuse-rejected",{$0.useMainProfile=true},false),
   ("experimental-reuse-rejected",{$0.validatedReuseMain=true},false),
   ("wrong-fallback-serial",{$0.targetSigningCertificate?.serialNumber="OTHER"},false),
   ("wrong-fallback-DER",{$0.targetSigningCertificate?.x509.data=Data([9])},false),
   ("expired-certificate",{$0.targetSigningCertificate?.x509.expiryDate=Date.distantPast},false),
   ("missing-certificate",{$0.targetSigningCertificate=nil},false),
   ("original-id-drift",{$0.bundleIdentifier="other"},false),
   ("assigned-profile-rejected",{$0.overrideProvisioningProfile=ALTProvisioningProfile()},false),
   ("cancel-admission",{$0.profileMutationAdmission={throw CancellationError()}},false),
   ("late-expiry",{$0.handler.admission={throw OperationError.invalidParameters("expired")}},false)
  ]
  for (name,change,expected) in admissionCases {let c=context();change(c);var admitted=false;do{try await c.validateLegacyReplacementAdmission();admitted=true}catch{};precondition(admitted==expected,name);cases.append(name)}
  let signedCases:[(String,(ALTApplication)->Void,Bool)] = [
   ("signed-exact",{_ in},true),
   ("signed-missing-both-appid",{$0.entitlements.removeValue(forKey:.applicationIdentifier);$0.provisioningProfile?.entitlements.removeValue(forKey:.applicationIdentifier)},false),
   ("signed-missing-one-appid",{$0.entitlements.removeValue(forKey:.applicationIdentifier)},false),
   ("signed-team-drift",{$0.entitlements[ALTEntitlement(rawValue:"com.apple.developer.team-identifier")]="OTHER"},false),
   ("signed-extension-added",{$0.appExtensions=[ALTApplication()]},false),
   ("signed-id-drift",{$0.bundleIdentifier="other"},false)
  ]
  for(name,change,expected)in signedCases {let c=context();let app=ALTApplication();change(app);var admitted=false;do{try c.validateLegacyReplacementBundle(app,signed:true);admitted=true}catch{};precondition(admitted==expected,name);cases.append(name)}
  do {let c=context();var p=ALTProvisioningProfile();p.teamIdentifier="OTHER";var admitted=false;do{try c.validateLegacyReplacementProfiles(["original.app":p]);admitted=true}catch{};precondition(!admitted);cases.append("profile-team-drift")}
  let originalExtension="original.app.original.app.ext",signedExtension="signed.app.original.app.ext"
  let extended=V3LegacyReplacementBinding(originalBundleID:"original.app",resignedBundleID:"signed.app",customBundleID:"custom.app",teamID:"T",certificateSerial:"S",certificateDER:Data([1]),sourceFingerprint:"cache",sourceTreeDigest:"tree",extensionIdentities:[originalExtension:signedExtension],recordDigest:"record")
  func extendedContext()->FixtureContext {let c=context();c.legacyReplacementBinding=extended;c.handler.legacyReplacementBinding=extended;c.customBundleIdentifier="custom.app";return c}
  for variant in ["exact","missing","wrong-id","extra"] {
   let c=extendedContext();let main=ALTApplication(),child=ALTApplication();child.bundleIdentifier=signedExtension
   var profile=ALTProvisioningProfile();profile.bundleIdentifier=signedExtension;profile.entitlements[.applicationIdentifier]="OTHER-PREFIX."+signedExtension
   child.provisioningProfile=profile;child.entitlements[.applicationIdentifier]="OTHER-PREFIX."+signedExtension
   main.appExtensions=[child]
   if variant=="missing" {main.appExtensions=[]};if variant=="wrong-id" {child.bundleIdentifier="unrelated"};if variant=="extra" {main.appExtensions.append(ALTApplication())}
   var admitted=false;do{try c.validateLegacyReplacementBundle(main,signed:true);admitted=true}catch{}
   precondition(admitted==(variant=="exact"));cases.append("required-extensions-"+variant)
  }
  for variant in ["exact","duplicate-uuid","wrong-der","wrong-serial"] {
   let c=extendedContext();let main=ALTProvisioningProfile();var child=ALTProvisioningProfile();child.bundleIdentifier=signedExtension
   if variant=="duplicate-uuid" {child.uuid=main.uuid};if variant=="wrong-der" {child.certificates=[Cert(serialNumber:"S",data:Data([2]))]};if variant=="wrong-serial" {child.certificates=[Cert(serialNumber:"OTHER",data:Data([1]))]}
   let key=try c.legacyReplacementProfileKey(originalID:originalExtension)
   precondition(key=="custom.app.original.app.ext")
   var admitted=false;do{try c.validateLegacyReplacementProfiles(["custom.app":main,key:child]);admitted=true}catch{}
   precondition(admitted==(variant=="exact"));cases.append("required-separate-profiles-"+variant)
  }
  do {
   let c=context();let db=FixtureDB()
   let cancelled=Task {withUnsafeCurrentTask {$0?.cancel()};try await actualPostAcknowledgementSave(context:c,backgroundContext:db)}
   try await cancelled.value;precondition(db.saved==1 && !db.hasChanges)
   try await actualPostAcknowledgementSave(context:c,backgroundContext:db);precondition(db.saved==1)
   cases.append("post-ack-cancel-still-persists-once")
  }
  do {let c=context();let db=FixtureDB();db.fail=true;var typed=false
   do {try await actualPostAcknowledgementSave(context:c,backgroundContext:db)}catch is V3PostMutationPersistenceError {typed=true}catch{}
   precondition(typed && db.saved==1 && db.hasChanges);cases.append("post-ack-save-failure-not-success")
  }
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let canonical=root.resolvingSymlinksInPath().standardizedFileURL
  let input=canonical.appendingPathComponent("Input.app",isDirectory:true)
  try FileManager.default.createDirectory(at:input,withIntermediateDirectories:false)
  try Data("synthetic input".utf8).write(to:input.appendingPathComponent("Fixture"))
  let model=ALTApplication();model.bundleIdentifier="original.app";model.fileURL=input;ALTApplication.sourceModel=model
  let stagedBinding=V3LegacyReplacementBinding(originalBundleID:"original.app",resignedBundleID:"signed.app",customBundleID:nil,teamID:"T",certificateSerial:"S",certificateDER:Data([1]),sourceFingerprint:AppBundleFingerprint.computeOriginalCacheKey(for:input)!,sourceTreeDigest:AppBundleFingerprint.compute(for:input)!,extensionIdentities:[:],recordDigest:"record")
  for variant in ["exact-copy","changed-source","symlink-source"] {
   let c=context();c.legacyReplacementBinding=stagedBinding;c.handler.legacyReplacementBinding=stagedBinding;c.targetAppBundle=model
   c.temporaryDirectory=canonical.appendingPathComponent(variant,isDirectory:true)
   try FileManager.default.createDirectory(at:c.temporaryDirectory,withIntermediateDirectories:false)
   if variant=="changed-source" {try Data("changed".utf8).write(to:input.appendingPathComponent("Fixture"))}
   if variant=="symlink-source" {try Data("synthetic input".utf8).write(to:input.appendingPathComponent("Fixture"));try FileManager.default.createSymbolicLink(at:input.appendingPathComponent("escape"),withDestinationURL:canonical)}
   var succeeded=false
   do {let staged=try await FixtureOperations(c).stage();_ = try await FixtureOperations(c).keepAll(staged);succeeded=true;precondition(AppBundleFingerprint.compute(for:staged.fileURL)==stagedBinding.sourceTreeDigest)}catch{}
   precondition(succeeded==(variant=="exact-copy"),variant);cases.append("owned-stage-"+variant)
  }
  let json:[String:Any]=["schema":"legacy-replacement-hooks-v1","status":"PASS","cases":cases]
  print(String(data:try JSONSerialization.data(withJSONObject:json,options:.sortedKeys),encoding:.utf8)!)
 }
}
