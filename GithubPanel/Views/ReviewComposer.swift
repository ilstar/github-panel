import SwiftUI

/// Comment, approve, or request changes in one step, like GitHub's Review changes box.
/// Keeps the draft and shows GitHub's error when the review is refused.
struct ReviewComposer: View {
    let onCancel: () -> Void
    /// Submits the review. Throws to keep the draft and show the error.
    let onSubmit: (PullRequestReviewEvent, String) async throws -> Void

    @State private var event: PullRequestReviewEvent = .approve
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review changes")
                .font(.headline)

            TextEditor(text: $text)
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
                        Text(event.requiresBody ? "Leave a comment (Markdown supported)" : "Leave a comment (optional)")
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
                .disabled(isSubmitting)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(PullRequestReviewEvent.allCases) { option in
                    eventOption(option)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("Submit review", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!Self.canSubmit(event, text: text) || isSubmitting)
                    .help("Submit review (⌘Return)")
            }
        }
        .padding(16)
        .frame(width: 400)
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
        .disabled(isSubmitting)
        .accessibilityAddTraits(event == option ? .isSelected : [])
    }

    /// GitHub needs a message for a comment or a change request, but not for an approval.
    static func canSubmit(_ event: PullRequestReviewEvent, text: String) -> Bool {
        !event.requiresBody || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard Self.canSubmit(event, text: text), !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await onSubmit(event, text)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}
