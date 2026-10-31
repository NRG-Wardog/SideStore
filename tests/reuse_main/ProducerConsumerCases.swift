@main @MainActor struct ProducerConsumerCases {
 static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let original="fixture."+UUID().uuidString.replacingOccurrences(of:"-",with:"")
  let resigned=original+".TEAM", source=root.appendingPathComponent("source/App.app"), staged=root.appendingPathComponent("stage/App.app")
  func write(_ url:URL,_ id:String,_ generation:String?=nil) throws {
   try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
   var p:[String:Any]=["CFBundleIdentifier":id]
   if let generation { p[V3ValidatedReuseMainRegistry.generationKey]=generation }
   try PropertyListSerialization.data(fromPropertyList:p,format:.binary,options:0).write(to:url.appendingPathComponent("Info.plist"))
  }
  try write(source,original);try write(staged,resigned,UUID().uuidString)
  let originalBytes=try Data(contentsOf:source.appendingPathComponent("Info.plist"))
  let app=InstalledApp(original,resigned,source),context=FixtureContext(app)
  let producer=ProducerHarness(context),consumer=ConsumerHarness(context)
  let der=Data([1,2,3]), certificate=ALTCertificate(x509:FixtureCertificate(data:Data([1,2,3])))
  let mainID="PREFIX."+resigned
  let profile=FixtureProfile(uuid:UUID(),data:Data([7]),teamIdentifier:"TEAM",certificates:[FixtureCertificate(data:der)],entitlements:[.applicationIdentifier:mainID])
  let signed=ALTApplication(staged);signed.provisioningProfile=profile;signed.entitlements=[.applicationIdentifier:mainID]
  let extURL=staged.appendingPathComponent("PlugIns/Widget.appex");try write(extURL,resigned+".widget")
  let ext=ALTApplication(extURL);ext.provisioningProfile=profile
  ext.entitlements=[.applicationIdentifier:mainID,ALTEntitlement(rawValue:"com.apple.developer.team-identifier"):"TEAM"]
  signed.appExtensions=[ext];app.appExtensions=[FixtureExtension(bundleIdentifier:original+".widget",resignedBundleIdentifier:resigned+".widget")]
  var cases:[String]=[]
  await consumer.consume(app)
  precondition(context.acknowledgedReuseMainIdentity==nil);cases.append("staged-without-ack-not-enrolled")
  // Failed native ACK boundary does not execute the actual post-ACK recording block.
  enum Failure:Error { case noACK }
  func dispatch(_ acknowledged:Bool) async throws {
   guard acknowledged else { throw Failure.noACK }
   context.validatedReuseMain=true
   await producer.acknowledged(app,signed,certificate)
  }
  do { try await dispatch(false);fatalError("unexpected ACK") } catch Failure.noACK {}
  await consumer.consume(app);precondition(context.acknowledgedReuseMainIdentity==nil);cases.append("failed-ack-not-enrolled")
  try await dispatch(true);await consumer.consume(app)
  guard let record=context.acknowledgedReuseMainIdentity else { fatalError("actual consumer did not recover actual producer") }
  precondition(record.certificateDER==der && record.reusedExtensionIdentifiers==[resigned+".widget"])
  precondition(!context.validatedReuseMain);cases.append("actual-producer-ack-consumer-recovers-history-only")
  let sourceAfter = try Data(contentsOf:source.appendingPathComponent("Info.plist"))
  precondition(sourceAfter==originalBytes)
  precondition(ALTApplication(source).infoPlist[V3ValidatedReuseMainRegistry.generationKey]==nil);cases.append("original-cache-unchanged-without-generation")
  try write(staged,resigned)
  try await dispatch(true);context.acknowledgedReuseMainIdentity=nil;await consumer.consume(app)
  precondition(context.acknowledgedReuseMainIdentity==nil);cases.append("missing-signed-marker-not-enrolled")
  try write(staged,resigned,UUID().uuidString)
  context.validatedReuseMain=true
  await producer.acknowledged(app,signed,ALTCertificate(x509:FixtureCertificate(data:Data([9]))))
  context.acknowledgedReuseMainIdentity=nil;await consumer.consume(app)
  precondition(context.acknowledgedReuseMainIdentity==nil);cases.append("certificate-profile-mismatch-not-enrolled")
  try await dispatch(true)
  try Data([1]).write(to:source.appendingPathComponent("changed.bin"))
  context.acknowledgedReuseMainIdentity=nil;await consumer.consume(app)
  precondition(context.acknowledgedReuseMainIdentity==nil);cases.append("actual-fingerprint-source-drift-rejected")
  print(String(data:try JSONSerialization.data(withJSONObject:["schema":"reuse-main-producer-consumer-v1","status":"PASS","cases":cases,"device_executed":false],options:[.sortedKeys]),encoding:.utf8)!)
 }
}
