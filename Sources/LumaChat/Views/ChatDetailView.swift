import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ChatDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            LumaTheme.canvas
                .overlay(LumaTheme.ambientGradient)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ChatHeader()
                Divider().opacity(0.45)

                if let conversation = viewModel.selectedConversation {
                    if conversation.messages.isEmpty {
                        WelcomeView()
                    } else {
                        MessageTimeline(conversation: conversation)
                    }
                    ComposerView()
                } else {
                    WelcomeView()
                    ComposerView()
                }
            }

            if dropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(LumaTheme.accent)
                            Text("放開以加入檔案")
                                .font(.headline)
                            Text("支援任何一般檔案；文字與圖片會直接提供給模型")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(LumaTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    }
                    .padding(24)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await viewModel.importFiles(urls) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }
}

private struct ChatHeader: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @State private var isShowingModelParameters = false

    private var endpointLabel: String {
        guard let url = URL(string: viewModel.settings.endpoint), let host = url.host else {
            return viewModel.settings.endpoint
        }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private var isSecureEndpoint: Bool {
        viewModel.settings.endpoint.lowercased().hasPrefix("https://")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selectedConversation?.title ?? "新對話")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    ConnectionDot(state: viewModel.connectionState)
                    Image(systemName: isSecureEndpoint ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(isSecureEndpoint ? Color.secondary : Color.orange)
                    Text(endpointLabel)
                        .lineLimit(1)
                    if let project = viewModel.selectedConversation?.project {
                        Text("·")
                        Image(systemName: "folder")
                        Text(project.name).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            ModeSelector(
                selection: agentViewModel.activeMode,
                isDisabled: false
            ) { mode in
                agentViewModel.switchMode(mode, route: viewModel.settings)
            }

            Menu {
                Section("目前連線的模型") {
                    if viewModel.availableModels.isEmpty {
                        Text("尚未取得模型")
                    } else {
                        ForEach(viewModel.availableModels, id: \.self) { model in
                            Button {
                                viewModel.selectModel(model)
                            } label: {
                                if model == viewModel.settings.selectedModel {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                }
                Divider()
                Section("已儲存的 Remote") {
                    ForEach(viewModel.settings.connectionProfiles) { profile in
                        Menu {
                            Button {
                                Task { await viewModel.activateProfile(id: profile.id, startNewConversation: false) }
                            } label: {
                                Label("套用到目前對話", systemImage: "arrow.triangle.branch")
                            }
                            Button {
                                Task { await viewModel.activateProfile(id: profile.id, startNewConversation: true) }
                            } label: {
                                Label("用這組開新對話", systemImage: "square.and.pencil")
                            }
                        } label: {
                            if profile.id == viewModel.settings.activeProfileID {
                                Label(profile.displayName, systemImage: "checkmark")
                            } else {
                                Text(profile.displayName)
                            }
                        }
                    }
                }
                Divider()
                Button {
                    Task { await viewModel.refreshModels() }
                } label: {
                    Label("重新整理模型", systemImage: "arrow.clockwise")
                }
                Button { viewModel.isShowingSettings = true } label: {
                    Label("連線設定", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 7) {
                    if viewModel.isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "network")
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(viewModel.activeProfile?.displayName ?? viewModel.settings.provider.title)
                            .font(.caption.weight(.semibold))
                        Text(viewModel.settings.selectedModel.isEmpty ? "選擇模型" : viewModel.settings.selectedModel)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(
                viewModel.selectedConversationIsGenerating
                    || viewModel.isReadingLiveContext
                    || viewModel.isApplyingLiveEdit
                    || viewModel.isDeletingAll
            )

            Button {
                isShowingModelParameters.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .topTrailing) {
                        let mode = viewModel.effectiveModelParameters(
                            for: ModelParameterRoute(settings: viewModel.settings, useCase: .chat)
                        ).mode
                        Circle()
                            .fill(mode == .auto ? Color.green : LumaTheme.accent)
                            .frame(width: 6, height: 6)
                    }
            }
            .buttonStyle(.plain)
            .help("目前模型參數")
            .disabled(viewModel.settings.selectedModel.isEmpty)
            .popover(isPresented: $isShowingModelParameters, arrowEdge: .bottom) {
                ModelParameterEditor(
                    viewModel: viewModel,
                    route: ModelParameterRoute(settings: viewModel.settings, useCase: .chat),
                    compact: true
                )
                .padding(8)
            }

            Button { viewModel.isShowingSettings = true } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("設定")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(LumaTheme.surface)
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    private let suggestions = [
        ("整理終端輸出", "terminal", "請分析我接下來附上的 Terminal 輸出，找出問題與修正方式。"),
        ("解釋程式碼", "chevron.left.forwardslash.chevron.right", "請逐步解釋這段程式碼，並指出可改善的地方。"),
        ("看圖回答", "photo", "請仔細觀察我附上的圖片並回答問題。")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 72)
                BrandMark(size: 58)
                VStack(spacing: 7) {
                    Text("今天想一起完成什麼？")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("連上你的遠端模型，檔案與內容只送往你指定的伺服器。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if viewModel.settings.selectedModel.isEmpty {
                    Button {
                        viewModel.isShowingSettings = true
                    } label: {
                        Label("連接 Ollama 或選擇模型", systemImage: "network")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack(spacing: 10) {
                    ForEach(suggestions, id: \.0) { item in
                        Button {
                            viewModel.draft = item.2
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: item.1)
                                    .font(.title3)
                                    .foregroundStyle(LumaTheme.accent)
                                Text(item.0)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(radius: 14, padding: 13)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 560)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
    }
}

private struct MessageTimeline: View {
    let conversation: Conversation
    @StateObject private var scrollState = ScrollFollowState()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 22) {
                    ForEach(conversation.messages) { message in
                        MessageRow(message: message, conversationID: conversation.id)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .background {
                    // Keep the observer inside the document view so its
                    // enclosing scroll view is always this message timeline.
                    ScrollPositionObserver { isNearBottom in
                        scrollState.followsLatest = isNearBottom
                    }
                }
            }
            .onAppear {
                scrollState.followsLatest = true
                Task { @MainActor in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: conversation.id) {
                scrollState.followsLatest = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversation.messages.last?.content) {
                guard scrollState.followsLatest else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversation.messages.last?.reasoning) {
                guard scrollState.followsLatest else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

@MainActor
private final class ScrollFollowState: ObservableObject {
    @Published var followsLatest = true
}

private struct MessageRow: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let message: ChatMessage
    let conversationID: UUID
    @State private var copied = false
    @State private var reasoningExpanded = false
    @State private var wantsFullDocumentApply = false

    private var isUser: Bool { message.role == .user }
    private var presentation: MessagePresentation { MessagePresentation(message: message) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isUser { Spacer(minLength: 70) }
            if !isUser {
                BrandMark(size: 28)
                    .padding(.top, 2)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 9) {
                if !message.attachments.isEmpty {
                    AttachmentGrid(attachments: message.attachments, conversationID: conversationID)
                }

                if !isUser, let reasoning = presentation.reasoning, !reasoning.isEmpty {
                    DisclosureGroup(isExpanded: $reasoningExpanded) {
                        Text(reasoning)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 7)
                    } label: {
                        Label(presentation.response.isEmpty ? "思考中…" : "思考過程", systemImage: "brain.head.profile")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }

                if presentation.response.isEmpty && !isUser {
                    ThinkingIndicator()
                        .padding(.vertical, 8)
                } else {
                    RichMessageText(
                        content: presentation.response,
                        assistantMessageID: isUser ? nil : message.id
                    )
                        .padding(isUser ? 13 : 0)
                        .background {
                            if isUser {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .fill(LumaTheme.accent.opacity(0.14))
                            }
                        }
                }

                HStack(spacing: 8) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(presentation.response, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("複製")

                    if !isUser,
                       !message.isError,
                       let source = viewModel.generatedEditSource(for: message.id) {
                        Button {
                            wantsFullDocumentApply = true
                        } label: {
                            HStack(spacing: 4) {
                                LocalAppIcon(source: source, size: 14, cornerRadius: 3)
                                Text("套用完整回覆")
                            }
                        }
                        .buttonStyle(.plain)
                        .help("直接修改已連接 App 的原文件")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(presentation.response.isEmpty ? 0 : 1)
            }
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "直接修改 \(viewModel.generatedEditTargetLabel(for: message.id) ?? "已連接文件")？",
            isPresented: $wantsFullDocumentApply
        ) {
            Button("確認直接修改") {
                Task {
                    await viewModel.applyGeneratedText(
                        presentation.response,
                        from: message.id
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會先確認文件仍是模型讀取時的相同版本；若你已切換文件或修改內容，操作會安全停止。")
        }
    }
}

private struct MessagePresentation {
    let response: String
    let reasoning: String?

    init(message: ChatMessage) {
        guard message.role == .assistant else {
            response = message.content
            reasoning = message.reasoning
            return
        }

        let tagged = Self.extractThinkBlocks(from: message.content)
        response = tagged.response
        let pieces = [message.reasoning, tagged.reasoning]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        reasoning = pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
    }

    private static func extractThinkBlocks(from content: String) -> (response: String, reasoning: String?) {
        var remaining = content
        var response = ""
        var thoughts: [String] = []

        while let opening = remaining.range(of: "<think>", options: .caseInsensitive) {
            response += String(remaining[..<opening.lowerBound])
            let afterOpening = String(remaining[opening.upperBound...])
            if let closing = afterOpening.range(of: "</think>", options: .caseInsensitive) {
                thoughts.append(String(afterOpening[..<closing.lowerBound]))
                remaining = String(afterOpening[closing.upperBound...])
            } else {
                thoughts.append(afterOpening)
                remaining = ""
                break
            }
        }
        response += remaining
        let reasoning = thoughts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (
            response.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoning.isEmpty ? nil : reasoning
        )
    }
}

/// macOS 14 does not expose SwiftUI's newer scroll-geometry callbacks. This
/// observer listens only to real clip-view movement, so content growth does not
/// incorrectly look like the user scrolled away from the latest message.
private struct ScrollPositionObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
        nsView.attachToEnclosingScrollView()
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private weak var observedClipView: NSClipView?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            Task { @MainActor [weak self] in
                self?.attachToEnclosingScrollView()
            }
        }

        override func viewWillMove(toSuperview newSuperview: NSView?) {
            if newSuperview == nil { detach() }
            super.viewWillMove(toSuperview: newSuperview)
        }

        func attachToEnclosingScrollView() {
            guard let clipView = enclosingScrollView?.contentView else { return }
            // SwiftUI updates this representable as every streamed token
            // changes the document height. Re-checking the geometry here
            // would mistake content growth for a user scroll and race with
            // the token onChange handler. Bounds notifications below are the
            // source of truth for actual viewport movement.
            guard observedClipView !== clipView else { return }
            detach()
            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            reportPosition()
        }

        private func detach() {
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            observedClipView = nil
        }

        @objc private func boundsChanged() {
            reportPosition()
        }

        private func reportPosition() {
            guard let clipView = observedClipView,
                  let documentView = clipView.documentView else { return }
            let visible = clipView.documentVisibleRect
            let distance = documentView.isFlipped
                ? documentView.bounds.maxY - visible.maxY
                : visible.minY - documentView.bounds.minY
            onChange?(distance <= 36)
        }
    }
}

private struct AttachmentGrid: View {
    let attachments: [ChatAttachment]
    let conversationID: UUID

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(attachments) { attachment in
                AttachmentChip(attachment: attachment, conversationID: conversationID)
            }
        }
    }
}

struct AttachmentChip: View {
    let attachment: ChatAttachment
    let conversationID: UUID

    private var icon: String {
        switch attachment.kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case .capturedContext: "macwindow"
        case .file: "paperclip"
        }
    }

    private var image: NSImage? {
        guard attachment.kind == .image, let relativePath = attachment.relativePath else { return nil }
        guard let url = AppPaths.safeAttachmentURL(relativePath: relativePath, conversationID: conversationID) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        HStack(spacing: 7) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: icon)
                    .foregroundStyle(LumaTheme.accent)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).lineLimit(1)
                if let label = attachment.sourceLabel {
                    Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
        .frame(maxWidth: 240)
    }
}

private struct RichMessageText: View {
    let content: String
    let assistantMessageID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MessageSegment.parse(content).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(markdown(text))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let code):
                    CodeBlock(
                        language: language,
                        code: code,
                        assistantMessageID: assistantMessageID
                    )
                }
            }
        }
        .foregroundStyle(messageColor)
    }

    private var messageColor: Color { .primary }

    private func markdown(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }
}

private enum MessageSegment {
    case text(String)
    case code(String, String)

    static func parse(_ content: String) -> [MessageSegment] {
        let pieces = content.components(separatedBy: "```")
        return pieces.enumerated().compactMap { index, piece in
            guard !piece.isEmpty else { return nil }
            if index.isMultiple(of: 2) { return .text(piece) }
            let lines = piece.split(separator: "\n", omittingEmptySubsequences: false)
            guard let first = lines.first else { return .code("", piece) }
            let possibleLanguage = String(first).trimmingCharacters(in: .whitespaces)
            let hasLanguage = !possibleLanguage.contains(" ") && possibleLanguage.count < 24
            let code = hasLanguage ? lines.dropFirst().joined(separator: "\n") : piece
            return .code(hasLanguage ? possibleLanguage : "", code)
        }
    }
}

private struct CodeBlock: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let language: String
    let code: String
    let assistantMessageID: UUID?
    @State private var copied = false
    @State private var wantsDirectApply = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "程式碼" : language)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    if let assistantMessageID,
                       let source = viewModel.generatedEditSource(for: assistantMessageID) {
                        Button {
                            wantsDirectApply = true
                        } label: {
                            HStack(spacing: 7) {
                                LocalAppIcon(source: source, size: 17, cornerRadius: 4)
                                VStack(alignment: .leading) {
                                    Text("直接修改 \(source.title)")
                                    if let target = viewModel.generatedEditTargetLabel(for: assistantMessageID) {
                                        Text(target).font(.caption)
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                    Button {
                        Task { await viewModel.saveTextToProject(code) }
                    } label: {
                        Label("儲存到專案…", systemImage: "folder.badge.plus")
                    }
                    .disabled(viewModel.selectedConversation?.project == nil)
                } label: {
                    Label("套用", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已複製" : "複製", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.035))

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .confirmationDialog(
            "直接修改 \(assistantMessageID.flatMap { viewModel.generatedEditTargetLabel(for: $0) } ?? "已連接文件")？",
            isPresented: $wantsDirectApply
        ) {
            Button("確認直接修改") {
                guard let assistantMessageID else { return }
                Task { await viewModel.applyGeneratedText(code, from: assistantMessageID) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會先核對文件與內容版本，再直接更新原 App 的目前文件；不會建立中介文字檔，且可在原 App 使用復原。")
        }
    }
}

private struct ThinkingIndicator: View {
    @State private var active = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(LumaTheme.accent.opacity(active ? 0.85 : 0.25))
                    .frame(width: 6, height: 6)
                    .scaleEffect(active ? 1 : 0.72)
                    .animation(
                        .easeInOut(duration: 0.65).repeatForever().delay(Double(index) * 0.16),
                        value: active
                    )
            }
        }
        .onAppear { active = true }
    }
}

private struct ComposerView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 8) {
            if let connection = viewModel.liveAppConnection {
                HStack(spacing: 9) {
                    LocalAppIcon(source: connection.source, size: 27, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("已連接 \(connection.applicationName)")
                                .font(.caption.weight(.semibold))
                        }
                        Text("每次送出前直接讀取目前文件，不建立文字檔")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.isReadingLiveContext || viewModel.isApplyingLiveEdit {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await viewModel.refreshLiveContext() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("立即確認目前文件")
                    }
                    Button {
                        viewModel.disconnectLiveContext()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("中斷 App 連接")
                    .disabled(viewModel.isApplyingLiveEdit)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(LumaTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(LumaTheme.accent.opacity(0.20))
                }
            }

            if !viewModel.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(viewModel.pendingAttachments, id: \.attachment.id) { prepared in
                            HStack(spacing: 5) {
                                Image(systemName: prepared.attachment.kind == .image ? "photo" : "doc")
                                Text(prepared.attachment.name).lineLimit(1)
                                Button { viewModel.removePendingAttachment(prepared.attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button {
                        Task { await viewModel.chooseFiles() }
                    } label: {
                        Label("選擇檔案或圖片…", systemImage: "paperclip")
                    }
                    Button {
                        Task { await viewModel.chooseProject() }
                    } label: {
                        Label("加入專案資料夾…", systemImage: "folder.badge.plus")
                    }
                    if viewModel.selectedConversation?.project != nil {
                        Button {
                            Task { await viewModel.refreshProject() }
                        } label: {
                            Label("重新讀取專案快照", systemImage: "arrow.clockwise")
                        }
                    }
                    Divider()
                    Section("連接 App · 送出前讀最新") {
                        ForEach(LocalContextSource.allCases.filter(\.supportsLiveDocumentAccess)) { source in
                            Button {
                                Task { await viewModel.connectLiveContext(source) }
                            } label: {
                                HStack(spacing: 8) {
                                    LocalAppIcon(source: source, size: 18, cornerRadius: 4)
                                    VStack(alignment: .leading) {
                                        Text(source.title)
                                        Text(source.subtitle).font(.caption)
                                    }
                                    if source == viewModel.liveContextSource {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    Section("一次性擷取") {
                        ForEach([
                            LocalContextSource.currentSelection,
                            .terminal
                        ]) { source in
                            Button {
                                Task { await viewModel.captureContext(source) }
                            } label: {
                                HStack(spacing: 8) {
                                    LocalAppIcon(source: source, size: 18, cornerRadius: 4)
                                    Text(source.title)
                                }
                            }
                        }
                    }
                    if viewModel.liveAppConnection != nil {
                        Divider()
                        Button("中斷 App 連接", role: .destructive) {
                            viewModel.disconnectLiveContext()
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 31, height: 31)
                        .background(.primary.opacity(0.07), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("加入檔案、專案，或即時連接 App")

                TextField("", text: $viewModel.draft, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .lineLimit(1...5)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                    .padding(.vertical, 4)
                    .accessibilityLabel("訊息輸入框")

                Button {
                    if viewModel.selectedConversationIsGenerating {
                        viewModel.stopGenerating()
                    } else {
                        Task { await viewModel.send() }
                    }
                } label: {
                    Image(systemName: viewModel.selectedConversationIsGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(
                            viewModel.canSend || viewModel.selectedConversationIsGenerating
                                ? Color(nsColor: .windowBackgroundColor)
                                : Color.secondary
                        )
                        .frame(width: 32, height: 32)
                        .background(
                            viewModel.canSend || viewModel.selectedConversationIsGenerating
                                ? AnyShapeStyle(Color.primary)
                                : AnyShapeStyle(Color.secondary.opacity(0.16)),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend && !viewModel.selectedConversationIsGenerating)
                .keyboardShortcut(.return, modifiers: .command)
                .help(viewModel.selectedConversationIsGenerating ? "停止 ⌘." : "送出 ⌘↩")
            }
            .padding(11)
            .background(LumaTheme.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(LumaTheme.border, lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.045), radius: 12, y: 5)

        }
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.bottom, 13)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 700
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: width, height: y + lineHeight), points)
    }
}
