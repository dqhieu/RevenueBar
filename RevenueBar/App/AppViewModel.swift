import Foundation
import SwiftUI
import Combine

enum SidebarSelection: Hashable {
    case allProducts
    case product(UUID)
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var products: [ProductConnection] = []
    @Published var selectedSidebarItem: SidebarSelection = .allProducts
    @Published private(set) var snapshotsByProductID: [UUID: RevenueSnapshotValue] = [:]
    @Published private(set) var syncStateByProductID: [UUID: SyncState] = [:]
    @Published var globalErrorMessage: String?
    @Published private(set) var displayCurrency: String = "USD"

    private let repository: MetricsRepository
    private let keychainService: KeychainService
    private let memoryCache: MetricsMemoryCache
    private let providerFactory: ProviderAdapterFactory
    private let settingsStore: AppSettingsStore
    private var scheduler: RefreshScheduler?
    private var cancellables: Set<AnyCancellable> = []

    private var didBootstrap = false
    private var activeRefreshes: Set<UUID> = []
    private let aggregateSnapshotID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    var selectedProductID: UUID? {
        switch selectedSidebarItem {
        case let .product(productID):
            return productID
        case .allProducts:
            return nil
        }
    }

    var isAllProductsSelected: Bool {
        selectedSidebarItem == .allProducts
    }

    init(
        repository: MetricsRepository,
        keychainService: KeychainService,
        memoryCache: MetricsMemoryCache,
        providerFactory: ProviderAdapterFactory,
        settingsStore: AppSettingsStore
    ) {
        self.repository = repository
        self.keychainService = keychainService
        self.memoryCache = memoryCache
        self.providerFactory = providerFactory
        self.settingsStore = settingsStore

        configureScheduler(
            refreshIntervalMinutes: settingsStore.refreshIntervalMinutes,
            shouldStart: false
        )
        observeSettings()
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        do {
            products = try repository.loadProducts()
            let persistedSnapshots = try repository.loadAllSnapshots().map(\RevenueSnapshot.value)
            await memoryCache.prime(persistedSnapshots)
            snapshotsByProductID = Dictionary(uniqueKeysWithValues: persistedSnapshots.map { ($0.productID, $0) })

            scheduler?.start()
            await scheduler?.refreshAll()
        } catch {
            globalErrorMessage = userFacingErrorMessage(error)
        }
    }

    func stopScheduler() {
        scheduler?.stop()
    }

    func snapshot(for productID: UUID?) -> RevenueSnapshotValue? {
        guard let productID else {
            return aggregateSnapshot()
        }
        return snapshotsByProductID[productID]
    }

    func syncState(for productID: UUID?) -> SyncState {
        guard let productID else {
            return aggregateSyncState()
        }
        return syncStateByProductID[productID] ?? .idle
    }

    func refreshAllNow() async {
        guard let scheduler else { return }
        await scheduler.refreshAll()
    }

    func refreshSelectedNow() async {
        guard let scheduler else { return }
        switch selectedSidebarItem {
        case let .product(productID):
            await scheduler.refreshNow(productID: productID)
        case .allProducts:
            await scheduler.refreshAll()
        }
    }

    func validateAndLoadEntities(provider: ProviderKind, key: String) async throws -> [ProviderEntity] {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ProviderAdapterError.missingData("API key")
        }

