import SwiftUI

struct AddProductSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @Binding var isPresented: Bool

    @State private var selectedProvider: ProviderKind = .stripe
    @State private var apiKey = ""
    @State private var entities: [ProviderEntity] = []
    @State private var selectedEntityID: String?
    @State private var isLoadingEntities = false
    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Product")
                .font(.title2.bold())

            Picker("Provider", selection: $selectedProvider) {
                ForEach(ProviderKind.allCases) { provider in
                    Label {
                        Text(provider.displayName)
                    } icon: {
                        ProviderIconView(provider: provider, size: 14)
                    }
                    .tag(provider)
                }
            }
            .pickerStyle(.segmented)

            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            if selectedProvider == .polar {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use a production Polar Organization Access Token (OAT).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Required scopes:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("organizations:read, orders:read, subscriptions:read")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await loadEntities() }
            } label: {
                if isLoadingEntities {
                    ProgressView()
                } else {
                    Text("Validate Key & Load Accounts")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingEntities || isSaving)

            if !entities.isEmpty {
                Picker("Store / Org / Account", selection: Binding(
                    get: { selectedEntityID ?? entities.first?.id ?? "" },
                    set: { selectedEntityID = $0 }
                )) {
                    ForEach(entities) { entity in
                        Text(entity.name).tag(entity.id)
                    }
                }
                .pickerStyle(.menu)
            }

            if let localError {
                Text(localError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await saveProduct() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedEntity == nil || isSaving || isLoadingEntities)
            }
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }

    private var selectedEntity: ProviderEntity? {
        guard let selectedEntityID else { return entities.first }
        return entities.first(where: { $0.id == selectedEntityID })
    }

    private func loadEntities() async {
        isLoadingEntities = true
        localError = nil
        entities = []
        selectedEntityID = nil

        do {
            let loaded = try await viewModel.validateAndLoadEntities(
                provider: selectedProvider,
                key: apiKey
            )
            entities = loaded
            selectedEntityID = loaded.first?.id
        } catch {
            localError = error.localizedDescription
        }

        isLoadingEntities = false
    }

    private func saveProduct() async {
        guard let selectedEntity else {
            localError = "Please select a store, org, or account."
            return
        }

        isSaving = true
        localError = nil

        do {
            try await viewModel.addProduct(
                provider: selectedProvider,
                key: apiKey,
                entity: selectedEntity
            )
            isPresented = false
            dismiss()
        } catch {
            localError = error.localizedDescription
        }

        isSaving = false
    }
}
