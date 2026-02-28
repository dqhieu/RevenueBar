import SwiftUI

struct ProductListView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedSidebarItem: SidebarSelection

    let onAdd: () -> Void

    private var listSelection: Binding<SidebarSelection?> {
        Binding<SidebarSelection?>(
            get: { selectedSidebarItem },
            set: { newValue in
                guard let newValue, newValue != selectedSidebarItem else { return }
                Task { @MainActor in
                    selectedSidebarItem = newValue
                }
            }
        )
    }

    var body: some View {
        List(selection: listSelection) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 18))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("All Products")
                        .font(.headline)
                    Text("Combined Revenue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(SidebarSelection.allProducts)

            ForEach(viewModel.products, id: \.id) { product in
                HStack(spacing: 10) {
                    ProviderIconView(provider: product.provider, size: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.providerEntityName)
                            .font(.headline)
                        Text(product.provider.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(SidebarSelection.product(product.id))
            }
            .onDelete(perform: viewModel.deleteProducts)
        }
        .navigationTitle("Products")
        .overlay {
            if viewModel.products.isEmpty {
                ContentUnavailableView(
                    "No Products",
                    systemImage: "chart.bar.doc.horizontal",
                    description: Text("Add a product to start fetching revenue metrics.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    onAdd()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
    }
}
