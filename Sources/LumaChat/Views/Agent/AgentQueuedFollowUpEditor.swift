import SwiftUI

struct AgentQueuedFollowUpEditRequest: Identifiable {
    let sessionID: UUID
    let entry: AgentQueuedFollowUp
    var id: UUID { entry.id }
}

/// The sheet owns its draft and receives its original Task in one value. This
/// avoids first-presentation ordering between independent parent @State fields.
struct AgentQueuedFollowUpEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agentViewModel: AgentViewModel
    let request: AgentQueuedFollowUpEditRequest
    @State private var text: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(request: AgentQueuedFollowUpEditRequest) {
        self.request = request
        _text = State(initialValue: request.entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("編輯排隊訊息").font(.headline)
            TextEditor(text: $text).frame(minHeight: 120)
                .accessibilityLabel("排隊訊息內容")
                .disabled(isSaving)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("儲存") {
                    isSaving = true
                    saveError = nil
                    let submitted = text
                    Task {
                        let saved = await agentViewModel.updateQueuedFollowUp(
                            id: request.entry.id, sessionID: request.sessionID, text: submitted
                        )
                        isSaving = false
                        if saved { dismiss() }
                        else { saveError = agentViewModel.errorMessage ?? "排隊訊息無法更新；內容仍保留在此。" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving
                    || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && request.entry.imageAttachments.isEmpty)
                    || text.utf8.count > AgentQueuedFollowUpStore.maximumPromptBytes)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
