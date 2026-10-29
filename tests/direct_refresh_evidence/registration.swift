import Foundation
struct AppOperation { let bundleIdentifier="fixture.app" }
final class V3HeadlessPipelineHandler {}
final class StandaloneOperationContext {}
struct V3RefreshVerification { var mutationDispatched=true; var installAcknowledged=true }
final class RefreshGroup: @unchecked Sendable {
 let context:StandaloneOperationContext; let progress=Progress(totalUnitCount:1)
 init(context:StandaloneOperationContext){self.context=context}
 func setVerification(_ value:V3RefreshVerification,for id:String){}
 func cancel(){}
}
final class V3ServiceCallbackGate: @unchecked Sendable {
 let continuation:CheckedContinuation<Void,Error>
 init(_ c:CheckedContinuation<Void,Error>){continuation=c}
 func settle(_ r:Result<Void,Error>){continuation.resume(with:r)}
}
@MainActor final class V3SideStoreService {
 static let shared=V3SideStoreService();var cancellations:[String:()->Void]=[:]
}
@MainActor final class Runner {
 var probe:((RefreshGroup)->Void)?;var fail=false;var calls=0
 func performSingleOperation(_ operation:AppOperation,handler:V3HeadlessPipelineHandler,context:StandaloneOperationContext,suppliedGroup:RefreshGroup?,completionHandler:(Result<Int,Error>)->Void)->RefreshGroup {
  calls += 1;let group=suppliedGroup!;probe?(group)
  completionHandler(fail ? .failure(NSError(domain:"fixture",code:1)) : .success(1))
  return group
 }
}
@MainActor final class AppManager {static let shared=AppManager();let pipelineRunner=Runner()}
@MainActor final class Fixture {
 struct Terminal {var isEmpty=true;var isCancellationRequested=false}
 struct Session {var group:RefreshGroup?;var terminal=Terminal()}
 var sessions:[String:Session]=["fixture":Session()]
 // ACTUAL_SINGLE
 func run() async throws {try await single(id:"fixture",operation:AppOperation(),handler:V3HeadlessPipelineHandler(),context:StandaloneOperationContext())}
}
@main struct Main {
 @MainActor static func main() async throws {
  let runner=AppManager.shared.pipelineRunner
  for fail in [false,true] {
   let fixture=Fixture();runner.fail=fail
   runner.probe={ group in precondition(fixture.sessions["fixture"]?.group === group);precondition(V3SideStoreService.shared.cancellations["fixture"] != nil) }
   do {try await fixture.run();precondition(!fail)} catch {precondition(fail)}
  }
  let fixture=Fixture();let before=runner.calls
  let task=Task {try await fixture.run()};task.cancel()
  do {try await task.value;preconditionFailure("cancelled operation started")} catch is CancellationError {} catch {preconditionFailure("wrong cancellation")}
  precondition(runner.calls==before)
  print("DIRECT_REGISTRATION_PASS cases=3")
 }
}
