import Foundation

@MainActor
protocol RefreshScheduler: AnyObject {
    func start()
    func stop()
    func refreshNow(productID: UUID) async
    func refreshAll() async
}

@MainActor
final class RevenueRefreshScheduler: RefreshScheduler {
    private let productIDsProvider: @MainActor () -> [UUID]
    private let refreshAction: @MainActor (UUID) async -> Void
    private let refreshInterval: TimeInterval
    private let maxConcurrentRefreshes: Int

    private var loopTask: Task<Void, Never>?

    init(
        refreshInterval: TimeInterval = 600,
        maxConcurrentRefreshes: Int = 3,
        productIDsProvider: @escaping @MainActor () -> [UUID],
        refreshAction: @escaping @MainActor (UUID) async -> Void
    ) {
        self.refreshInterval = refreshInterval
        self.maxConcurrentRefreshes = max(1, maxConcurrentRefreshes)
        self.productIDsProvider = productIDsProvider
        self.refreshAction = refreshAction
    }

    func start() {
        guard loopTask == nil else { return }

        loopTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await refreshAll()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refreshNow(productID: UUID) async {
        await refreshAction(productID)
    }

    func refreshAll() async {
        let ids = productIDsProvider()
        guard !ids.isEmpty else { return }

        let action = refreshAction
        var index = 0
        while index < ids.count {
            let end = min(index + maxConcurrentRefreshes, ids.count)
            let batch = Array(ids[index..<end])

            await withTaskGroup(of: Void.self) { group in
                for id in batch {
                    group.addTask {
                        await action(id)
                    }
                }
            }

            index = end
        }
    }
}
