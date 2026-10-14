import Foundation

/// `created_at` is a note's effective creation date; filesystem metadata stays intact.
public enum NoteDate {
    /// Date-only values use the local calendar. Timestamps require an ISO-8601 timezone.
    public static func parse(_ value: String) -> Date? {
        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
            return date
        }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#,
                          options: .regularExpression) != nil else { return nil }
        guard parse(String(value.prefix(10))) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public static func override(in properties: [String: [String]]) -> Double? {
        guard let values = properties["created_at"], values.count == 1 else { return nil }
        return parse(values[0])?.timeIntervalSince1970
    }
}
