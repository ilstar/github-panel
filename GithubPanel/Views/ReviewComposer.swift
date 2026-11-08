import SwiftUI

/// Comment, approve, or request changes in one step, like GitHub's Review changes box.
/// Submitting clears the form: the review shows right away in the Activity list, and if GitHub refuses it, it stays
/// there with its text, the error, and Retry. With a pending review, submitting publishes its draft comments too.
struct ReviewComposer: View {
    /// Draft comments in the pending review, published with the verdict.
    var pendingCommentCount = 0
    let onCancel: () -> Void
    /// Submits the review, which shows right away.
    let onSubmit: (PullRequestReviewEvent, String) -> Void
    /// Discards the pending review and its drafts, which disappear right away. Nil when there is no pending review.
    var onDiscard: (() -> Void)?

    /// Starts on Comment, like GitHub, so an approval is always a deliberate choice.
    @State private var event: PullRequestReviewEvent = .comment
    @State private var text = ""
    @State private var isConfirmingDiscard = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(onDiscard == nil ? "Review changes" : "Finish your review")
                    .font(.headline)
                if pendingCommentCount > 0 {
                    Text(Self.pendingSummary(pendingCommentCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $text)
                .mentionAutocomplete()
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(height: 110)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.bodyIsOptional(event, pendingCommentCount: pendingCommentCount)
                             ? "Leave a comment (optional)" : "Leave a comment (Markdown supported)")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 8) {
                ForEach(PullRequestReviewEvent.allCases) { option in
                    eventOption(option)
                }
            }

            HStack(spacing: 8) {
                if onDiscard != nil {
                    Button("Discard review", role: .destructive) {
                        isConfirmingDiscard = true
                    }
                    .help("Delete the pending review and its draft comments")
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Submit review", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!Self.canSubmit(event, text: text, pendingCommentCount: pendingCommentCount))
                    .help("Submit review (⌘Return)")
            }
        }
        .padding(16)
        .frame(width: 400)
        .confirmationDialog("Discard your pending review?", isPresented: $isConfirmingDiscard) {
            Button("Discard review", role: .destructive, action: discard)
        } message: {
            Text("Its draft comments will be deleted. This cannot be undone.")
        }
        .onAppear {
            // The text view is not in the window yet during onAppear, so focus on the next turn.
            DispatchQueue.main.async { isFocused = true }
        }
    }

    /// A radio choice with GitHub's explanation under it.
    private func eventOption(_ option: PullRequestReviewEvent) -> some View {
        Button {
            event = option
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: event == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(event == option ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.callout.weight(.semibold))
                    Text(option.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(event == option ? .isSelected : [])
    }

    /// GitHub needs a message for a comment or a change request, but not for an approval
    /// or for a review whose draft comments already say something.
    static func canSubmit(_ event: PullRequestReviewEvent, text: String, pendingCommentCount: Int = 0) -> Bool {
        bodyIsOptional(event, pendingCommentCount: pendingCommentCount)
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func bodyIsOptional(_ event: PullRequestReviewEvent, pendingCommentCount: Int) -> Bool {
        !event.requiresBody || pendingCommentCount > 0
    }

    static func pendingSummary(_ count: Int) -> String {
        count == 1 ? "1 pending comment will be published." : "\(count) pending comments will be published."
    }

    private func discard() {
        onDiscard?()
    }

    private func submit() {
        guard Self.canSubmit(event, text: text, pendingCommentCount: pendingCommentCount) else { return }
        onSubmit(event, text)
        text = ""
    }
}
