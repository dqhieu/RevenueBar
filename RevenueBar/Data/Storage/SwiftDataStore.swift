import Foundation
import SwiftData

@MainActor
final class SwiftDataMetricsRepository: MetricsRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadProducts() throws -> [ProductConnection] {
        let descriptor = FetchDescriptor<ProductConnection>(
            sortBy: [SortDescriptor(\ProductConnection.providerEntityName, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    func saveProduct(_ product: ProductConnection) throws {
        product.updatedAt = .now
        modelContext.insert(product)
        try modelContext.save()
    }

    func deleteProduct(id: UUID) throws {
        let productDescriptor = FetchDescriptor<ProductConnection>(
            predicate: #Predicate { $0.id == id }
        )
        if let product = try modelContext.fetch(productDescriptor).first {
            modelContext.delete(product)
        }

        let snapshotDescriptor = FetchDescriptor<RevenueSnapshot>(
            predicate: #Predicate { $0.productID == id }
        )
        if let snapshot = try modelContext.fetch(snapshotDescriptor).first {
            modelContext.delete(snapshot)
        }

        try modelContext.save()
    }

    func loadSnapshot(productID: UUID) throws -> RevenueSnapshot? {
        let descriptor = FetchDescriptor<RevenueSnapshot>(
            predicate: #Predicate { $0.productID == productID }
        )
        return try modelContext.fetch(descriptor).first
    }

    func loadAllSnapshots() throws -> [RevenueSnapshot] {
        try modelContext.fetch(FetchDescriptor<RevenueSnapshot>())
    }

    @discardableResult
    func saveSnapshot(productID: UUID, snapshot: RevenueSnapshotValue) throws -> RevenueSnapshot {
        if let existing = try loadSnapshot(productID: productID) {
            existing.update(from: snapshot)
            try modelContext.save()
            return existing
        }

        let created = RevenueSnapshot(from: snapshot)
        modelContext.insert(created)
        try modelContext.save()
        return created
    }
}
