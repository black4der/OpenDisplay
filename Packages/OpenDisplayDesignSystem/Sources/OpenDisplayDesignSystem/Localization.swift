import Foundation

public extension String {
    /// This string looked up in the host app's `Localizable.strings`, or itself when there is no entry.
    /// Components take plain `String`s — literals and model values alike — so they translate here: a
    /// label with an entry shows the translation, a display name or a number renders as-is.
    var localized: String { Bundle.main.localizedString(forKey: self, value: nil, table: nil) }
}
