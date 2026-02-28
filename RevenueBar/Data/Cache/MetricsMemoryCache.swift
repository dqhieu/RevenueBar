import Foundation

actor MetricsMemoryCache {
    private var snapshots: [UUID: RevenueSnapshotValue] = [:]

    func value(for productID: UUID) -> RevenueSnapshotValue? {
        snapshots[productID]
    }

    func set(_ snapshot: RevenueSnapshotValue) {
        snapshots[snapshot.productID] = snapshot
    }

    func remove(productID: UUID) {
        snapshots.removeValue(forKey: productID)
    }

    func prime(_ values: [RevenueSnapshotValue]) {
        for value in values {
            snapshots[value.productID] = value
        }
    }
}
