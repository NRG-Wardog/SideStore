@main struct Cases {
    static func main() {
        let now = Date(timeIntervalSince1970: 1000)
        let key = Data([7, 8])
        func p(_ id: Int, _ expiry: Double, bundle: String = "app", cert: Data = Data([7, 8]), team: String = "T") -> ALTProvisioningProfile {
            ALTProvisioningProfile(uuid: UUID(uuidString: String(format:"00000000-0000-0000-0000-%012d",id))!, data: Data([UInt8(id)]), bundleIdentifier: bundle, teamIdentifier: team, expirationDate: Date(timeIntervalSince1970: expiry), certificates: [Cert(serialNumber:"S",data:cert)])
        }
        let old = p(1, 1100), fresh = p(2, 2000), extOld = p(3, 1200,bundle:"app.ext"), extNew = p(4, 2100,bundle:"app.ext")
        var passed: [String] = []
        func check(_ id: String, _ condition: @autoclosure () -> Bool) { precondition(condition(), id); passed.append(id) }
        func eval(_ expected:[ALTProvisioningProfile], _ before:[ALTProvisioningProfile]?, _ after:[ALTProvisioningProfile]?, certExpiry:Double=3000) -> V3RefreshVerification {
            V3RefreshVerification.evaluate(expected: expected,before:before,after:after,certificateSerial:"S",certificateExpiry:Date(timeIntervalSince1970:certExpiry),certificateData:key,now:now)
        }
        check("all-targets-extended", eval([fresh,extNew],[old,extOld],[fresh,extNew]).renewal == .extended)
        check("assigned-unchanged", eval([old],[old],[old]).renewal == .unchanged)
        check("shortened", eval([old],[fresh],[old]).renewal == .shortened)
        check("baseline-unavailable", eval([fresh],nil,[fresh]).renewal == .unknown)
        check("readback-unavailable", eval([fresh],[old],nil).profileStore == .unavailable)
        check("missing-extension", eval([fresh,extNew],[old,extOld],[fresh]).profileStore == .mismatch)
        check("unrelated-extra", eval([fresh],[old],[fresh,p(8,2500,bundle:"other")]).profileStore == .matched)
        var altered = fresh; altered.data=Data([99])
        check("same-uuid-different-bytes", eval([fresh],[old],[altered]).profileStore == .mismatch)
        check("duplicate-readback-uuid", eval([fresh],[old],[fresh,fresh]).profileStore == .mismatch)
        check("same-serial-wrong-der", eval([p(5,2000,cert:Data([9]))],[old],[p(5,2000,cert:Data([9]))]).profileStore == .mismatch)
        check("expired-profile", eval([p(6,900)],[p(7,800)],[p(6,900)]).profileStore == .mismatch)
        check("certificate-limits-lifetime", eval([fresh],[old],[fresh],certExpiry:1050).renewal == .unchanged)
        check("certificate-expired", eval([fresh],[old],[fresh],certExpiry:900).certificate == "invalid")
        check("greatest-baseline", eval([fresh],[old,p(9,2300)],[fresh]).renewal == .shortened)
        check("wrong-baseline-team", eval([fresh],[p(9,1100,team:"OTHER")],[fresh]).renewal == .unknown)
        check("expected-order-independent", eval([extNew,fresh],[old,extOld],[fresh,extNew]).renewal == .extended)
        check("explicit-reuse-identical-profile", eval([fresh,fresh],[old],[fresh]).profileStore == .matched)
        check("identity-reject", !V3RefreshVerification.authorizes(fresh,signedID:"other",certificateSerial:"S",certificateData:key,now:now))
        check("identity-exact", V3RefreshVerification.authorizes(fresh,signedID:"app",certificateSerial:"S",certificateData:key,now:now))
        check("identity-wildcard", V3RefreshVerification.authorizes(p(10,2000,bundle:"app.*"),signedID:"app.ext",certificateSerial:"S",certificateData:key,now:now))
        check("identity-wildcard-boundary", !V3RefreshVerification.authorizes(p(10,2000,bundle:"app.*"),signedID:"application.ext",certificateSerial:"S",certificateData:key,now:now))
        let wire = eval([fresh],[old],[fresh]).wire
        check("wire-finite-no-secrets", Set(wire.keys)==Set(["version","mutationDispatched","installAcknowledged","profileStore","renewal","certificate"]))
        let report:[String:Any] = ["schema":"refresh-truth-runtime-v1","status":"PASS","cases":passed]
        print(String(data:try! JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
