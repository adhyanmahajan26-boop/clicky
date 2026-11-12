//
//  BotRoutines.swift
//  leanring-buddy
//
//  Routines, like Grok Bot's: a bot (or a group chat) runs an instruction on
//  a schedule. Daily, on weekdays, weekly, hourly or every N minutes; each can
//  be paused, resumed, run now or deleted, and keeps its last 20 runs. A run
//  posts the instruction into the bot's chat as a routine message and the
//  bot's reply lands there. A bot sets one up itself by answering with a
//  ```routine block ({"when": "weekdays 08:00", "do": "…"}).
//

import ClickyCore
import Foundation

/// The same routines on both Macs, whichever one fires them, so the list, edits, Pause and Delete work on either.
enum BotRoutineSync {
    /// What the owner decides about a routine. When it ran and when it's next due are the firing Mac's doing, and aren't edits.
    static func edits(of routines: [BotRoutine]) -> [BotRoutine] {
        routines.map { routine in
            var routine = routine
            routine.runs = []
            routine.nextRunAt = nil
            return routine
        }
    }

    /// The newest edit wins, and both Macs' runs are kept. A slot that passed while a routine was only on the other Mac is skipped: nothing fires just
    /// for arriving. The same job on both Macs under two ids becomes one, or it would fire twice.
    static func merged(local: [BotRoutine], localStamps: LinkMerge.Stamps, remote: [BotRoutine], remoteStamps: LinkMerge.Stamps, now: Date = Date()) -> (items: [BotRoutine], stamps: LinkMerge.Stamps) {
        let result = LinkMerge.byID(local: local, localStamps: localStamps, remote: remote, remoteStamps: remoteStamps, id: \.id)
        let mine = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var stamps = result.stamps
        let items = result.items.map { routine -> BotRoutine in
            var routine = routine
            if let a = mine[routine.id], let b = theirs[routine.id] {
                routine.runs = joinedRuns(a.runs, b.runs)
                if a.schedule == b.schedule { routine.nextRunAt = [a.nextRunAt, b.nextRunAt].compactMap { $0 }.max() }
            } else if mine[routine.id] == nil, (routine.nextRunAt ?? .distantPast) <= now {
                routine.nextRunAt = routine.schedule.next(after: now)
            }
            return routine
        }
        // Whichever is running stays, and both Macs choose the same one.
        var kept: [String: String] = [:]
        for routine in items.sorted(by: { ($0.paused ? 1 : 0, $0.id) < ($1.paused ? 1 : 0, $1.id) }) {
            let job = LinkCoding.digest([routine.target, routine.instruction]) + LinkCoding.digest(routine.schedule)
            if kept[job] == nil { kept[job] = routine.id }
        }
        let keptIDs = Set(kept.values)
        for routine in items where !keptIDs.contains(routine.id) {
            stamps.gone[routine.id] = now
            stamps.changed[routine.id] = nil
        }
        return (items.filter { keptIDs.contains($0.id) }, stamps)
    }

    /// A run on both Macs is one run, and a finished copy says more than a running one. The last 20 stay.
    private static func joinedRuns(_ first: [BotRoutine.Run], _ second: [BotRoutine.Run]) -> [BotRoutine.Run] {
        var byID: [String: BotRoutine.Run] = [:]
        for run in first + second where byID[run.id]?.finishedAt == nil { byID[run.id] = run }
        return Array(byID.values.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }.suffix(20))
    }
}

