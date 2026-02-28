import SwiftUI

struct ProviderIconView: View {
    let provider: ProviderKind
    var size: CGFloat = 20

    var body: some View {
        Image(provider.iconAssetName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .clipShape(.rect(cornerRadius: 4, style: .continuous))
    }
}
