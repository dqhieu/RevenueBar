import Foundation
import SwiftData

struct MonetaryAmount: Sendable, Hashable {
    var minorUnits: Int64
    var currencyCode: String
}

struct RevenueSnapshotValue: Sendable, Hashable {
    var productID: UUID
    var today: MonetaryAmount
    var thisMonth: MonetaryAmount
    var last30Days: MonetaryAmount
    var mrr: MonetaryAmount
    var allTime: MonetaryAmount
    var displayCurrency: String
    var lastUpdatedAt: Date
    var isStale: Bool
    var lastErrorMessage: String?
    var lastSuccessfulSyncAt: Date?
}

enum SyncState: Sendable, Equatable {
    case idle
    case refreshing
    case failed(String)
    case stale
}

@Model
final class RevenueSnapshot {
    @Attribute(.unique) var productID: UUID
    var todayMinorUnits: Int64
    var thisMonthMinorUnits: Int64
    var last30DaysMinorUnits: Int64
    var mrrMinorUnits: Int64
    var allTimeMinorUnits: Int64
    var displayCurrency: String
    var lastUpdatedAt: Date
    var isStale: Bool
    var lastErrorMessage: String?
    var lastSuccessfulSyncAt: Date?

    init(
        productID: UUID,
        todayMinorUnits: Int64,
        thisMonthMinorUnits: Int64,
        last30DaysMinorUnits: Int64,
        mrrMinorUnits: Int64,
        allTimeMinorUnits: Int64,
        displayCurrency: String,
        lastUpdatedAt: Date,
        isStale: Bool,
        lastErrorMessage: String?,
        lastSuccessfulSyncAt: Date?
    ) {
        self.productID = productID
        self.todayMinorUnits = todayMinorUnits
        self.thisMonthMinorUnits = thisMonthMinorUnits
        self.last30DaysMinorUnits = last30DaysMinorUnits
        self.mrrMinorUnits = mrrMinorUnits
        self.allTimeMinorUnits = allTimeMinorUnits
        self.displayCurrency = displayCurrency
        self.lastUpdatedAt = lastUpdatedAt
        self.isStale = isStale
        self.lastErrorMessage = lastErrorMessage
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }

    convenience init(from value: RevenueSnapshotValue) {
        self.init(
            productID: value.productID,
            todayMinorUnits: value.today.minorUnits,
            thisMonthMinorUnits: value.thisMonth.minorUnits,
            last30DaysMinorUnits: value.last30Days.minorUnits,
            mrrMinorUnits: value.mrr.minorUnits,
            allTimeMinorUnits: value.allTime.minorUnits,
            displayCurrency: value.displayCurrency,
            lastUpdatedAt: value.lastUpdatedAt,
            isStale: value.isStale,
            lastErrorMessage: value.lastErrorMessage,
            lastSuccessfulSyncAt: value.lastSuccessfulSyncAt
        )
    }

    func update(from value: RevenueSnapshotValue) {
        todayMinorUnits = value.today.minorUnits
        thisMonthMinorUnits = value.thisMonth.minorUnits
        last30DaysMinorUnits = value.last30Days.minorUnits
        mrrMinorUnits = value.mrr.minorUnits
        allTimeMinorUnits = value.allTime.minorUnits
        displayCurrency = value.displayCurrency
        lastUpdatedAt = value.lastUpdatedAt
        isStale = value.isStale
        lastErrorMessage = value.lastErrorMessage
        lastSuccessfulSyncAt = value.lastSuccessfulSyncAt
    }

    var value: RevenueSnapshotValue {
        RevenueSnapshotValue(
            productID: productID,
            today: MonetaryAmount(minorUnits: todayMinorUnits, currencyCode: displayCurrency),
            thisMonth: MonetaryAmount(minorUnits: thisMonthMinorUnits, currencyCode: displayCurrency),
            last30Days: MonetaryAmount(minorUnits: last30DaysMinorUnits, currencyCode: displayCurrency),
            mrr: MonetaryAmount(minorUnits: mrrMinorUnits, currencyCode: displayCurrency),
            allTime: MonetaryAmount(minorUnits: allTimeMinorUnits, currencyCode: displayCurrency),
            displayCurrency: displayCurrency,
            lastUpdatedAt: lastUpdatedAt,
            isStale: isStale,
            lastErrorMessage: lastErrorMessage,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt
        )
    }
}
