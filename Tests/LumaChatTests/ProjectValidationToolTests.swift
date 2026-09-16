import Foundation
import Darwin
import XCTest
@testable import LumaChat

final class ProjectValidationToolTests: XCTestCase {
    func testDetectorSelectsFixedCommandsForSupportedProjectManifests() throws {
        try withWorkspace(name: "swift") { root, detector in
            try write("// swift-tools-version: 6.0\n", to: root.appendingPathComponent("Package.swift"))
            XCTAssertEqual(
                try detector().detect(.build),
                .init(
                    action: .build,
                    projectKind: .swiftPackage,
                    manifestPath: "Package.swift",
                    command: "swift build",
                    workingDirectory: "."
                )
            )
            XCTAssertEqual(try detector().detect(.test).command, "swift test")
        }

        try withWorkspace(name: "node") { root, detector in
            try write(
                #"{"scripts":{"build":"printf injected-build","test":"printf injected-test"}}"#,
                to: root.appendingPathComponent("package.json")
            )
            XCTAssertEqual(try detector().detect(.build).command, "npm run build")
            XCTAssertEqual(try detector().detect(.test).command, "npm run test")
            XCTAssertFalse(try detector().detect(.build).command.contains("injected"))
        }

        try withWorkspace(name: "python") { root, detector in
            try write(
                "[build-system]\nrequires = []\nbuild-backend = \"example.backend\"\n",
                to: root.appendingPathComponent("pyproject.toml")
            )
            XCTAssertEqual(
                try detector().detect(.build).command,
                "python3 -m compileall -q -x '(^|/)\\._' ."
            )
            XCTAssertThrowsError(try detector().detect(.test)) { error in
                XCTAssertEqual(
                    error as? ProjectValidationCommandDetectorError,
                    .unsupportedProject(.test)
                )
            }
            let selection = try detector().detectForExecution(.test)
            XCTAssertEqual(selection.actualAction, .build)
            XCTAssertEqual(
                selection.command.command,
                "python3 -m compileall -q -x '(^|/)\\._' ."
            )
        }

        try withWorkspace(name: "rust") { root, detector in
            try write("[package]\nname = \"tiny\"\n", to: root.appendingPathComponent("Cargo.toml"))
            XCTAssertEqual(try detector().detect(.build).command, "cargo build")
            XCTAssertEqual(try detector().detect(.test).command, "cargo test")
        }

        try withWorkspace(name: "go") { root, detector in
            try write("module invalid.local/tiny\n", to: root.appendingPathComponent("go.mod"))
            XCTAssertEqual(try detector().detect(.build).command, "go build ./...")
            XCTAssertEqual(try detector().detect(.test).command, "go test ./...")
        }
    }

