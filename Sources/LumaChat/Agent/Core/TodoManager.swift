import Foundation

enum TodoManagerError: LocalizedError, Sendable, Equatable {
    case notFound(UUID)
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case .notFound(let id): "找不到 Todo \(id.uuidString)。"
        case .emptyTitle: "Todo 標題不可為空白。"
        }
    }
}

actor TodoManager {
    private var todosBySession: [UUID: [AgentTodo]] = [:]

    func load(sessionID: UUID, todos: [AgentTodo]) {
        todosBySession[sessionID] = todos
    }

    func create(sessionID: UUID, title: String, detail: String? = nil) throws -> AgentTodo {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TodoManagerError.emptyTitle }
        let todo = AgentTodo(title: normalized, detail: detail)
        todosBySession[sessionID, default: []].append(todo)
        return todo
    }

    func update(
        sessionID: UUID,
        id: UUID,
        title: String? = nil,
        detail: String? = nil,
        status: AgentTodoStatus? = nil
    ) throws -> AgentTodo {
        guard let index = todosBySession[sessionID, default: []].firstIndex(where: { $0.id == id }) else {
            throw TodoManagerError.notFound(id)
        }
        if let title {
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw TodoManagerError.emptyTitle }
            todosBySession[sessionID]![index].title = normalized
        }
        if let detail { todosBySession[sessionID]![index].detail = detail }
        if let status { todosBySession[sessionID]![index].status = status }
        todosBySession[sessionID]![index].updatedAt = Date()
        return todosBySession[sessionID]![index]
    }

    func complete(sessionID: UUID, id: UUID) throws -> AgentTodo {
        try update(sessionID: sessionID, id: id, status: .completed)
    }

    func list(sessionID: UUID) -> [AgentTodo] {
        todosBySession[sessionID, default: []]
    }

    func clear(sessionID: UUID) {
        todosBySession.removeValue(forKey: sessionID)
    }
}
