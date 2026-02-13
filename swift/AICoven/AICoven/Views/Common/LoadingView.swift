import SwiftUI

/// Loading view with cauldron animation and optional message
struct LoadingView: View {
    let message: String

    var body: some View {
        CauldronLoadingView(message: message, size: 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

#Preview {
    LoadingView(message: "Loading...")
}