    func testDetectorSelectsBoundedPythonTestFrameworkOnlyWhenProven() throws {
        try withWorkspace(name: "python-pytest-config") { root, detector in
            try write(
                """
                [project]
                name = "pytest-config"
                version = "1.0.0"

                [tool.pytest.ini_options]
                addopts = "-q"
                """,
                to: root.appendingPathComponent("pyproject.toml")
            )
            XCTAssertEqual(try detector().detect(.test).command, "python3 -m pytest")
        }

        try withWorkspace(name: "python-pytest-dependency") { root, detector in
            try write(
                """
                [project]
                name = "pytest-dependency"
                version = "1.0.0"
                description = "Mentions pytest without selecting it"
                dependencies = [
                    "requests",
                    "pytest>=8",
                ]
                """,
                to: root.appendingPathComponent("pyproject.toml")
            )
            XCTAssertEqual(try detector().detect(.test).command, "python3 -m pytest")
        }

        try withWorkspace(name: "python-pytest-file") { root, detector in
            try write(
                "[project]\nname = \"pytest-file\"\nversion = \"1.0.0\"\n",
                to: root.appendingPathComponent("pyproject.toml")
            )
            try write(
                "import pytest\n\ndef test_answer():\n    assert 6 * 7 == 42\n",
                to: root.appendingPathComponent("tests/test_answer.py")
            )
            XCTAssertEqual(try detector().detect(.test).command, "python3 -m pytest")
        }

        try withWorkspace(name: "python-pytest-convention") { root, detector in
            try write(
                "[project]\nname = \"pytest-convention\"\nversion = \"1.0.0\"\n",
                to: root.appendingPathComponent("pyproject.toml")
            )
            try write(
                "def test_answer():\n    assert 6 * 7 == 42\n",
                to: root.appendingPathComponent("test_answer.py")
            )
            XCTAssertEqual(try detector().detect(.test).command, "python3 -m pytest")
        }

        try withWorkspace(name: "python-unittest-file") { root, detector in
            try write(
                "[project]\nname = \"unittest-file\"\nversion = \"1.0.0\"\n",
                to: root.appendingPathComponent("pyproject.toml")
            )
            try write(
                """
                import unittest

                class AnswerTests(unittest.TestCase):
                    def test_answer(self):
                        self.assertEqual(6 * 7, 42)
                """,
                to: root.appendingPathComponent("test_answer.py")
            )
            XCTAssertEqual(
                try detector().detect(.test).command,
                "python3 -m unittest discover"
            )
        }

        try withWorkspace(name: "python-ambiguous-file") { root, detector in
            try write(
                """
                [project]
                name = "ambiguous"
                version = "1.0.0"
                description = "Works well with pytest"
                # [tool.pytest.ini_options]
                """,
                to: root.appendingPathComponent("pyproject.toml")
            )
            try write(
                """
                \"\"\"
                import unittest
                class FakeTests(unittest.TestCase):
                    def test_not_code(self):
                        pass
                \"\"\"

                def helper():
                    return 42
                """,
                to: root.appendingPathComponent("test_answer.py")
            )
            try write(
                "def test_not_default_pytest_filename():\n    assert True\n",
                to: root.appendingPathComponent("testing.py")
            )
            XCTAssertThrowsError(try detector().detect(.test)) { error in
                XCTAssertEqual(
                    error as? ProjectValidationCommandDetectorError,
                    .unsupportedProject(.test)
                )
            }
        }

        try withWorkspace(name: "python-unittest-nonpackage") { root, detector in
            try write(
                "[project]\nname = \"nested-unit\"\nversion = \"1.0.0\"\n",
                to: root.appendingPathComponent("pyproject.toml")
            )
            try writeUnittestFile(to: root.appendingPathComponent("tests/test_answer.py"))
            XCTAssertThrowsError(try detector().detect(.test))

            try write("", to: root.appendingPathComponent("tests/__init__.py"))
            XCTAssertEqual(
                try detector().detect(.test).command,
                "python3 -m unittest discover"
            )
        }

        try withWorkspace(name: "python-truncated-layout") { root, detector in
            try write(
                "[project]\nname = \"bounded-unit\"\nversion = \"1.0.0\"\n",
                to: root.appendingPathComponent("pyproject.toml")
            )
            try writeUnittestFile(to: root.appendingPathComponent("test_answer.py"))
            for index in 0..<520 {
                try write("", to: root.appendingPathComponent("source_\(index).py"))
            }
            XCTAssertThrowsError(try detector().detect(.test)) { error in
                XCTAssertEqual(
                    error as? ProjectValidationCommandDetectorError,
                    .unsupportedProject(.test)
                )
            }
        }
    }

    func testDetectorBoundsManifestReadsAndReturnsDeterministicUnsupportedError() throws {
        try withWorkspace(name: "unsupported") { root, detector in
            try Data(repeating: 0x41, count: 512 * 1_024 + 1).write(
                to: root.appendingPathComponent("package.json")
            )
            for action in [ProjectValidationAction.build, .test] {
                XCTAssertThrowsError(try detector().detect(action)) { error in
                    XCTAssertEqual(
                        error as? ProjectValidationCommandDetectorError,
                        .unsupportedProject(action)
                    )
                    XCTAssertEqual(
                        error.localizedDescription,
                        "No supported project \(action.rawValue) command was detected at the workspace root."
                    )
                }
            }
        }
    }

