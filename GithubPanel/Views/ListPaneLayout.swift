import SwiftUI
import AppKit

/// Width rules for the pull request list on the left of the main window.
/// The width is kept in UserDefaults so it survives selection changes and relaunches.
enum ListPaneLayout {
    static let widthDefaultsKey = "GithubPanel.listPaneWidth"
    static let defaultWidth: CGFloat = 600
    /// Narrow enough to leave the pull request more room on small screens, wide enough for the tab picker and refresh button.
    static let minWidth: CGFloat = 440
    static let maxWidth: CGFloat = 760
    static let minDetailWidth: CGFloat = 420
    static let dividerWidth: CGFloat = 1
    /// The narrowest window that fits both panes at their minimum widths.
    static let minWindowWidth: CGFloat = minWidth + dividerWidth + minDetailWidth

    /// Keeps the list within its limits and leaves room for the detail pane.
    static func clampedWidth(_ width: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let roomForList = totalWidth - minDetailWidth - dividerWidth
        let upperBound = max(minWidth, min(maxWidth, roomForList))
        return min(max(width, minWidth), upperBound)
    }
}

/// A thin divider that resizes the list pane when dragged.
struct ListPaneDivider: View {
    @Binding var width: Double
    let totalWidth: CGFloat
    @State private var dragStartWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: ListPaneLayout.dividerWidth)
            .frame(maxHeight: .infinity)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        if isHovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? width
                                dragStartWidth = start
                                width = Double(ListPaneLayout.clampedWidth(CGFloat(start) + value.translation.width,
                                                                           totalWidth: totalWidth))
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                            }
                    )
            )
            .zIndex(1)
    }
}
