import SwiftUI

struct ProductDetailView: View {
    let product: ProductConnection?
    let isAllProductsSelected: Bool
    let hasProducts: Bool
    let snapshot: RevenueSnapshotValue?
    let syncState: SyncState
    let onRefresh: () -> Void

    private let gridColumns = [
        GridItem(.flexible(minimum: 160), spacing: 12),
        GridItem(.flexible(minimum: 160), spacing: 12)
    ]

    var body: some View {
        Group {
            if hasProducts {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(
                            title: isAllProductsSelected ? "All Products" : (product?.providerEntityName ?? "Product"),
                            subtitle: isAllProductsSelected ? "Combined Revenue" : product?.provider.displayName,
                            provider: isAllProductsSelected ? nil : product?.provider
                        )

                        if let snapshot {
                            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                                MetricCardView(title: "Today", value: snapshot.today)
                                MetricCardView(title: "This Month", value: snapshot.thisMonth)
                                MetricCardView(title: "Last 30 Days", value: snapshot.last30Days)
                                MetricCardView(title: "MRR", value: snapshot.mrr)
                            }

                            allTimeLine(snapshot.allTime)
                            statusFooter(snapshot: snapshot)
                        } else {
                            ContentUnavailableView(
                                "No Metrics Yet",
                                systemImage: "hourglass",
                                description: Text("Revenue metrics will appear after the first successful sync.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 240)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "No Products",
                    systemImage: "chart.bar.doc.horizontal",
                    description: Text("Add a product to start fetching revenue metrics.")
                )
            }
        }
        .navigationTitle(isAllProductsSelected ? "All Products" : (product?.providerEntityName ?? "Revenue"))
        .frame(minWidth: 450)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!hasProducts)
            }
        }
    }

    private func allTimeLine(_ value: MonetaryAmount) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("All-time Revenue:")
                .font(.headline)
            Text(formattedCurrency(value))
                .font(.title3.bold())
        }
    }

    private func header(title: String, subtitle: String?, provider: ProviderKind?) -> some View {
        HStack {
            HStack(spacing: 10) {
                if let provider {
                    ProviderIconView(provider: provider, size: 24)
                } else {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 22))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let subtitle {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(title)
                                .font(.title2.bold())
                            Text("• \(subtitle)")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(title)
                            .font(.title2.bold())
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusFooter(snapshot: RevenueSnapshotValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last updated: \(snapshot.lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if snapshot.isStale {
                Text(snapshot.lastErrorMessage ?? "Showing stale cached metrics.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func formattedCurrency(_ value: MonetaryAmount) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = value.currencyCode
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2

        let decimal = Decimal(value.minorUnits) / 100
        let number = NSDecimalNumber(decimal: decimal)
        return formatter.string(from: number) ?? "\(value.currencyCode) \(decimal)"
    }

    private var statusText: String {
        switch syncState {
        case .idle:
            return "Up to date"
        case .refreshing:
            return "Refreshing"
        case .failed:
            return "Failed"
        case .stale:
            return "Stale"
        }
    }

    private var statusColor: Color {
        switch syncState {
        case .idle:
            return .green
        case .refreshing:
            return .blue
        case .failed:
            return .red
        case .stale:
            return .orange
        }
    }
}

private struct MetricCardView: View {
    let title: String
    let value: MonetaryAmount

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(formattedCurrency)
                .font(.title3.bold())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: shape)
    }

    private var formattedCurrency: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = value.currencyCode
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2

        let decimal = Decimal(value.minorUnits) / 100
        let number = NSDecimalNumber(decimal: decimal)
        return formatter.string(from: number) ?? "\(value.currencyCode) \(decimal)"
    }

}