    func testDetectorQuotesXcodeContainerAndRequiresSharedSchemeForTests() throws {
        try withWorkspace(name: "xcode") { root, detector in
            let project = root.appendingPathComponent("Demo's App.xcodeproj", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let build = try detector().detect(.build)
            XCTAssertEqual(build.projectKind, .xcodeProject)
            XCTAssertEqual(
                build.command,
                "xcodebuild -project 'Demo'\\''s App.xcodeproj' -configuration Debug build"
            )
            XCTAssertThrowsError(try detector().detect(.test))

            try write(
                "<Scheme/>",
                to: project.appendingPathComponent("xcshareddata/xcschemes/Demo Tests.xcscheme")
            )
            XCTAssertEqual(
                try detector().detect(.test).command,
                "xcodebuild -project 'Demo'\\''s App.xcodeproj' -scheme 'Demo Tests' "
                    + "-configuration Debug test"
            )
        }
    }

    func testDetectorFallsBackOnlyFromExplicitlyUnsupportedTestToBuild() throws {
        try withWorkspace(name: "build-only-node") { root, detector in
            try write(
                #"{"scripts":{"build":"/usr/bin/true"}}"#,
                to: root.appendingPathComponent("package.json")
            )

            XCTAssertThrowsError(try detector().detect(.test)) { error in
                XCTAssertEqual(
                    error as? ProjectValidationCommandDetectorError,
                    .unsupportedProject(.test)
                )
            }
            let selection = try detector().detectForExecution(.test)
            XCTAssertEqual(selection.requestedAction, .test)
            XCTAssertEqual(selection.actualAction, .build)
            XCTAssertTrue(selection.usedFallback)
            XCTAssertEqual(selection.command.command, "npm run build")
            XCTAssertEqual(
                selection.fallbackReason,
                "No deterministic test command was detected; ran the fixed build command instead."
            )
        }

        try withWorkspace(name: "no-validation-action") { root, detector in
            try write(#"{"scripts":{}}"#, to: root.appendingPathComponent("package.json"))
            XCTAssertThrowsError(try detector().detectForExecution(.test)) { error in
                XCTAssertEqual(
                    error as? ProjectValidationCommandDetectorError,
                    .unsupportedProject(.build)
                )
            }
        }
    }

    func testBuildAndTestToolsExposeExecuteOnlyMetadataWithoutCommandInput() async throws {
        let tools = BuiltinToolFactory.makeTools(todoManager: TodoManager())
        for name in ["build", "test"] {
            let tool = try XCTUnwrap(tools.first { $0.name == name })
            XCTAssertEqual(tool.id, "builtin.\(name)")
            XCTAssertEqual(tool.category, .terminal)
            XCTAssertEqual(tool.permissionLevel, .execute)
            XCTAssertFalse(tool.supportsParallelExecution)
            XCTAssertEqual(tool.inputSchema["properties"]?.objectValue, [:])
            XCTAssertEqual(tool.inputSchema["required"]?.arrayValue, [])
            XCTAssertEqual(tool.inputSchema["additionalProperties"]?.boolValue, false)
            XCTAssertNil(tool.inputSchema["properties"]?["command"])
        }
    }

    func testBuildAndTestToolsRunTinyProjectAndKeepArtifactsInProjectTmp() async throws {
        let root = try makeWorkspaceRoot(name: "python-execution")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTinyPythonProject(at: root)

        let registry = ToolRegistry()
        let environment = BuiltinToolEnvironment()
        try await BuiltinToolFactory.register(
            in: registry,
            environment: environment,
            todoManager: TodoManager()
        )
        let callerSelectedBytecodeCache = root.appendingPathComponent(
            "caller-selected-bytecode-cache",
            isDirectory: true
        )
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: workspace(root: root),
            commandTimeout: 90,
            environment: ["PYTHONPYCACHEPREFIX": callerSelectedBytecodeCache.path]
        )

        do {
            let build = try await execute(
                "build",
                // An out-of-schema command is ignored; the detector remains authoritative.
                arguments: .object(["command": .string("printf MODEL-COMMAND-MUST-NOT-RUN")]),
                registry: registry,
                context: context
            )
            XCTAssertFalse(build.isError, build.content)
            XCTAssertEqual(
                build.data?["command"]?.stringValue,
                "python3 -m compileall -q -x '(^|/)\\._' ."
            )
            XCTAssertEqual(build.data?["requested_action"]?.stringValue, "build")
            XCTAssertEqual(build.data?["actual_action"]?.stringValue, "build")
            XCTAssertEqual(build.data?["fallback_used"]?.boolValue, false)
            XCTAssertTrue(build.content.contains("Actual Action: build"))
            XCTAssertFalse(build.content.contains("MODEL-COMMAND-MUST-NOT-RUN"))

            let test = try await execute(
                "test",
                arguments: .emptyObject,
                registry: registry,
                context: context
            )
            XCTAssertFalse(test.isError, test.content)
            XCTAssertEqual(test.data?["command"]?.stringValue, "python3 -m unittest discover")
            XCTAssertEqual(test.data?["requested_action"]?.stringValue, "test")
            XCTAssertEqual(test.data?["actual_action"]?.stringValue, "test")
            XCTAssertEqual(test.data?["fallback_used"]?.boolValue, false)
            XCTAssertTrue(test.content.contains("Fallback: no"))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("__pycache__").path)
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: callerSelectedBytecodeCache.path),
                "TerminalSession must force Python bytecode into its project-tmp runtime."
            )
        } catch {
            await environment.stopAllProcesses()
            throw error
        }
        await environment.stopAllProcesses()
    }

    func testTestToolExecutesBuildFallbackAndReportsActualAction() async throws {
        let root = try makeWorkspaceRoot(name: "node-build-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            #"{"scripts":{"build":"/usr/bin/printf real-build-fallback"}}"#,
            to: root.appendingPathComponent("package.json")
        )
        let bin = root.appendingPathComponent("tool-bin", isDirectory: true)
        let fakeNPM = bin.appendingPathComponent("npm")
        try write(
            """
            #!/bin/sh
            if [ "$1" = "run" ] && [ "$2" = "build" ]; then
              /usr/bin/printf fake-build-fallback
              exit 0
            fi
            exit 91
            """,
            to: fakeNPM
        )
        XCTAssertEqual(Darwin.chmod(fakeNPM.path, mode_t(0o700)), 0)

        let registry = ToolRegistry()
        let environment = BuiltinToolEnvironment()
        try await BuiltinToolFactory.register(
            in: registry,
            environment: environment,
            todoManager: TodoManager()
        )
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: workspace(root: root),
            commandTimeout: 90,
            environment: ["PATH": bin.path]
        )

        do {
            let result = try await execute(
                "test",
                arguments: .emptyObject,
                registry: registry,
                context: context
            )
            XCTAssertFalse(result.isError, result.content)
            XCTAssertEqual(result.data?["command"]?.stringValue, "npm run build")
            XCTAssertEqual(result.data?["requested_action"]?.stringValue, "test")
            XCTAssertEqual(result.data?["actual_action"]?.stringValue, "build")
            XCTAssertEqual(result.data?["fallback_used"]?.boolValue, true)
            XCTAssertNotNil(result.data?["fallback_reason"]?.stringValue)
            XCTAssertTrue(result.content.contains("Requested Action: test"))
            XCTAssertTrue(result.content.contains("Actual Action: build"))
            XCTAssertTrue(result.content.contains("Fallback: yes"))
        } catch {
            await environment.stopAllProcesses()
            throw error
        }
        await environment.stopAllProcesses()
    }

    func testRealTestFailureNeverFallsBackToBuild() async throws {
        let root = try makeWorkspaceRoot(name: "node-test-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            #"{"scripts":{"build":"/usr/bin/true","test":"/usr/bin/false"}}"#,
            to: root.appendingPathComponent("package.json")
        )
        let bin = root.appendingPathComponent("tool-bin", isDirectory: true)
        let fakeNPM = bin.appendingPathComponent("npm")
        try write(
            """
            #!/bin/sh
            if [ "$1" = "run" ] && [ "$2" = "test" ]; then
              /usr/bin/printf test-failed >&2
              exit 7
            fi
            if [ "$1" = "run" ] && [ "$2" = "build" ]; then
              /usr/bin/printf build-must-not-run
              exit 0
            fi
            exit 91
            """,
            to: fakeNPM
        )
        XCTAssertEqual(Darwin.chmod(fakeNPM.path, mode_t(0o700)), 0)

        let registry = ToolRegistry()
        let environment = BuiltinToolEnvironment()
        try await BuiltinToolFactory.register(
            in: registry,
            environment: environment,
            todoManager: TodoManager()
        )
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: workspace(root: root),
            commandTimeout: 90,
            environment: ["PATH": bin.path]
        )

        do {
            let result = try await execute(
                "test",
                arguments: .emptyObject,
                registry: registry,
                context: context
            )
            XCTAssertTrue(result.isError, result.content)
            XCTAssertEqual(result.data?["command"]?.stringValue, "npm run test")
            XCTAssertEqual(result.data?["requested_action"]?.stringValue, "test")
            XCTAssertEqual(result.data?["actual_action"]?.stringValue, "test")
            XCTAssertEqual(result.data?["fallback_used"]?.boolValue, false)
            XCTAssertTrue(result.content.contains("Actual Action: test"))
            XCTAssertTrue(result.content.contains("Fallback: no"))
            XCTAssertFalse(result.content.contains("build-must-not-run"))
        } catch {
            await environment.stopAllProcesses()
            throw error
        }
        await environment.stopAllProcesses()
    }

    private func withWorkspace(
        name: String,
        body: (URL, () throws -> ProjectValidationCommandDetector) throws -> Void
    ) throws {
        let root = try makeWorkspaceRoot(name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root) {
            try ProjectValidationCommandDetector(
                validator: WorkspaceSecurityValidator(workspace: self.workspace(root: root))
            )
        }
    }

    private func execute(
        _ name: String,
        arguments: JSONValue,
        registry: ToolRegistry,
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let registered = await registry.tool(named: name)
        let tool = try XCTUnwrap(registered)
        return try await tool.execute(arguments: arguments, context: context)
    }

    private func makeWorkspaceRoot(name: String) throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("project-validation-tool-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func workspace(root: URL) -> AgentWorkspace {
        AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func writeTinyPythonProject(at root: URL) throws {
        try write(
            """
            [project]
            name = "tiny-validation"
            version = "1.0.0"
            """,
            to: root.appendingPathComponent("pyproject.toml")
        )
        try write(
            "def validation_sum(lhs, rhs):\n    return lhs + rhs\n",
            to: root.appendingPathComponent("tiny_validation.py")
        )
        try write(
            """
            import unittest
            from tiny_validation import validation_sum

            class TinyValidationTests(unittest.TestCase):
                def test_sum(self):
                    self.assertEqual(validation_sum(20, 22), 42)
            """,
            to: root.appendingPathComponent("test_tiny_validation.py")
        )
    }

    private func writeUnittestFile(to url: URL) throws {
        try write(
            """
            import unittest

            class AnswerTests(unittest.TestCase):
                def test_answer(self):
                    self.assertEqual(6 * 7, 42)
            """,
            to: url
        )
    }
}
