import Foundation
import SwiftData

@Model
final class ProductConnection {
    @Attribute(.unique) var id: UUID
    var providerRawValue: String
    var providerEntityID: String
    var providerEntityName: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        provider: ProviderKind,
        providerEntityID: String,
        providerEntityName: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.providerRawValue = provider.rawValue
        self.providerEntityID = providerEntityID
        self.providerEntityName = providerEntityName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var provider: ProviderKind {
        get { ProviderKind(rawValue: providerRawValue) ?? .stripe }
        set { providerRawValue = newValue.rawValue }
    }
}
