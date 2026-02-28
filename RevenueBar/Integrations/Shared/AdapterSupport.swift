import Foundation

enum AdapterSupport {
    static let iso8601Parsers: [ISO8601DateFormatter] = {
        let parser1 = ISO8601DateFormatter()
        parser1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parser2 = ISO8601DateFormatter()
        parser2.formatOptions = [.withInternetDateTime]
        return [parser1, parser2]
    }()

    static func parseDate(_ value: Any?) -> Date? {
        if let timestamp = value as? TimeInterval {
            if timestamp > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: timestamp / 1000)
            }
            return Date(timeIntervalSince1970: timestamp)
        }

        if let intValue = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }

        if let string = value as? String {
            if let interval = TimeInterval(string) {
                return Date(timeIntervalSince1970: interval)
            }
            for parser in iso8601Parsers {
                if let date = parser.date(from: string) {
                    return date
                }
            }
        }

        return nil
    }

    static func parseString(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let value {
            return String(describing: value)
        }
        return nil
    }

    static func parseInt64(_ value: Any?) -> Int64? {
        if let int = value as? Int64 {
            return int
        }
        if let int = value as? Int {
            return Int64(int)
        }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            if let int = Int64(string) {
                return int
            }
            if let decimal = Decimal(string: string) {
                return NSDecimalNumber(decimal: decimal).int64Value
            }
        }
        return nil
    }

    static func parseDecimal(_ value: Any?) -> Decimal? {
        if let decimal = value as? Decimal {
            return decimal
        }
        if let number = value as? NSNumber {
            return number.decimalValue
        }
        if let int = value as? Int {
            return Decimal(int)
        }
        if let string = value as? String {
            return Decimal(string: string)
        }
        return nil
    }

    static func normalizedMonthlyMinorUnits(for item: RecurringRevenueItem) -> Int64 {
        let quantity = max(1, item.quantity)
        let intervalCount = max(1, item.intervalCount)
        let baseMinor = Decimal(item.amount.minorUnits * Int64(quantity))

        let monthlyFactor: Decimal
        switch item.interval {
        case .month:
            monthlyFactor = 1 / Decimal(intervalCount)
        case .year:
            monthlyFactor = 1 / (12 * Decimal(intervalCount))
        case .week:
            monthlyFactor = 52 / (12 * Decimal(intervalCount))
        case .day:
            monthlyFactor = 365 / (12 * 30.4375 * Decimal(intervalCount))
        }

        return NSDecimalNumber(decimal: baseMinor * monthlyFactor).int64Value
    }

    static func grossSnapshot(
        events: [RevenueEvent],
        currency: String,
        now: Date,
        calendar: Calendar
    ) -> ProviderRevenueSnapshot {
        let dayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart
        let last30Start = calendar.date(byAdding: .day, value: -30, to: now) ?? now

        var today: Int64 = 0
        var thisMonth: Int64 = 0
        var last30Days: Int64 = 0
        var allTime: Int64 = 0

        for event in events where event.amount.minorUnits > 0 {
            let amount = event.amount.minorUnits
            allTime += amount
            if event.timestamp >= dayStart {
                today += amount
            }
            if event.timestamp >= monthStart {
                thisMonth += amount
            }
            if event.timestamp >= last30Start {
                last30Days += amount
            }
        }

        return ProviderRevenueSnapshot(
            today: MonetaryAmount(minorUnits: today, currencyCode: currency),
            thisMonth: MonetaryAmount(minorUnits: thisMonth, currencyCode: currency),
            last30Days: MonetaryAmount(minorUnits: last30Days, currencyCode: currency),
            allTime: MonetaryAmount(minorUnits: allTime, currencyCode: currency)
        )
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { AdapterSupport.parseString(self[key]) }
    func int64(_ key: String) -> Int64? { AdapterSupport.parseInt64(self[key]) }
    func decimal(_ key: String) -> Decimal? { AdapterSupport.parseDecimal(self[key]) }
    func date(_ key: String) -> Date? { AdapterSupport.parseDate(self[key]) }

    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func array(_ key: String) -> [[String: Any]]? {
        self[key] as? [[String: Any]]
    }
}
