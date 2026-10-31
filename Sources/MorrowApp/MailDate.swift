import Foundation

extension Date {
    func uiFormatted(date: Date.FormatStyle.DateStyle = .abbreviated, time: Date.FormatStyle.TimeStyle = .shortened) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(Locale(identifier: L10n.languageCode)))
    }
}
