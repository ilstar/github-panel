import SwiftUI

/// Every shortcut in one place, opened with ⌘/ or ? and from the Help menu.
struct KeyboardShortcutsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 18) {
                    section(ShortcutHelp.sections[0])
                    section(ShortcutHelp.sections[3])
                }
                VStack(alignment: .leading, spacing: 18) {
                    section(ShortcutHelp.sections[1])
                    section(ShortcutHelp.sections[2])
                }
            }

            Text(ShortcutHelp.footnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 820)
    }

    private func section(_ section: ShortcutHelp.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(section.entries, id: \.self) { entry in
                    GridRow {
                        Text(entry.keys)
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                            .frame(minWidth: 70, alignment: .trailing)
                        Text(entry.title)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
