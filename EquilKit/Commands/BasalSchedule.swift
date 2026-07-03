import Foundation

public struct BasalScheduleEntry: Equatable {
    public let rate: Double
    /// Seconds from start of day (0, 3600, …, 82800).
    public let startTimeSeconds: Int
}

public struct BasalSchedule: Equatable {
    public let entries: [BasalScheduleEntry]

    public init(entries: [BasalScheduleEntry]) {
        precondition(!entries.isEmpty, "Entries can not be empty")
        precondition(entries[0].startTimeSeconds == 0, "First basal schedule entry should have 0 offset")
        self.entries = entries
    }

    /// From 24 hourly basal U/h values (AAPS mapProfileToBasalSchedule).
    public static func fromHourlyRates(_ rates: [Double]) -> BasalSchedule {
        precondition(rates.count == 24, "Expected 24 hourly basal rates")
        let entries = rates.enumerated().map { i, rate in
            BasalScheduleEntry(rate: rate, startTimeSeconds: i * 3600)
        }
        return BasalSchedule(entries: entries)
    }
}
