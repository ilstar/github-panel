import SwiftUI

/// How a change GitHub hasn't confirmed is doing, for the cue next to what it changed.
struct ChangeStatus {
    /// GitHub's error once it refused the change. Nil while the change waits or sends.
    var failure: String?
    var retry: () -> Void = {}
    var discard: () -> Void = {}

    var isSaving: Bool { failure == nil }
}

extension PullRequestDetailViewModel {
    /// The newest change to `field`, nil once GitHub confirmed every change to it.
    func status(of field: PendingChange.Field) -> ChangeStatus? {
        change(to: field).map(status(of:))
    }

    func status(of change: PendingChange) -> ChangeStatus {
        ChangeStatus(failure: change.state == .failed ? change.error ?? "Couldn't save this change." : nil,
                     retry: { [weak self] in self?.retry(change) },
                     discard: { [weak self] in self?.discard(change) })
    }
}

/// A change GitHub refused, shown next to what it changed: the error, with Retry and Discard.
/// The change stays shown until one of them is picked.
struct FailedChangeNotice: View {
    let message: String
    let onRetry: () -> Void
    let onDiscard: () -> Void

    init(message: String, onRetry: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.message = message
        self.onRetry = onRetry
        self.onDiscard = onDiscard
    }

    /// Nil unless the change failed.
    init?(_ status: ChangeStatus?) {
        guard let status, let failure = status.failure else { return nil }
        message = failure
        onRetry = status.retry
        onDiscard = status.discard
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(message)
                .prFont(.caption1)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry", action: onRetry)
                .buttonStyle(QuietButtonStyle())
                .help("Send this change to GitHub again")
            Button("Discard", action: onDiscard)
                .buttonStyle(QuietButtonStyle())
                .help("Drop this change and show what GitHub has")
        }
    }
}

/// The quiet cue that a change is saving: a small spinner.
struct SavingIndicator: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .help("Saving to GitHub")
            .accessibilityLabel("Saving")
    }
}
