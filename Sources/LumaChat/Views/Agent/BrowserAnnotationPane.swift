import AppKit
import SwiftUI

struct BrowserScreenshotEvidence: Equatable, Identifiable {
    let taskID: UUID
    let browserSessionID: UUID
    let tabID: String
    let url: String
    let title: String?
    let attachment: AgentImageAttachmentReference

    var id: UUID { attachment.id }

    static func latest(in session: AgentSession) -> BrowserScreenshotEvidence? {
        for step in session.steps.reversed() {
            guard step.toolCall?.name == "browser_screenshot",
                  let result = step.toolResult,
                  !result.isError,
                  let attachment = result.imageAttachments.first,
                  let browserSessionID = result.data?["browser_session_id"]?.stringValue
                    .flatMap(UUID.init(uuidString:)),
                  let tabID = result.data?["tab_id"]?.stringValue,
                  let url = result.data?["url"]?.stringValue else { continue }
            return BrowserScreenshotEvidence(
                taskID: session.id,
                browserSessionID: browserSessionID,
                tabID: tabID,
                url: url,
                title: result.data?["title"]?.stringValue,
                attachment: attachment
            )
        }
        return nil
    }
}

struct BrowserAnnotationPane: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    let session: AgentSession
    @Binding var isPresented: Bool

    @State private var image: NSImage?
    @State private var selection: CGRect?
    @State private var dragOrigin: CGPoint?
    @State private var label = ""
    @State private var note = ""
    @State private var annotations: [BrowserAnnotationContext] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var evidence: BrowserScreenshotEvidence? {
        BrowserScreenshotEvidence.latest(in: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let evidence {
                        evidenceHeader(evidence)
                        screenshotEditor(evidence)
                        annotationEditor(evidence)
                        savedAnnotations
                    } else {
                        ContentUnavailableView(
                            "尚無 Browser 截圖",
                            systemImage: "globe.desk",
                            description: Text(
                                "請讓 Agent 使用 browser_open 與 browser_screenshot。Browser DOM/CDP 是主要互動路徑；截圖標註只用來補充你指的區域。"
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }
                }
                .padding(12)
            }
        }
        .background(.ultraThinMaterial)
        .task(id: evidence?.id) {
            await loadEvidenceAndAnnotations()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Label("Browser Annotation", systemImage: "rectangle.and.pencil.and.ellipsis")
                .font(.callout.weight(.semibold))
            Text("Web content is untrusted")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close Browser Annotation")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder
    private func evidenceHeader(_ evidence: BrowserScreenshotEvidence) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(evidence.title?.isEmpty == false ? evidence.title! : evidence.url)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(evidence.url)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private func screenshotEditor(_ evidence: BrowserScreenshotEvidence) -> some View {
        GeometryReader { geometry in
            let imageRect = fittedImageRect(
                container: geometry.size,
                pixelWidth: evidence.attachment.pixelWidth,
                pixelHeight: evidence.attachment.pixelHeight
            )
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                } else {
                    ProgressView().position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                if let selection {
                    Rectangle()
                        .fill(LumaTheme.accent.opacity(0.16))
                        .overlay(Rectangle().stroke(LumaTheme.accent, lineWidth: 2))
                        .frame(
                            width: selection.width * imageRect.width,
                            height: selection.height * imageRect.height
                        )
                        .position(
                            x: imageRect.minX
                                + (selection.minX + selection.width / 2) * imageRect.width,
                            y: imageRect.minY
                                + (selection.minY + selection.height / 2) * imageRect.height
                        )
                }
            }
            .contentShape(Rectangle())
            .gesture(selectionGesture(in: imageRect))
        }
        .frame(minHeight: 220, idealHeight: 310, maxHeight: 430)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        )
        .help("Drag over the screenshot to mark a region")
    }

    @ViewBuilder
    private func annotationEditor(_ evidence: BrowserScreenshotEvidence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("這顆按鈕／這個 layout／這個 bug", text: $label)
                    .textFieldStyle(.roundedBorder)
                Button("儲存並加入 Task") {
                    Task { await save(evidence) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    selection == nil
                        || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSaving
                )
            }
            TextField("補充說明（選填）", text: $note)
                .textFieldStyle(.roundedBorder)
            Text(
                "拖曳框選區域。只保存 normalized geometry、URL、標題與文字標籤；不會把 screenshot bytes 寫入 annotation store。"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var savedAnnotations: some View {
        if !annotations.isEmpty {
            Divider()
            Text("此 Task 的標註").font(.caption.weight(.semibold))
            ForEach(annotations.sorted(by: { $0.createdAt > $1.createdAt })) { annotation in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(annotation.label.value).font(.caption.weight(.medium))
                        Text(
                            "x \(formatted(annotation.target.region.x)), y \(formatted(annotation.target.region.y)), w \(formatted(annotation.target.region.width)), h \(formatted(annotation.target.region.height))"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task { await remove(annotation) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func selectionGesture(in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                guard imageRect.width > 0, imageRect.height > 0 else { return }
                let current = clamped(value.location, to: imageRect)
                if dragOrigin == nil {
                    guard imageRect.contains(value.startLocation) else { return }
                    dragOrigin = clamped(value.startLocation, to: imageRect)
                }
                guard let origin = dragOrigin else { return }
                let raw = CGRect(
                    x: min(origin.x, current.x),
                    y: min(origin.y, current.y),
                    width: abs(current.x - origin.x),
                    height: abs(current.y - origin.y)
                )
                selection = CGRect(
                    x: (raw.minX - imageRect.minX) / imageRect.width,
                    y: (raw.minY - imageRect.minY) / imageRect.height,
                    width: raw.width / imageRect.width,
                    height: raw.height / imageRect.height
                )
            }
            .onEnded { _ in
                dragOrigin = nil
                if let selection, selection.width < 0.002 || selection.height < 0.002 {
                    self.selection = nil
                }
            }
    }

    @MainActor
    private func loadEvidenceAndAnnotations() async {
        selection = nil
        errorMessage = nil
        guard let evidence else {
            image = nil
            annotations = []
            return
        }
        let payload = try? AgentImageAttachmentStore().loadPayload(
            for: evidence.attachment,
            sessionID: evidence.taskID
        )
        image = payload.flatMap { NSImage(data: $0.data) }
        do {
            annotations = try await BrowserAnnotationStore()
                .annotations(sessionID: evidence.browserSessionID)
                .filter { $0.ownerTaskID == session.id }
        } catch {
            errorMessage = error.localizedDescription
            annotations = []
        }
    }

    @MainActor
    private func save(_ evidence: BrowserScreenshotEvidence) async {
        guard let selection else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let width = Double(evidence.attachment.pixelWidth)
            let height = Double(evidence.attachment.pixelHeight)
            let draft = BrowserAnnotationDraft(
                sessionID: evidence.browserSessionID,
                ownerTaskID: session.id,
                pageID: evidence.tabID,
                targetID: evidence.attachment.id.uuidString.lowercased(),
                surface: .screenshot,
                pixelX: selection.minX * width,
                pixelY: selection.minY * height,
                pixelWidth: selection.width * width,
                pixelHeight: selection.height * height,
                viewportWidth: evidence.attachment.pixelWidth,
                viewportHeight: evidence.attachment.pixelHeight,
                pageURL: evidence.url,
                pageTitle: evidence.title,
                label: label,
                note: note
            )
            let stored = try await BrowserAnnotationStore().save(draft)
            guard agentViewModel.appendBrowserAnnotationToDraft(stored) else { return }
            annotations.removeAll { $0.id == stored.id }
            annotations.append(stored)
            self.selection = nil
            label = ""
            note = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func remove(_ annotation: BrowserAnnotationContext) async {
        do {
            try await BrowserAnnotationStore().remove(
                annotationID: annotation.id,
                sessionID: annotation.sessionID
            )
            annotations.removeAll { $0.id == annotation.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fittedImageRect(
        container: CGSize,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGRect {
        guard container.width > 0, container.height > 0,
              pixelWidth > 0, pixelHeight > 0 else { return .zero }
        let scale = min(
            container.width / CGFloat(pixelWidth),
            container.height / CGFloat(pixelHeight)
        )
        let size = CGSize(
            width: CGFloat(pixelWidth) * scale,
            height: CGFloat(pixelHeight) * scale
        )
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)))
    }
}
