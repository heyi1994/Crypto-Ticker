import Foundation

public enum L10n {
    // SwiftPM's command-line resource accessor searches beside the main bundle.
    // Packaged macOS apps keep these resources in Contents/Resources instead.
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("CryptoTicker_CryptoTickerCore.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()

    public static var language: String { resources.preferredLocalizations.first ?? "en" }
    public static var resourceBundleURL: URL { resources.bundleURL }

    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        render(key, arguments: arguments, bundle: resources)
    }

    static func text(_ key: String, language: String, _ arguments: CVarArg...) -> String {
        let localization = resources.localizations.first { $0.caseInsensitiveCompare(language) == .orderedSame } ?? language
        guard let path = resources.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return render(key, arguments: arguments, bundle: bundle)
    }

    private static func render(_ key: String, arguments: [CVarArg], bundle: Bundle) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
    }
}
