func evidence(_ dispatched:Bool=true,_ ack:Bool=true,_ store:String="matched",_ renewal:String="extended",_ cert:String="valid")->[String:Any]{
 ["version":1,"mutationDispatched":dispatched,"installAcknowledged":ack,"profileStore":store,"renewal":renewal,"certificate":cert]
}
func apply(_ e:[[String:Any]],_ state:String="completed",_ kind:String="refreshApp",_ started:Bool=true)->[String:Any]{
 V3DirectInstallEvidencePolicy.applying(["state":state,"stopConfirmed":true],kind:kind,observations:e,operationStarted:started)
}
let renewed=apply([evidence()]);precondition(renewed["renewalVerified"] as? Bool == true && renewed["outcomeUnknown"] == nil)
let unchanged=apply([evidence(true,true,"matched","unchanged")]);precondition(unchanged["renewalVerified"] as? Bool == false && unchanged["retryable"] as? Bool == false)
let unavailable=apply([evidence(true,true,"unavailable","unknown","unknown")]);precondition(unavailable["renewalVerified"] as? Bool == false)
for state in ["failed","cancelled"] {
 let lost=apply([evidence(true,false,"unavailable","unknown","unknown")],state)
 precondition(lost["outcomeUnknown"] as? Bool == true && lost["retryable"] as? Bool == false && lost["stopConfirmed"] == nil)
}
let saveFailed=apply([evidence()],"failed");precondition(saveFailed["outcomeUnknown"] as? Bool == true)
let early=apply([evidence(false,false,"unavailable","unknown","unknown")],"failed");precondition(early["outcomeUnknown"] == nil && early["mutationDispatched"] as? Bool == false)
precondition(apply([],"failed")["outcomeUnknown"] as? Bool == true)
precondition(apply([evidence(),evidence()])["outcomeUnknown"] as? Bool == true)
var malformed=evidence();malformed["version"]=true;precondition(apply([malformed])["outcomeUnknown"] as? Bool == true)
var secret=evidence();secret["rawProfile"]="SECRET";let scrubbed=apply([secret]);precondition(scrubbed["verification"] == nil && scrubbed["outcomeUnknown"] as? Bool == true)
var contradiction=evidence();contradiction["reason"]="certificateUnknown";precondition(apply([contradiction])["outcomeUnknown"] as? Bool == true)
precondition(apply([],"failed","delete")["outcomeUnknown"] == nil)
precondition(apply([],"failed","install",false)["outcomeUnknown"] == nil)
print("DIRECT_REFRESH_EVIDENCE_PASS cases=14")
