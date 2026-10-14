import Foundation

private var localizationResources: Bundle {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle.main
    #endif
}

func localized(_ key: String, preferences: [String]) -> String {
    let language = Bundle.preferredLocalizations(from: ["en", "pt"], forPreferences: preferences).first ?? "en"
    guard let path = localizationResources.path(forResource: language, ofType: "lproj"),
          let bundle = Bundle(path: path) else { return key }
    return bundle.localizedString(forKey: key, value: key, table: "Localizable")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let preferences = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
    let format = localized(key, preferences: preferences)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

func verifyLocalizations() -> [String: Bool] {
    func entries(_ language: String) -> [String: String] {
        guard let path = localizationResources.path(forResource: "Localizable", ofType: "strings", inDirectory: "\(language).lproj"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return dictionary
    }
    let english = entries("en"), portuguese = entries("pt")
    let placeholders = try! NSRegularExpression(pattern: "%[@d]")
    let formatsMatch = english.allSatisfy { key, value in
        let a = placeholders.matches(in: key, range: NSRange(key.startIndex..., in: key)).map { (key as NSString).substring(with: $0.range) }
        let b = placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) }
        return a == b
    }
    return [
        "matchingTranslationKeys": !english.isEmpty && Set(english.keys) == Set(portuguese.keys),
        "formatArgumentsMatch": formatsMatch,
        "englishBrazilRegion": localized("Meu quarto", preferences: ["en-BR", "pt-BR"]) == "My room",
        "englishUS": localized("Meu quarto", preferences: ["en-US", "pt-BR"]) == "My room",
        "portugueseBrazil": localized("Meu quarto", preferences: ["pt-BR", "en"]) == "Meu quarto",
        "portuguesePortugal": localized("Iluminação", preferences: ["pt-PT"]) == "Iluminação",
        "englishFallback": localized("Iluminação", preferences: ["ja"]) == "Lighting",
        "backendErrorTranslated": localized("O aparelho não confirmou o comando solicitado.", preferences: ["en"]) == "The device did not confirm the requested change.",
        "colorTranslated": localized("Vermelha", preferences: ["en"]) == "Red"
    ]
}
