import SwiftUI

enum LumaTheme {
    /// A restrained green accent keeps controls close to ChatGPT's neutral
    /// palette without washing the whole interface in a brand colour.
    static let accent = Color(red: 0.10, green: 0.55, blue: 0.44)
    static let cyan = Color(red: 0.16, green: 0.49, blue: 0.46)
    static let pink = Color(red: 0.30, green: 0.58, blue: 0.48)

    static let brandGradient = LinearGradient(
        colors: [accent, Color(red: 0.08, green: 0.43, blue: 0.38)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let ambientGradient = RadialGradient(
        colors: [accent.opacity(0.055), cyan.opacity(0.025), .clear],
        center: .topTrailing,
        startRadius: 20,
        endRadius: 520
    )
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

extension View {
    func glassCard(radius: CGFloat = 18, padding: CGFloat = 12) -> some View {
        modifier(GlassCard(radius: radius, padding: padding))
    }
}

extension Date {
    var conversationTimestamp: String {
        if Calendar.current.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(self) { return "昨天" }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}

extension ConnectionState {
    var color: Color {
        switch self {
        case .idle: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}
