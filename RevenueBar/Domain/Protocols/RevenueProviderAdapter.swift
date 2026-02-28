import Foundation

struct ProviderEntity: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
}

enum BillingInterval: String, Sendable {
    case day
    case week
    case month
    case year
}

struct RevenueEvent: Sendable {
    let timestamp: Date
    let amount: MonetaryAmount
}

struct RecurringRevenueItem: Sendable {
    let amount: MonetaryAmount
    let interval: BillingInterval
    let intervalCount: Int
    let quantity: Int
}

struct ProviderRevenueSnapshot: Sendable {
    let today: MonetaryAmount
    let thisMonth: MonetaryAmount
    let last30Days: MonetaryAmount
    let allTime: MonetaryAmount
}

protocol RevenueProviderAdapter: AnyObject {
    var provider: ProviderKind { get }

    func validateKey(_ key: String) async throws
    func listSelectableEntities(using key: String) async throws -> [ProviderEntity]

    func fetchRevenueSnapshot(
        entity: ProviderEntity,
        key: String,
        currency: String,
        now: Date
    ) async throws -> ProviderRevenueSnapshot

    func fetchMrr(
        entity: ProviderEntity,
        key: String,
        currency: String,
        now: Date
    ) async throws -> MonetaryAmount
}

enum ProviderAdapterError: LocalizedError {
    case unauthorized
    case invalidResponse
    case missingData(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The API key is not valid for this provider."
        case .invalidResponse:
            return "The provider returned an invalid response."
        case .missingData(let field):
            return "Missing required field: \(field)."
        case .unsupported(let message):
            return message
        }
    }
}
