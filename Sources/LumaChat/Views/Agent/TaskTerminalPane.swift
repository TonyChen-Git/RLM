import Combine
import SwiftUI

@MainActor
final class TaskTerminalPaneModel: ObservableObject {
    @Published private(set) var descriptors: [TaskTerminalDescriptor] = []
    @Published var selectedTerminalID: UUID?
    @Published private(set) var renderRevision: UInt64 = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private static let replayBudget = 4 * 1_024 * 1_024
    private static let replayChunk = 64 * 1_024

    private var service: TaskTerminalService?
    private var attachmentID = UUID()
    private var eventTask: Task<Void, Never>?
    private var inputTail: Task<Void, Never>?
    private var inputTailID: UUID?
    private var emulators: [UUID: TaskTerminalEmulator] = [:]
    private var nextOffsets: [UUID: Int64] = [:]
    private var clearGenerations: [UUID: UInt64] = [:]
    private var lastRequestedDimensions: [UUID: (rows: Int, columns: Int)] = [:]

    var selectedDescriptor: TaskTerminalDescriptor? {
        guard let selectedTerminalID else { return nil }
        return descriptors.first { $0.id == selectedTerminalID }
    }

    var selectedSnapshot: TaskTerminalSnapshot {
        guard let selectedTerminalID,
              let emulator = emulators[selectedTerminalID] else {
            return Self.emptySnapshot
        }
        return emulator.snapshot()
    }

    var selectedApplicationCursorKeys: Bool {
        selectedSnapshot.modes.applicationCursorKeys
    }

    var selectedBracketedPaste: Bool {
        selectedSnapshot.modes.bracketedPaste
    }

