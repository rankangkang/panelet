import Foundation

@main
struct EnvironmentCheckTests {
    static func main() {
        let healthy = EnvironmentCheck.inspect(hasClass: { _ in true }, hasMethod: { _, _ in true }, hasSymbol: { _ in true })
        assert(healthy.canSplit && healthy.problem == nil)
        let absentClass = EnvironmentCheck.inspect(hasClass: { $0 != "CGVirtualDisplay" }, hasMethod: { _, _ in true }, hasSymbol: { _ in true })
        assert(!absentClass.canSplit && absentClass.missing == ["CGVirtualDisplay"])
        let absentMethod = EnvironmentCheck.inspect(hasClass: { _ in true }, hasMethod: { _, method in method != "applySettings:" }, hasSymbol: { _ in true })
        assert(!absentMethod.canSplit && absentMethod.missing == ["CGVirtualDisplay.applySettings:"])
        let absentSpace = EnvironmentCheck.inspect(hasClass: { _ in true }, hasMethod: { _, _ in true }, hasSymbol: { $0 != "SLSCopySpacesForWindows" })
        assert(!absentSpace.canSplit && absentSpace.problem != nil)
        let fallback = EnvironmentCheck.inspect(hasClass: { _ in true }, hasMethod: { _, _ in true }, hasSymbol: { !EnvironmentCheck.optionalSymbols.contains($0) })
        assert(fallback.canSplit && fallback.optionalMissing.count == EnvironmentCheck.optionalSymbols.count)
        assert(fallback.summary.contains("受限"))
        print("EnvironmentCheck: missing classes, selectors, required symbols and optional fallbacks passed")
        print("Read-only host check:\n\(EnvironmentCheck.inspect().details)")
    }
}
