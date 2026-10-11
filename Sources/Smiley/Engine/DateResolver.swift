import Foundation

/// Resolves spoken times ("Thursday at 3pm", "in 20 minutes", "tomorrow morning") to dates.
/// Small models are unreliable at calendar math, so the model only copies the phrase and this code does the math.
enum DateResolver {
    static let defaultHour = 9

    static func resolve(_ phrase: String, now: Date = Date(), calendar cal: Calendar = .current) -> Date? {
        let s = " " + phrase.lowercased().replacingOccurrences(of: ".", with: "") + " "
        guard !phrase.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        if let d = relative(s, now: now, cal: cal) { return d }

        let partOfDay = hourForPartOfDay(s)
        let hasClock = s.matches(#"\d{1,2}(:\d{2})?\s*(am|pm)|\d{1,2}:\d{2}|\bnoon\b|\bmidnight\b|o'?clock"#)

        // Named anchors NSDataDetector doesn't handle well.
        if s.matches(#"\b(end of (the )?day|eod|tonight|this evening|this afternoon|this morning)\b"#), !s.matches(#"\btomorrow\b"#) {
            let hour = s.matches(#"end of (the )?day|eod"#) ? 17 : (partOfDay ?? 20)
            var d = at(hour: hour, minute: 0, on: now, cal)
            if d <= now { d = now.addingTimeInterval(30 * 60) }
            return d
        }
        if s.matches(#"\bend of (the )?week\b"#) { return nextWeekday(6, hour: 17, after: now, cal, allowToday: true) }
        if s.matches(#"\bnext week\b"#), !s.matches(#"monday|tuesday|wednesday|thursday|friday|saturday|sunday"#) {
            return nextWeekday(2, hour: partOfDay ?? defaultHour, after: now, cal, allowToday: false)
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)),
              var date = match.date else {
            if s.matches(#"\btomorrow\b"#) {
                return at(hour: partOfDay ?? defaultHour, minute: 0, on: cal.date(byAdding: .day, value: 1, to: now)!, cal)
            }
            return nil
        }

        if !hasClock {
            date = at(hour: partOfDay ?? defaultHour, minute: 0, on: date, cal)
        }
        // "Thursday" said on a Friday means next Thursday; a time already passed today means tomorrow.
        if date <= now {
            let mentionsWeekday = s.matches(#"monday|tuesday|wednesday|thursday|friday|saturday|sunday"#)
            date = cal.date(byAdding: .day, value: mentionsWeekday ? 7 : 1, to: date)!
        }
        return date
    }

    private static func relative(_ s: String, now: Date, cal: Calendar) -> Date? {
        let pattern = #"\bin\s+(an?|one|two|three|four|five|ten|fifteen|twenty|thirty|forty five|\d+(?:\.\d+)?)\s+(minute|min|hour|hr|day|week)s?\b"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let nr = Range(m.range(at: 1), in: s), let ur = Range(m.range(at: 2), in: s) else {
            if s.matches(#"\bin half an hour\b"#) { return now.addingTimeInterval(1800) }
            return nil
        }
        let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10,
                                       "fifteen": 15, "twenty": 20, "thirty": 30, "forty five": 45]
        let n = Double(s[nr]) ?? words[String(s[nr])] ?? 1
        let unit: Double
        switch s[ur] {
        case "minute", "min": unit = 60
        case "hour", "hr": unit = 3600
        case "day": unit = 86400
        default: unit = 7 * 86400
        }
        return now.addingTimeInterval(n * unit)
    }

    private static func hourForPartOfDay(_ s: String) -> Int? {
        if s.matches(#"\bmorning\b"#) { return 9 }
        if s.matches(#"\bafternoon\b"#) { return 14 }
        if s.matches(#"\bevening\b"#) { return 18 }
        if s.matches(#"\b(tonight|night)\b"#) { return 20 }
        return nil
    }

    private static func at(hour: Int, minute: Int, on day: Date, _ cal: Calendar) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// weekday: 1 = Sunday … 7 = Saturday
    private static func nextWeekday(_ weekday: Int, hour: Int, after now: Date, _ cal: Calendar, allowToday: Bool) -> Date {
        var d = cal.startOfDay(for: now)
        for _ in 0..<8 {
            if cal.component(.weekday, from: d) == weekday {
                let candidate = at(hour: hour, minute: 0, on: d, cal)
                if candidate > now && (allowToday || !cal.isDate(d, inSameDayAs: now)) { return candidate }
            }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return at(hour: hour, minute: 0, on: d, cal)
    }

    /// "Today 3:00 PM", "Tomorrow 9:00 AM", "Thu, Sep 24 at 3:00 PM"
    static func friendly(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " at \(time)"
    }
}
