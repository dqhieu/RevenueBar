import Foundation

enum ProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case polar
    case lemonSqueezy
    case stripe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .polar:
            return "Polar"
        case .lemonSqueezy:
            return "Lemon Squeezy"
        case .stripe:
            return "Stripe"
        }
    }

    var symbolName: String {
        switch self {
        case .polar:
            return "snowflake"
        case .lemonSqueezy:
            return "cart"
        case .stripe:
            return "creditcard"
        }
    }

    var iconAssetName: String {
        switch self {
        case .polar:
            return "polar"
        case .lemonSqueezy:
            return "lemonsqueezy"
        case .stripe:
            return "stripe"
        }
    }
}