    func attach(to newService: TaskTerminalService) async {
        detach(clearDisplay: true)
        let attachment = UUID()
        attachmentID = attachment
        service = newService
        isLoading = true

        do {
            // Subscribe before listing/replay. The bounded stream bridges the
            // small window between the snapshot and live output; byte offsets
            // below detect and repair any overflowed event gap.
            let stream = try await newService.events()
            let listed = try await newService.list()
            guard attachmentID == attachment, !Task.isCancelled else { return }

            descriptors = listed
            selectedTerminalID = selectedTerminalID.flatMap { selected in
                listed.contains(where: { $0.id == selected }) ? selected : nil
            } ?? listed.first?.id
            for descriptor in listed {
                install(descriptor, resetForReplay: true)
                await replay(
                    terminalID: descriptor.id,
                    descriptor: descriptor,
                    attachment: attachment
                )
            }
            guard attachmentID == attachment, !Task.isCancelled else { return }
            isLoading = false

            eventTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled, let self else { return }
                    await self.consume(event, attachment: attachment)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard attachmentID == attachment else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    /// Detaching is intentionally UI-only. The Task-owned service and PTYs are
    /// never disposed when a pane, Task, chat, or Settings view disappears.
    func detach(clearDisplay: Bool = false) {
        attachmentID = UUID()
        eventTask?.cancel()
        eventTask = nil
        inputTail?.cancel()
        inputTail = nil
        inputTailID = nil
        service = nil
        isLoading = false
        if clearDisplay {
            descriptors.removeAll()
            selectedTerminalID = nil
            emulators.removeAll()
            nextOffsets.removeAll()
            clearGenerations.removeAll()
            lastRequestedDimensions.removeAll()
            renderRevision &+= 1
        }
    }

    func select(_ id: UUID) {
        guard descriptors.contains(where: { $0.id == id }) else { return }
        selectedTerminalID = id
        renderRevision &+= 1
    }

    func create() {
        guard let service else { return }
        let attachment = attachmentID
        Task { [weak self] in
            do {
                let descriptor = try await service.create()
                guard let self, self.isCurrent(service, attachment: attachment) else { return }
                self.install(descriptor, resetForReplay: false)
                self.selectedTerminalID = descriptor.id
                await self.replay(
                    terminalID: descriptor.id,
                    descriptor: descriptor,
                    attachment: self.attachmentID
                )
            } catch {
                self?.present(error, from: service, attachment: attachment)
            }
        }
    }

    func renameSelected(to title: String) {
        guard let service, let id = selectedTerminalID else { return }
        let attachment = attachmentID
        Task { [weak self] in
            do {
                let metadata = try await service.rename(id: id, title: title)
                guard let self, self.isCurrent(service, attachment: attachment) else { return }
                if let index = self.descriptors.firstIndex(where: { $0.id == id }) {
                    self.descriptors[index].metadata = metadata
                    self.renderRevision &+= 1
                }
            } catch {
                self?.present(error, from: service, attachment: attachment)
            }
        }
    }

    func reconnectSelected() {
        guard let service, let id = selectedTerminalID else { return }
        let attachment = attachmentID
        Task { [weak self] in
            do {
                let descriptor = try await service.reconnect(id: id)
                guard let self, self.isCurrent(service, attachment: attachment) else { return }
                self.install(descriptor, resetForReplay: false)
                await self.replay(
                    terminalID: descriptor.id,
                    descriptor: descriptor,
                    attachment: self.attachmentID
                )
            } catch {
                self?.present(error, from: service, attachment: attachment)
            }
        }
    }

    func killSelected() {
        guard let service, let id = selectedTerminalID else { return }
        let attachment = attachmentID
        Task { [weak self] in
            do {
                let descriptor = try await service.kill(id: id)
                guard let self, self.isCurrent(service, attachment: attachment) else { return }
                self.install(descriptor, resetForReplay: false)
            } catch {
                self?.present(error, from: service, attachment: attachment)
            }
        }
    }

    func closeSelected() {
        guard let service, let id = selectedTerminalID else { return }
        let attachment = attachmentID
        Task { [weak self] in
            do {
                try await service.close(id: id)
                guard let self, self.isCurrent(service, attachment: attachment) else { return }
                self.remove(id)
            } catch {
                self?.present(error, from: service, attachment: attachment)
            }
        }
    }

    func clearSelected() {
        guard let service, let id = selectedTerminalID else { return }
        let attachment = attachmentID
        Task { [weak self] in
            do {
                let descriptor = try await service.clear(id: id)
                guard let self, self.isCurrent(service, attachment: attachment) else { return }
                self.install(descriptor, resetForReplay: false)
            } catch {
                self?.present(error, from: service, attachment: attachment)
            }
        }
    }

    func signalSelected(_ signal: TaskTerminalSignal) {
        guard let service, let id = selectedTerminalID else { return }
        let attachment = attachmentID
        Task { [weak self] in
            do {
                let descriptor = try await service.signal(id: id, signal: signal)
                guard let self, self.isCurrent(service, attachment: attachment) else { return }
                self.install(descriptor, resetForReplay: false)
            } catch {
                self?.present(error, from: service, attachment: attachment)
            }
        }
    }

    func sendEOF() {
        write(Data([0x04]))
    }

    func write(_ data: Data) {
        guard !data.isEmpty, let service, let id = selectedTerminalID else { return }
        let attachment = attachmentID
        let predecessor = inputTail
        let operationID = UUID()
        let operation = Task { [weak self] in
            if let predecessor { await predecessor.value }
            guard !Task.isCancelled,
                  let self,
                  self.isCurrent(service, attachment: attachment) else { return }
            defer { self.finishInputOperation(operationID) }
            do {
                var offset = 0
                while offset < data.count, !Task.isCancelled {
                    let count = min(
                        PseudoTerminalSession.maximumInputBytes,
                        data.count - offset
                    )
                    let upperBound = data.index(data.startIndex, offsetBy: offset + count)
                    let lowerBound = data.index(data.startIndex, offsetBy: offset)
                    _ = try await service.write(
                        id: id,
                        data: Data(data[lowerBound..<upperBound])
                    )
                    offset += count
                }
            } catch {
                self.present(error, from: service, attachment: attachment)
            }
        }
        inputTail = operation
        inputTailID = operationID
    }

    func resizeSelected(rows: Int, columns: Int) {
        guard let service, let id = selectedTerminalID,
              selectedDescriptor?.metadata.state == .running else { return }
        if let previous = lastRequestedDimensions[id],
           previous.rows == rows, previous.columns == columns { return }
        lastRequestedDimensions[id] = (rows, columns)
        let attachment = attachmentID
        if var emulator = emulators[id] {
            try? emulator.resize(rows: rows, columns: columns)
            emulators[id] = emulator
            renderRevision &+= 1
        }
        Task { [weak self] in
            do {
                _ = try await service.resize(id: id, rows: rows, columns: columns)
            } catch {
                guard let self, self.isCurrent(service, attachment: attachment) else { return }
                if self.lastRequestedDimensions[id]?.rows == rows,
                   self.lastRequestedDimensions[id]?.columns == columns {
                    self.lastRequestedDimensions.removeValue(forKey: id)
                }
                self.present(error)
            }
        }
    }

    private func consume(_ event: TaskTerminalEvent, attachment: UUID) async {
        guard attachmentID == attachment else { return }
        switch event.kind {
        case .snapshot:
            if let descriptor = event.descriptor {
                install(descriptor, resetForReplay: false)
            }
        case .output:
            guard let output = event.output else { return }
            let expected = nextOffsets[event.terminalID] ?? output.earliestAvailableOffset
            if output.truncatedBeforeOffset || output.offset > expected {
                guard let descriptor = descriptors.first(where: { $0.id == event.terminalID }) else {
                    return
                }
                await replay(
                    terminalID: event.terminalID,
                    descriptor: descriptor,
                    attachment: attachment
                )
            } else {
                append(output)
            }
        case .removed:
            remove(event.terminalID)
        }
    }

    private func install(
        _ descriptor: TaskTerminalDescriptor,
        resetForReplay: Bool
    ) {
        let id = descriptor.id
        let oldGeneration = clearGenerations[id]
        let generationChanged = oldGeneration != nil
            && oldGeneration != descriptor.metadata.clearGeneration
        let shouldReset = resetForReplay || generationChanged || emulators[id] == nil

        if shouldReset {
            var emulator = emulators[id] ?? Self.makeEmulator(
                rows: Int(descriptor.metadata.rows),
                columns: Int(descriptor.metadata.columns)
            )
            emulator.reset()
            try? emulator.resize(
                rows: Int(descriptor.metadata.rows),
                columns: Int(descriptor.metadata.columns)
            )
            emulators[id] = emulator
            nextOffsets[id] = descriptor.earliestAvailableOffset
        } else {
            if var emulator = emulators[id] {
                try? emulator.resize(
                    rows: Int(descriptor.metadata.rows),
                    columns: Int(descriptor.metadata.columns)
                )
                emulators[id] = emulator
            }
        }
        clearGenerations[id] = descriptor.metadata.clearGeneration

        if let index = descriptors.firstIndex(where: { $0.id == id }) {
            descriptors[index] = descriptor
        } else {
            descriptors.append(descriptor)
        }
        if selectedTerminalID == nil { selectedTerminalID = id }
        renderRevision &+= 1
    }

    private func replay(
        terminalID id: UUID,
        descriptor: TaskTerminalDescriptor,
        attachment: UUID
    ) async {
        guard let service, attachmentID == attachment else { return }
        let earliest = descriptor.earliestAvailableOffset
        let latest = max(earliest, descriptor.nextOffset)
        var start = nextOffsets[id] ?? earliest
        start = max(earliest, min(start, latest))
        if latest - start > Int64(Self.replayBudget) {
            start = latest - Int64(Self.replayBudget)
            if var emulator = emulators[id] {
                emulator.reset()
                try? emulator.resize(
                    rows: Int(descriptor.metadata.rows),
                    columns: Int(descriptor.metadata.columns)
                )
                emulators[id] = emulator
            }
            nextOffsets[id] = start
            renderRevision &+= 1
        }

        var consumed = 0
        while consumed < Self.replayBudget, attachmentID == attachment, !Task.isCancelled {
            do {
                let output = try await service.read(
                    id: id,
                    offset: nextOffsets[id] ?? start,
                    maxBytes: min(Self.replayChunk, Self.replayBudget - consumed)
                )
                guard attachmentID == attachment else { return }
                if output.truncatedBeforeOffset {
                    if var emulator = emulators[id] {
                        emulator.reset()
                        try? emulator.resize(
                            rows: Int(descriptor.metadata.rows),
                            columns: Int(descriptor.metadata.columns)
                        )
                        emulators[id] = emulator
                    }
                    nextOffsets[id] = output.earliestAvailableOffset
                }
                append(output)
                consumed += output.data.count
                if !output.hasMore || output.data.isEmpty { return }
            } catch {
                if !Task.isCancelled { present(error) }
                return
            }
        }
    }

    private func append(_ output: TaskTerminalOutput) {
        let id = output.terminalID
        guard var emulator = emulators[id] else { return }
        let knownGeneration = clearGenerations[id]
        if knownGeneration != nil, knownGeneration != output.clearGeneration {
            emulator.reset()
            nextOffsets[id] = output.earliestAvailableOffset
            clearGenerations[id] = output.clearGeneration
        }

        let expected = nextOffsets[id] ?? output.offset
        guard output.offset <= expected else { return }
        let overlap = max(0, expected - output.offset)
        if overlap < Int64(output.data.count) {
            let lowerBound = output.data.index(
                output.data.startIndex,
                offsetBy: Int(overlap)
            )
            emulator.feed(Data(output.data[lowerBound...]))
        }
        nextOffsets[id] = max(expected, output.nextOffset)
        clearGenerations[id] = output.clearGeneration
        if let index = descriptors.firstIndex(where: { $0.id == id }) {
            descriptors[index].earliestAvailableOffset = output.earliestAvailableOffset
            descriptors[index].nextOffset = output.nextOffset
        }
        emulators[id] = emulator
        renderRevision &+= 1
    }

    private func remove(_ id: UUID) {
        let removedIndex = descriptors.firstIndex { $0.id == id }
        descriptors.removeAll { $0.id == id }
        emulators.removeValue(forKey: id)
        nextOffsets.removeValue(forKey: id)
        clearGenerations.removeValue(forKey: id)
        lastRequestedDimensions.removeValue(forKey: id)
        if selectedTerminalID == id {
            let fallbackIndex = min(removedIndex ?? 0, max(0, descriptors.count - 1))
            selectedTerminalID = descriptors.isEmpty ? nil : descriptors[fallbackIndex].id
        }
        renderRevision &+= 1
    }

    private func present(_ error: Error) {
        guard !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription
    }

    private func present(
        _ error: Error,
        from service: TaskTerminalService,
        attachment: UUID
    ) {
        guard isCurrent(service, attachment: attachment) else { return }
        present(error)
    }

    private func isCurrent(
        _ service: TaskTerminalService,
        attachment: UUID
    ) -> Bool {
        self.service === service && attachmentID == attachment
    }

    private func finishInputOperation(_ id: UUID) {
        guard inputTailID == id else { return }
        inputTail = nil
        inputTailID = nil
    }

    private static func makeEmulator(rows: Int, columns: Int) -> TaskTerminalEmulator {
        if let emulator = try? TaskTerminalEmulator(
            rows: rows,
            columns: columns,
            maximumScrollbackLines: 5_000
        ) {
            return emulator
        }
        // Service metadata is validated to 1...1,000 before it reaches the UI;
        // this fallback keeps a corrupt presentation from becoming a crash.
        return try! TaskTerminalEmulator(rows: 1, columns: 1, maximumScrollbackLines: 0)
    }

    private static let emptySnapshot = makeEmulator(rows: 1, columns: 1).snapshot()
}

struct TaskTerminalPane: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel

    let sessionID: UUID
    @Binding var isPresented: Bool

    @StateObject private var model = TaskTerminalPaneModel()
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var pendingDestructiveAction: DestructiveAction?
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchRequest: UInt64 = 0
    @State private var copyRequest: UInt64 = 0

    private enum DestructiveAction: String, Identifiable {
        case kill
        case close
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.55)
            tabs
            Divider().opacity(0.4)

            if let descriptor = model.selectedDescriptor {
                TaskTerminalSurfaceView(
                    snapshot: model.selectedSnapshot,
                    applicationCursorKeys: model.selectedApplicationCursorKeys,
                    bracketedPaste: model.selectedBracketedPaste,
                    searchText: searchText,
                    searchRequest: searchRequest,
                    copyRequest: copyRequest,
                    onInput: { model.write($0) },
                    onResize: { rows, columns in
                        model.resizeSelected(rows: rows, columns: columns)
                    },
                    onRequestSearch: { isSearching = true }
                )
                .id(descriptor.id)
                .overlay(alignment: .topTrailing) {
                    stateBadge(descriptor.metadata.state)
                        .padding(7)
                        .allowsHitTesting(false)
                }
            } else if model.isLoading {
                ProgressView("載入 Task Terminals…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("這個 Task 尚無 Terminal")
                        .font(.callout.weight(.medium))
                    Button("New Terminal") { model.create() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.secondary)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: sessionID) {
            do {
                let service = try await agentViewModel.taskTerminalService(for: sessionID)
                await model.attach(to: service)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .onDisappear { model.detach() }
        .alert("Rename Terminal", isPresented: $isRenaming) {
            TextField("Terminal name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.renameSelected(to: renameDraft) }
        } message: {
            Text("名稱只會儲存為這個 Task 的 Terminal metadata。")
        }
        .alert(
            "Terminal Error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown terminal error")
        }
        .confirmationDialog(
            destructiveTitle,
            isPresented: Binding(
                get: { pendingDestructiveAction != nil },
                set: { if !$0 { pendingDestructiveAction = nil } }
            )
        ) {
            if pendingDestructiveAction == .kill {
                Button("Kill process tree", role: .destructive) {
                    pendingDestructiveAction = nil
                    model.killSelected()
                }
            } else if pendingDestructiveAction == .close {
                Button("Close and remove Terminal", role: .destructive) {
                    pendingDestructiveAction = nil
                    model.closeSelected()
                }
            }
            Button("Cancel", role: .cancel) { pendingDestructiveAction = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 7) {
            Label("Task Terminal", systemImage: "terminal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaTheme.accent)

            Button { model.create() } label: {
                Label("New", systemImage: "plus")
            }
            .help("New Terminal")

            Button {
                renameDraft = model.selectedDescriptor?.metadata.title ?? ""
                isRenaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(model.selectedDescriptor == nil)

            Button { model.reconnectSelected() } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .disabled(!canReconnect)

            Menu {
                Button("Interrupt (Ctrl-C)") { model.signalSelected(.interrupt) }
                Button("End of input (Ctrl-D)") { model.sendEOF() }
                Button("Suspend (Ctrl-Z)") { model.signalSelected(.suspend) }
                Divider()
                Button("Resume") { model.signalSelected(.resume) }
                Button("Hang up") { model.signalSelected(.hangup) }
                Button("Terminate") { model.signalSelected(.terminate) }
            } label: {
                Label("Signal", systemImage: "waveform.path")
            }
            .disabled(model.selectedDescriptor?.metadata.state != .running)

            Button {
                pendingDestructiveAction = .kill
            } label: {
                Label("Kill", systemImage: "stop.fill")
            }
            .disabled(model.selectedDescriptor?.metadata.state != .running)

            Button { model.clearSelected() } label: {
                Label("Clear", systemImage: "eraser")
            }
            .disabled(model.selectedDescriptor == nil)

            Button { copyRequest &+= 1 } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(model.selectedDescriptor == nil)

            Button { isSearching.toggle() } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .disabled(model.selectedDescriptor == nil)

            if isSearching {
                TextField("Find", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { searchRequest &+= 1 }
                Button {
                    searchText = ""
                    isSearching = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                pendingDestructiveAction = .close
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(model.selectedDescriptor == nil)
            .help("Close and remove Terminal")

            Button { isPresented = false } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Hide Task Terminal")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(model.descriptors) { descriptor in
                    Button {
                        model.select(descriptor.id)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(stateColor(descriptor.metadata.state))
                                .frame(width: 6, height: 6)
                            Text(descriptor.metadata.title)
                                .font(.caption)
                                .lineLimit(1)
                            if descriptor.metadata.state == .disconnected {
                                Image(systemName: "bolt.slash")
                                    .font(.caption2)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            descriptor.id == model.selectedTerminalID
                                ? LumaTheme.accent.opacity(0.13)
                                : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(height: 34)
    }

    private var canReconnect: Bool {
        guard let state = model.selectedDescriptor?.metadata.state else { return false }
        return state != .running
    }

    private var destructiveTitle: String {
        switch pendingDestructiveAction {
        case .kill: "Kill this Terminal process tree?"
        case .close: "Close this Terminal?"
        case nil: "Terminal action"
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: TaskTerminalLifecycleState) -> some View {
        if state != .running {
            Text(stateLabel(state))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private func stateColor(_ state: TaskTerminalLifecycleState) -> Color {
        switch state {
        case .running: .green
        case .disconnected: .orange
        case .failed: .red
        case .exited, .stopped: .secondary
        }
    }

    private func stateLabel(_ state: TaskTerminalLifecycleState) -> String {
        switch state {
        case .running: "Running"
        case .exited: "Exited"
        case .stopped: "Stopped"
        case .disconnected: "Disconnected · Reconnect starts a fresh shell"
        case .failed: "Failed"
        }
    }
}
