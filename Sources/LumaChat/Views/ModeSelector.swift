import SwiftUI

struct ModeSelector: View {
    let selection: AppMode
    var isDisabled = false
    let onSelect: (AppMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(selection == mode ? .semibold : .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .foregroundStyle(selection == mode ? Color.primary : Color.secondary)
                        .background {
                            if selection == mode {
                                Capsule().fill(.regularMaterial)
                                    .overlay { Capsule().strokeBorder(.primary.opacity(0.10)) }
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel("切換到 \(mode.title) 模式")
            }
        }
        .padding(3)
        .background(.primary.opacity(0.055), in: Capsule())
        .opacity(isDisabled ? 0.58 : 1)
    }
}
