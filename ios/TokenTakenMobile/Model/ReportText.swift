import Foundation

enum ReportText {
    private static let utcTimeZone = TimeZone(secondsFromGMT: 0)!
    private static let utcGregorianCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcTimeZone
        return calendar
    }()

    static func monthLabel(_ month: String, locale: Locale) -> String {
        guard let date = parse(month, format: "yyyy-MM") else { return month }
        let display = makeDisplayFormatter(template: "MMM", locale: locale)
        return display.string(from: date)
    }

    static func dayLabel(_ day: String, locale: Locale) -> String {
        guard let date = parse(day, format: "yyyy-MM-dd") else { return day }
        let display = makeDisplayFormatter(template: "MMMd", locale: locale)
        return display.string(from: date)
    }

    static func periodLabel(start: String, end: String, locale: Locale) -> String {
        let year = String(end.prefix(4))
        return "\(dayLabel(start, locale: locale)) – \(dayLabel(end, locale: locale)), \(year)"
    }

    static func relativeTime(since date: Date, locale: Locale, now: Date = .now) -> String {
        let clamped = min(date, now)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: clamped, relativeTo: now)
    }

    static func percent(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return 0.0.formatted(.percent.precision(.fractionLength(0))) }
        let ratio = Double(part) / Double(total)
        return ratio.formatted(.percent.precision(.fractionLength(0...1)))
    }

    private static func makeDisplayFormatter(template: String, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = utcGregorianCalendar
        formatter.timeZone = utcTimeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func parse(_ text: String, format: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = utcGregorianCalendar
        parser.timeZone = utcTimeZone
        parser.dateFormat = format
        return parser.date(from: text)
    }
}
