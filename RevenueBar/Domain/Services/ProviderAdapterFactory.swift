import Foundation

@MainActor
final class ProviderAdapterFactory {
    private let adapters: [ProviderKind: any RevenueProviderAdapter]

    init(adapters: [any RevenueProviderAdapter]) {
        var map: [ProviderKind: any RevenueProviderAdapter] = [:]
        for adapter in adapters {
            map[adapter.provider] = adapter
        }
        self.adapters = map
    }

    func adapter(for provider: ProviderKind) throws -> any RevenueProviderAdapter {
        guard let adapter = adapters[provider] else {
            throw ProviderAdapterError.unsupported("Provider \(provider.displayName) is not configured.")
        }
        return adapter
    }
}
