import Foundation

/// A rolling year of note activity. Counts unique notes, never tag occurrences.
public struct HeatmapData: Sendable {
    public struct Day: Equatable, Sendable {
        public let date: Date
        public let count: Int
    }
    public let days: [Day]
    public let calendar: Calendar

    public init(hits: [NoteIndex.SearchHit], tag: String? = nil,
                now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .year, value: -1, to: end) ?? end
        var counts: [Date: Set<Int64>] = [:]
        for hit in Self.filtered(hits, tag: tag) {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: hit.created))
            counts[day, default: []].insert(hit.id)
        }
        var days: [Day] = []
        var date = start
        while date <= end {
            days.append(Day(date: date, count: counts[date]?.count ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        self.days = days
    }

    public static func tagChoices(for configuration: ViewQuery.Heatmap, hits: [NoteIndex.SearchHit]) -> [String] {
        switch configuration.tags {
        case .none: return []
        case .discovered: return Set(hits.flatMap(\.tags)).sorted()
        case .specified(let names): return names
        }
    }

    public static func filtered(_ hits: [NoteIndex.SearchHit], tag: String? = nil,
                                day: Date? = nil, calendar: Calendar = .current) -> [NoteIndex.SearchHit] {
        hits.filter { hit in
            (tag.map { hit.tags.contains($0) } ?? true) &&
            (day.map { calendar.isDate(Date(timeIntervalSince1970: hit.created), inSameDayAs: $0) } ?? true)
        }
    }
}
