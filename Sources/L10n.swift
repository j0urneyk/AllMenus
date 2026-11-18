import Foundation

/// Localized UI text. Keys are the English source strings; `ko.lproj/Localizable.strings` has the
/// Korean translations (generated from Tools/strings.py). English is the development language, so a
/// Mac set to any other language gets English. Text with values uses format specifiers ("%ld items", "%@").
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}
