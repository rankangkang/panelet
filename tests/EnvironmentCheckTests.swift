import Foundation

@main
struct EnvironmentCheckTests {
    static func main() {
        let healthy = EnvironmentCheck.inspect(hasClass: { _ in true }, hasMethod: { _, _ in true }, hasSymbol: { _ in true })
        assert(healthy.canSplit && healthy.problem == nil)
        assert(healthy.status == .available)
        let absentClass = EnvironmentCheck.inspect(hasClass: { $0 != "CGVirtualDisplay" }, hasMethod: { _, _ in true }, hasSymbol: { _ in true })
        assert(!absentClass.canSplit && absentClass.missing == ["CGVirtualDisplay"])
        assert(absentClass.status == .unavailable)
        let absentMethod = EnvironmentCheck.inspect(hasClass: { _ in true }, hasMethod: { _, method in method != "applySettings:" }, hasSymbol: { _ in true })
        assert(!absentMethod.canSplit && absentMethod.missing == ["CGVirtualDisplay.applySettings:"])
        let absentSpace = EnvironmentCheck.inspect(hasClass: { _ in true }, hasMethod: { _, _ in true }, hasSymbol: { $0 != "SLSCopySpacesForWindows" })
        assert(!absentSpace.canSplit && absentSpace.problem != nil)
        let fallback = EnvironmentCheck.inspect(hasClass: { _ in true }, hasMethod: { _, _ in true }, hasSymbol: { !EnvironmentCheck.optionalSymbols.contains($0) })
        assert(fallback.canSplit && fallback.optionalMissing.count == EnvironmentCheck.optionalSymbols.count)
        assert(fallback.status == .limited)
        assert(fallback.summary.contains("受限"))
        assert(EnvironmentCheck.optionalSymbols.contains("SLSFindWindowAndOwner"))
        assert(EnvironmentCheck.optionalSymbols.contains("SLSGetWindowLevel"))
        let missingHitTest = EnvironmentCheck.inspect(hasClass: { _ in true }, hasMethod: { _, _ in true }, hasSymbol: { $0 != "SLSGetWindowLevel" })
        assert(missingHitTest.canSplit && missingHitTest.status == .limited && missingHitTest.optionalMissing == ["SLSGetWindowLevel"])
        let unavailableWithOptionalMissing = EnvironmentCheck.Report(missing: ["required"], optionalMissing: ["optional"])
        assert(unavailableWithOptionalMissing.status == .unavailable)
        print("EnvironmentCheck: missing classes, selectors, required symbols and optional fallbacks passed")
        print("Read-only host check:\n\(EnvironmentCheck.inspect().details)")
    }
}
