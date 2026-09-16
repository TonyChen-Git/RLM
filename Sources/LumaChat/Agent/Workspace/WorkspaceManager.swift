import AppKit
import Foundation

enum WorkspaceManagerError: LocalizedError, Sendable {
    case invalidFolder
    case bookmark(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolder: "選取的位置不是安全、可讀取的專案資料夾。"
        case .bookmark(let detail): "無法保存專案資料夾權限：\(detail)"
        }
    }
}

final class WorkspaceAccessLease: @unchecked Sendable {
    let rootURL: URL
    private let didStartAccess: Bool

    init(rootURL: URL) {
        self.rootURL = rootURL
        didStartAccess = rootURL.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccess { rootURL.stopAccessingSecurityScopedResource() }
    }
}

@MainActor
final class WorkspaceManager {
    nonisolated static func isGitRepository(at rootPath: String) -> Bool {
        do {
            return try GitRepositoryLayout.inspect(
                workspaceRoot: URL(fileURLWithPath: rootPath, isDirectory: true)
            ) != nil
        } catch {
            return false
        }
    }

    nonisolated static func currentBranch(at rootPath: String) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", rootPath, "branch", "--show-current"]
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let branch = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return branch.isEmpty ? nil : branch
            } catch {
                return nil
            }
        }.value
    }

    func chooseWorkspace() throws -> (AgentWorkspace, WorkspaceAccessLease)? {
        let panel = NSOpenPanel()
        panel.title = "開啟 Coding Project"
        panel.message = "Agent 的檔案、Terminal 與 Git 工具只會在這個 Workspace 範圍內運作。"
        panel.prompt = "開啟專案"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let selected = panel.url else { return nil }

        let canonical = selected.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard canonical.path != "/",
              FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceManagerError.invalidFolder
        }

        let bookmark: Data
        do {
            bookmark = try selected.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )
        } catch {
            throw WorkspaceManagerError.bookmark(error.localizedDescription)
        }

        let workspace = AgentWorkspace(
            name: canonical.lastPathComponent,
            rootPath: canonical.path,
            allowedPaths: [],
            bookmarkData: bookmark,
            gitRepository: Self.isGitRepository(at: canonical.path),
            branch: nil
        )
        return (workspace, WorkspaceAccessLease(rootURL: selected))
    }

    func open(_ workspace: AgentWorkspace) throws -> (AgentWorkspace, WorkspaceAccessLease) {
        let candidate: URL
        if let bookmark = workspace.bookmarkData {
            var isStale = false
            do {
                candidate = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                throw WorkspaceManagerError.bookmark(error.localizedDescription)
            }
        } else {
            candidate = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        }

        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard canonical.path != "/",
              FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceManagerError.invalidFolder
        }

        var updated = workspace
        updated.name = canonical.lastPathComponent
        updated.rootPath = canonical.path
        updated.lastOpened = Date()
        updated.gitRepository = Self.isGitRepository(at: canonical.path)
        if let refreshed = try? candidate.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        ) {
            updated.bookmarkData = refreshed
        }
        return (updated, WorkspaceAccessLease(rootURL: candidate))
    }
}
