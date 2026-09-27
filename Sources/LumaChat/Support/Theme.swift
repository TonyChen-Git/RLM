import AppKit
import SwiftUI

enum LumaTheme {
    // Neutral surfaces and a monochrome control accent keep both appearances
    // close to the Codex desktop palette. Reserve colour for actual status.
    static let canvas = adaptive(light: (0.969, 0.969, 0.961), dark: (0.114, 0.118, 0.118))
    static let sidebar = adaptive(light: (0.941, 0.945, 0.937), dark: (0.090, 0.094, 0.094))
    static let surface = adaptive(light: (1.000, 1.000, 1.000), dark: (0.145, 0.149, 0.149))
    static let elevated = adaptive(light: (0.980, 0.980, 0.976), dark: (0.169, 0.173, 0.173))
    static let border = adaptive(light: (0.871, 0.878, 0.867), dark: (0.255, 0.263, 0.259))
    static let accent = adaptive(light: (0.231, 0.239, 0.231), dark: (0.914, 0.914, 0.906))

    private static let brandTop = Color(red: 0.290, green: 0.302, blue: 0.302)
    private static let brandBottom = Color(red: 0.157, green: 0.165, blue: 0.165)

    static let brandGradient = LinearGradient(
        colors: [brandTop, brandBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let ambientGradient = RadialGradient(
        colors: [Color.primary.opacity(0.012), .clear],
        center: .topTrailing,
        startRadius: 20,
        endRadius: 520
    )

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LumaTheme.border.opacity(0.7), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
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
