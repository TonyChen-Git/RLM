import Foundation
import XCTest

@testable import LumaChat

final class TaskTerminalPaneModelTests: XCTestCase {
    @MainActor
    func testPanePreservesRapidInputOrderAndClosesWithoutEventDependency() async throws {
        let scratch = AppPaths.projectTemporaryRoot
            .appendingPathComponent("terminal-pane-model-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceRoot = scratch.appendingPathComponent("workspace", isDirectory: true)
        let sessionsRoot = scratch.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sessionsRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let workspace = AgentWorkspace(
            name: "pane-model",
            rootPath: workspaceRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let service = TaskTerminalService(
            taskID: UUID(),
            validator: try WorkspaceSecurityValidator(workspace: workspace),
            sessionsRoot: sessionsRoot
        )
        let model = TaskTerminalPaneModel()
        do {
            let descriptor = try await service.create(
                title: "Ordered input",
                shell: "/bin/sh"
            )
            await model.attach(to: service)
            model.select(descriptor.id)

            let byteCount = 512
            let command = #"/bin/stty raw -echo; exec /usr/bin/perl -e '$|=1; print q{READY}; my $data=q{}; while (length($data) < 512) { my $count=sysread(STDIN,my $chunk,512-length($data)); exit 81 unless defined($count) && $count > 0; $data.=$chunk; } syswrite(STDOUT,q{BEGIN},5); syswrite(STDOUT,$data,length($data));'"# + "\n"
            model.write(Data(command.utf8))
            _ = try await waitForOutput(
                service,
                id: descriptor.id,
                containing: "READY"
            )

            let payload = Data((0..<byteCount).map { UInt8(0x21 + ($0 % 90)) })
            for byte in payload { model.write(Data([byte])) }
            _ = try await waitForOutput(
                service,
                id: descriptor.id,
                containing: "BEGIN"
            )
            try await waitForExit(service, id: descriptor.id)
            let output = try await service.read(
                id: descriptor.id,
                offset: 0,
                maxBytes: 1 * 1_024 * 1_024
            )
            let expectedSuffix = Data("BEGIN".utf8) + payload
            let actualSuffix = Data(output.data.suffix(expectedSuffix.count))
            if actualSuffix != expectedSuffix {
                let mismatch = zip(actualSuffix, expectedSuffix).enumerated().first {
                    $0.element.0 != $0.element.1
                }
                XCTFail(
                    "Ordered input mismatch at \(mismatch?.offset ?? -1): "
                        + "actual=\(mismatch?.element.0 ?? 0) "
                        + "expected=\(mismatch?.element.1 ?? 0)"
                )
            }

            try await waitUntil {
                model.selectedSnapshot.allLines.contains {
                    $0.plainText().contains("BEGIN")
                }
            }
            model.closeSelected()
            try await waitUntil { model.descriptors.isEmpty }
        } catch {
            model.detach(clearDisplay: true)
            await service.disposeAll()
            throw error
        }
        model.detach(clearDisplay: true)
        await service.disposeAll()
    }

    @MainActor
    private func waitForOutput(
        _ service: TaskTerminalService,
        id: UUID,
        containing marker: String,
        timeout: Duration = .seconds(8)
    ) async throws -> TaskTerminalOutput {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            let output = try await service.read(
                id: id,
                offset: 0,
                maxBytes: 1 * 1_024 * 1_024
            )
            if String(decoding: output.data, as: UTF8.self).contains(marker) {
                return output
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PaneModelTestError.timeout(marker)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(8),
        condition: () -> Bool
    ) async throws {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PaneModelTestError.timeout("condition")
    }

    @MainActor
    private func waitForExit(
        _ service: TaskTerminalService,
        id: UUID,
        timeout: Duration = .seconds(8)
    ) async throws {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            if let descriptor = try await service.list().first(where: { $0.id == id }),
               descriptor.metadata.state != .running {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PaneModelTestError.timeout("exit")
    }
}

private enum PaneModelTestError: Error {
    case timeout(String)
}
