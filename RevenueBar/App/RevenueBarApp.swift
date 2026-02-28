import SwiftData
import SwiftUI

@main
struct RevenueBarApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var settingsStore: AppSettingsStore
    @StateObject private var viewModel: AppViewModel

    init() {
        let schema = Schema([
            ProductConnection.self,
            RevenueSnapshot.self
        ])

        do {
            modelContainer = try ModelContainer(for: schema)
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }

        let repository = SwiftDataMetricsRepository(modelContext: modelContainer.mainContext)
        let keychainService = KeychainService()
        let memoryCache = MetricsMemoryCache()

        let client = HTTPClient()
        let adapters: [any RevenueProviderAdapter] = [
            PolarAdapter(client: client),
            LemonSqueezyAdapter(client: client),
            StripeAdapter(client: client)
        ]

        let providerFactory = ProviderAdapterFactory(adapters: adapters)
        let settingsStore = AppSettingsStore()

        _settingsStore = StateObject(wrappedValue: settingsStore)
        _viewModel = StateObject(wrappedValue: AppViewModel(
            repository: repository,
            keychainService: keychainService,
            memoryCache: memoryCache,
            providerFactory: providerFactory,
            settingsStore: settingsStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(settingsStore)
        }
        .modelContainer(modelContainer)

        Settings {
            SettingsView()
                .environmentObject(settingsStore)
        }
    }
}
