import SwiftUI

/// A switch on a card: label (with optional explanation) left, switch right.
///
/// **Why this exists.** Two bare `Toggle`s with `.font(.caption)` labels, stacked
/// in a `VStack(spacing: Spacing.xs)`, rendered *on top of each other* on the
/// DJ-modi screen: SwiftUI sized each row to its label, and a switch is 31 pt
/// tall, so it spilled into the row below. The first attempt at a fix was padding
/// on one call site, which only moved the collision. A minimum row height that
/// actually fits the control solves it wherever it is used.
///
/// It also settles a smaller thing: a setting is not a caption. Both call sites
/// had shrunk their labels to `.caption` to make the row look less heavy, which
/// made the one interactive line on the card the hardest one to read.
@MainActor
public struct SettingToggle: View {
    private let title: String
    private let explanation: String?
    @Binding private var isOn: Bool

    public init(_ title: String, explanation: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.explanation = explanation
        self._isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                if let explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        // The switch, not the label, sets the floor for this row.
        .frame(minHeight: 34)
    }
}
