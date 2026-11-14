import Foundation

enum Localization {
    static let language: String = {
        let choice = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system"
        if choice == "en" || choice == "zh-Hans" { return choice }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    }()
    static let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let template = Localization.bundle.localizedString(forKey: key, value: key, table: "Localizable")
    return arguments.isEmpty ? template : String(format: template, locale: Locale.current, arguments: arguments)
}
