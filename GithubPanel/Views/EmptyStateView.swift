import SwiftUI

/// A centered placeholder for a list with nothing to show, in the style of macOS's
/// ContentUnavailableView (which needs macOS 14).
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    var tint: Color = .secondary
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(tint)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String, tint: Color = .secondary) {
        self.init(systemImage: systemImage, title: title, message: message, tint: tint) { EmptyView() }
    }
}
