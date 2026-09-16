import AppKit
import SwiftUI

/// Displays the installed application's own bundle icon for a local context
/// source. If none of the supported application variants are installed, the
/// source's existing SF Symbol is used instead.
struct LocalAppIcon: View {
    let source: LocalContextSource
    let size: CGFloat
    let cornerRadius: CGFloat

    init(
        source: LocalContextSource,
        size: CGFloat = 24,
        cornerRadius: CGFloat = 5
    ) {
        self.source = source
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let applicationIcon = applicationIcon {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: cornerRadius,
                            style: .continuous
                        )
                    )
            } else {
                Image(systemName: source.systemImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .padding(size * 0.14)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var applicationIcon: NSImage? {
        let workspace = NSWorkspace.shared

        for bundleIdentifier in source.applicationIconBundleIdentifiers {
            guard let applicationURL = workspace.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) else { continue }

            return workspace.icon(forFile: applicationURL.path)
        }

        return nil
    }
}

private extension LocalContextSource {
    /// Ordered by the app variant most users expect to see. Alternate bundle
    /// identifiers let the icon follow the locally installed editor/terminal.
    var applicationIconBundleIdentifiers: [String] {
        switch self {
        case .currentSelection:
            []
        case .terminal:
            [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "dev.warp.Warp-Stable",
                "com.mitchellh.ghostty",
                "org.alacritty",
                "net.kovidgoyal.kitty",
                "com.github.wez.wezterm"
            ]
        case .notes:
            ["com.apple.Notes"]
        case .textEdit:
            ["com.apple.TextEdit"]
        case .visualStudioCode:
            [
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders"
            ]
        case .xcode:
            ["com.apple.dt.Xcode"]
        }
    }
}
