import Foundation

@MainActor
protocol MetricsRepository: AnyObject {
    func loadProducts() throws -> [ProductConnection]
    func saveProduct(_ product: ProductConnection) throws
    func deleteProduct(id: UUID) throws

    func loadSnapshot(productID: UUID) throws -> RevenueSnapshot?
    func loadAllSnapshots() throws -> [RevenueSnapshot]
    @discardableResult
    func saveSnapshot(productID: UUID, snapshot: RevenueSnapshotValue) throws -> RevenueSnapshot
}