        let adapter = try providerFactory.adapter(for: provider)
        try await adapter.validateKey(trimmedKey)
        let entities = try await adapter.listSelectableEntities(using: trimmedKey)
        if entities.isEmpty {
            throw ProviderAdapterError.missingData("No store/org/account found for this key")
        }
        return entities
    }

    func addProduct(provider: ProviderKind, key: String, entity: ProviderEntity) async throws {
        let product = ProductConnection(
            provider: provider,
            providerEntityID: entity.id,
            providerEntityName: entity.name
        )

        try repository.saveProduct(product)
        try keychainService.saveAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: product.id)

        products.append(product)
        products.sort { $0.providerEntityName.localizedCaseInsensitiveCompare($1.providerEntityName) == .orderedAscending }
        selectedSidebarItem = .product(product.id)

        await refreshProduct(productID: product.id)
    }

    func deleteProducts(at offsets: IndexSet) {
        let targets = offsets.map { products[$0] }

        for product in targets {
            do {
                try repository.deleteProduct(id: product.id)
                try keychainService.deleteAPIKey(for: product.id)
                Task { await memoryCache.remove(productID: product.id) }
                snapshotsByProductID.removeValue(forKey: product.id)
                syncStateByProductID.removeValue(forKey: product.id)
            } catch {
                globalErrorMessage = userFacingErrorMessage(error)
            }
        }

        products.remove(atOffsets: offsets)

        if case let .product(selectedProductID) = selectedSidebarItem,
           !products.contains(where: { $0.id == selectedProductID }) {
            self.selectedSidebarItem = .allProducts
        }
    }

    func product(for id: UUID?) -> ProductConnection? {
        guard let id else { return nil }
        return products.first { $0.id == id }
    }

    func clearGlobalError() {
        globalErrorMessage = nil
    }

    private func refreshProduct(productID: UUID) async {
        guard !activeRefreshes.contains(productID) else { return }
        guard let product = products.first(where: { $0.id == productID }) else { return }

        activeRefreshes.insert(productID)
        syncStateByProductID[productID] = .refreshing

        defer {
            activeRefreshes.remove(productID)
        }

        do {
            guard let key = try keychainService.loadAPIKey(for: productID), !key.isEmpty else {
                throw ProviderAdapterError.missingData("API key for selected product")
            }

            let adapter = try providerFactory.adapter(for: product.provider)
            let entity = ProviderEntity(id: product.providerEntityID, name: product.providerEntityName)

            let grossSnapshot = try await adapter.fetchRevenueSnapshot(
                entity: entity,
                key: key,
                currency: displayCurrency,
                now: .now
            )
            let mrr = try await adapter.fetchMrr(
                entity: entity,
                key: key,
                currency: displayCurrency,
                now: .now
            )

            let value = RevenueSnapshotValue(
                productID: productID,
                today: grossSnapshot.today,
                thisMonth: grossSnapshot.thisMonth,
                last30Days: grossSnapshot.last30Days,
                mrr: mrr,
                allTime: grossSnapshot.allTime,
                displayCurrency: displayCurrency,
                lastUpdatedAt: .now,
                isStale: false,
                lastErrorMessage: nil,
                lastSuccessfulSyncAt: .now
            )

            try repository.saveSnapshot(productID: productID, snapshot: value)
            await memoryCache.set(value)
            snapshotsByProductID[productID] = value
            syncStateByProductID[productID] = .idle
        } catch {
            let message = userFacingErrorMessage(error)
            globalErrorMessage = message
            await applyStaleFallback(for: productID, errorMessage: message)
        }
    }

    private func applyStaleFallback(for productID: UUID, errorMessage: String) async {
        let fromMemory = await memoryCache.value(for: productID)
        let existing = snapshotsByProductID[productID]
            ?? (try? repository.loadSnapshot(productID: productID)?.value)
            ?? fromMemory

        let fallback = existing ?? RevenueSnapshotValue(
            productID: productID,
            today: MonetaryAmount(minorUnits: 0, currencyCode: displayCurrency),
            thisMonth: MonetaryAmount(minorUnits: 0, currencyCode: displayCurrency),
            last30Days: MonetaryAmount(minorUnits: 0, currencyCode: displayCurrency),
            mrr: MonetaryAmount(minorUnits: 0, currencyCode: displayCurrency),
            allTime: MonetaryAmount(minorUnits: 0, currencyCode: displayCurrency),
            displayCurrency: displayCurrency,
            lastUpdatedAt: .now,
            isStale: true,
            lastErrorMessage: errorMessage,
            lastSuccessfulSyncAt: nil
        )

        let stale = RevenueSnapshotValue(
            productID: fallback.productID,
            today: fallback.today,
            thisMonth: fallback.thisMonth,
            last30Days: fallback.last30Days,
            mrr: fallback.mrr,
            allTime: fallback.allTime,
            displayCurrency: fallback.displayCurrency,
            lastUpdatedAt: fallback.lastUpdatedAt,
            isStale: true,
            lastErrorMessage: errorMessage,
            lastSuccessfulSyncAt: fallback.lastSuccessfulSyncAt
        )

        do {
            try repository.saveSnapshot(productID: productID, snapshot: stale)
        } catch {
            globalErrorMessage = userFacingErrorMessage(error)
        }

        await memoryCache.set(stale)
        snapshotsByProductID[productID] = stale
        syncStateByProductID[productID] = .stale
    }

    private func userFacingErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return "Could not resolve provider API hostname. Check internet/DNS and ensure app outbound network access is enabled."
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection. Showing cached metrics."
            default:
                return urlError.localizedDescription
            }
        }

        return error.localizedDescription
    }

    private func observeSettings() {
        settingsStore.$refreshIntervalMinutes
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] minutes in
                guard let self else { return }
                self.configureScheduler(
                    refreshIntervalMinutes: minutes,
                    shouldStart: self.didBootstrap
                )
            }
            .store(in: &cancellables)
    }

    private func configureScheduler(
        refreshIntervalMinutes: Int,
        shouldStart: Bool
    ) {
        scheduler?.stop()
        scheduler = RevenueRefreshScheduler(
            refreshInterval: TimeInterval(max(1, refreshIntervalMinutes) * 60),
            maxConcurrentRefreshes: 3,
            productIDsProvider: { [weak self] in
                self?.products.map(\.id) ?? []
            },
            refreshAction: { [weak self] productID in
                await self?.refreshProduct(productID: productID)
            }
        )

        if shouldStart {
            scheduler?.start()
        }
    }

    private func aggregateSnapshot() -> RevenueSnapshotValue? {
        guard !products.isEmpty else { return nil }

        let availableSnapshots = products.compactMap { snapshotsByProductID[$0.id] }
        guard !availableSnapshots.isEmpty else { return nil }

        let now = Date.now
        let latestUpdatedAt = availableSnapshots.map(\.lastUpdatedAt).max() ?? now
        let latestSuccessfulSyncAt = availableSnapshots.compactMap(\.lastSuccessfulSyncAt).max()
        let firstErrorMessage = availableSnapshots.compactMap(\.lastErrorMessage).first
        let hasStaleSnapshot = availableSnapshots.contains(where: \.isStale)

        return RevenueSnapshotValue(
            productID: aggregateSnapshotID,
            today: MonetaryAmount(
                minorUnits: availableSnapshots.reduce(0) { $0 + $1.today.minorUnits },
                currencyCode: displayCurrency
            ),
            thisMonth: MonetaryAmount(
                minorUnits: availableSnapshots.reduce(0) { $0 + $1.thisMonth.minorUnits },
                currencyCode: displayCurrency
            ),
            last30Days: MonetaryAmount(
                minorUnits: availableSnapshots.reduce(0) { $0 + $1.last30Days.minorUnits },
                currencyCode: displayCurrency
            ),
            mrr: MonetaryAmount(
                minorUnits: availableSnapshots.reduce(0) { $0 + $1.mrr.minorUnits },
                currencyCode: displayCurrency
            ),
            allTime: MonetaryAmount(
                minorUnits: availableSnapshots.reduce(0) { $0 + $1.allTime.minorUnits },
                currencyCode: displayCurrency
            ),
            displayCurrency: displayCurrency,
            lastUpdatedAt: latestUpdatedAt,
            isStale: hasStaleSnapshot,
            lastErrorMessage: firstErrorMessage,
            lastSuccessfulSyncAt: latestSuccessfulSyncAt
        )
    }

    private func aggregateSyncState() -> SyncState {
        guard !products.isEmpty else { return .idle }

        let allStates = products.map { syncStateByProductID[$0.id] ?? .idle }
        if allStates.contains(.refreshing) {
            return .refreshing
        }

        if let failedState = allStates.first(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            return failedState
        }

        if allStates.contains(.stale) {
            return .stale
        }

        return .idle
    }
}
