import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var isShowingAddSheet = false

    var body: some View {
        NavigationSplitView {
            ProductListView(
                selectedSidebarItem: $viewModel.selectedSidebarItem,
                onAdd: { isShowingAddSheet = true }
            )
        } detail: {
            ProductDetailView(
                product: viewModel.product(for: viewModel.selectedProductID),
                isAllProductsSelected: viewModel.isAllProductsSelected,
                hasProducts: !viewModel.products.isEmpty,
                snapshot: viewModel.snapshot(for: viewModel.selectedProductID),
                syncState: viewModel.syncState(for: viewModel.selectedProductID),
                onRefresh: {
                    Task { await viewModel.refreshSelectedNow() }
                }
            )
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AddProductSheet(isPresented: $isShowingAddSheet)
                .environmentObject(viewModel)
        }
        .task {
            await viewModel.bootstrap()
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.globalErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    Task { @MainActor in
                        viewModel.clearGlobalError()
                    }
                }
            }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.globalErrorMessage ?? "Unknown error")
        }
    }
}