struct BotRoutine: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    /// A bot id, or "group:<id>" for a group chat.
    var target: String
    var instruction: String
    var schedule: Schedule
    var paused = false
    var createdAt = Date()
    var nextRunAt: Date?
    var runs: [Run] = []

    struct Run: Codable, Equatable, Identifiable {
        var id: String = UUID().uuidString
        var startedAt: Date
        var finishedAt: Date?
        /// "running", "done", "failed", "skipped" (the bot was off), "quiet" (a check that found nothing, so nothing was posted)
        /// or "missed" (Theo wasn't running at the time, and it was too late to catch up).
        var status: String
        /// The reply's first words.
        var summary: String?
    }

    enum Kind: String, Codable, CaseIterable { case daily, weekdays, weekly, hourly, every }

    struct Schedule: Codable, Equatable {
        var kind: Kind
        var hour = 9
        var minute = 0
        /// 1 = Sunday … 7 = Saturday (Calendar's numbering), for weekly.
        var weekday = 2
        /// For "every".
        var intervalMinutes = 60

        var label: String {
            let time = String(format: "%d:%02d", hour, minute)
            switch kind {
            case .daily: return "Every day at \(time)"
            case .weekdays: return "Weekdays at \(time)"
            case .weekly: return "Every \(Calendar.current.weekdaySymbols[(weekday - 1 + 7) % 7]) at \(time)"
            case .hourly: return "Every hour at :\(String(format: "%02d", minute))"
            case .every:
                return intervalMinutes % 60 == 0 ? "Every \(intervalMinutes / 60) h" : "Every \(intervalMinutes) min"
            }
        }

        /// How far apart its runs are, for the catch-up window.
        var periodSeconds: Double {
            switch kind {
            case .every: return Double(max(5, intervalMinutes) * 60)
            case .hourly: return 3_600
            case .daily, .weekdays: return 86_400
            case .weekly: return 604_800
            }
        }

        /// The first run time after `date`.
        func next(after date: Date, calendar: Calendar = .current) -> Date {
            switch kind {
            case .every:
                return date.addingTimeInterval(TimeInterval(max(5, intervalMinutes) * 60))
            case .hourly:
                var parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
                parts.minute = minute
                let candidate = calendar.date(from: parts) ?? date
                return candidate > date ? candidate : candidate.addingTimeInterval(3600)
            case .daily, .weekdays, .weekly:
                var day = calendar.startOfDay(for: date)
                for _ in 0..<15 {
                    if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), candidate > date {
                        let weekdayNumber = calendar.component(.weekday, from: candidate)
                        let fits = kind == .daily || (kind == .weekdays && (2...6).contains(weekdayNumber))
                            || (kind == .weekly && weekdayNumber == weekday)
                        if fits { return candidate }
                    }
                    day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                }
                return date.addingTimeInterval(86400)
            }
        }

        /// "daily 08:00", "weekdays 8:30", "weekly mon 09:00", "hourly", "hourly :15", "every 30 minutes",
        /// "every 2 hours". Nil when it can't be read.
        static func parse(_ text: String) -> Schedule? {
            let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
            func time(in string: String) -> (Int, Int)? {
                guard let match = string.range(of: #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#, options: .regularExpression) else { return nil }
                let piece = String(string[match])
                let numbers = piece.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                guard var hour = numbers.first else { return nil }
                let minute = numbers.count > 1 ? numbers[1] : 0
                if piece.contains("pm"), hour < 12 { hour += 12 }
                if piece.contains("am"), hour == 12 { hour = 0 }
                guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
                return (hour, minute)
            }
            if lower.hasPrefix("every") {
                let numbers = lower.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                let amount = numbers.first ?? 1
                if lower.contains("hour") { return Schedule(kind: .every, intervalMinutes: amount * 60) }
                if lower.contains("min") { return Schedule(kind: .every, intervalMinutes: amount) }
                if lower.contains("day"), let (hour, minute) = time(in: lower) { return Schedule(kind: .daily, hour: hour, minute: minute) }
                if lower.contains("weekday"), let (hour, minute) = time(in: lower) { return Schedule(kind: .weekdays, hour: hour, minute: minute) }
            }
            if lower.hasPrefix("hourly") {
                let minute = lower.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first ?? 0
                return Schedule(kind: .hourly, minute: min(59, minute))
            }
            let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            if lower.hasPrefix("weekly") || days.contains(where: { lower.hasPrefix($0) }) {
                let weekday = (days.firstIndex { lower.contains($0) } ?? 1) + 1
                let (hour, minute) = time(in: lower.replacingOccurrences(of: "weekly", with: "")) ?? (9, 0)
                return Schedule(kind: .weekly, hour: hour, minute: minute, weekday: weekday)
            }
            if lower.hasPrefix("weekday"), let (hour, minute) = time(in: lower) { return Schedule(kind: .weekdays, hour: hour, minute: minute) }
            if lower.hasPrefix("daily") || lower.hasPrefix("every day"), let (hour, minute) = time(in: lower) {
                return Schedule(kind: .daily, hour: hour, minute: minute)
            }
            return nil
        }
    }

    var lastRun: Run? { runs.last }
}

extension BotsStore {
    /// The ```routine block a bot writes to set one up: {"when": "weekdays 08:00", "do": "…", "name": "…"}.
    static func routineRequest(in text: String) -> (name: String, when: String, schedule: BotRoutine.Schedule, instruction: String)? {
        guard let start = text.range(of: "```routine") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "```"),
              let object = try? JSONSerialization.jsonObject(with: Data(rest[..<end.lowerBound].utf8)) as? [String: Any],
              let when = object["when"] as? String, let schedule = BotRoutine.Schedule.parse(when),
              let instruction = (object["do"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty
        else { return nil }
        let name = (object["name"] as? String) ?? String(instruction.prefix(40))
        return (name, when, schedule, instruction)
    }
}
