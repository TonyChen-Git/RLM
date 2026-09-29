import Foundation
import XCTest
@testable import LumaChat

private enum MaintenanceProbeError: LocalizedError {
    case unsupported
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: "Unsupported test operation"
        case .loadFailed: "Injected registry load failure"
        }
    }
}

private actor MaintenanceWorktreeProbe: TaskWorktreeManaging {
    private var records: [ManagedWorktreeRecord]
    private let inspection: ManagedWorktreeInspection
    private var cleanupReport = WorktreeMaintenanceReport()
    private var repairReport = WorktreeMaintenanceReport()
    private var inspectionIDs: [UUID] = []
    private var cleanupAges: [TimeInterval] = []
    private var cleanupNowValues: [Date?] = []
    private var repairCount = 0
    private var shouldFailList = false

    init(record: ManagedWorktreeRecord, inspection: ManagedWorktreeInspection) {
        records = [record]
        self.inspection = inspection
    }

    func create(
        repositoryRoot: URL,
        taskID: UUID,
        options: ManagedWorktreeCreateOptions
    ) async throws -> ManagedWorktreeRecord {
        throw MaintenanceProbeError.unsupported
    }

    func reuse(id: UUID, taskID: UUID) async throws -> ManagedWorktreeRecord {
        throw MaintenanceProbeError.unsupported
    }

    func release(_ lease: WorktreeLease) async throws -> ManagedWorktreeRecord {
        throw MaintenanceProbeError.unsupported
    }

    func list() async throws -> [ManagedWorktreeRecord] {
        if shouldFailList { throw MaintenanceProbeError.loadFailed }
        return records
    }

    func inspect(id: UUID) async throws -> ManagedWorktreeInspection {
        inspectionIDs.append(id)
        return inspection
    }

    func remove(id: UUID, lease: WorktreeLease?, force: Bool) async throws {
        throw MaintenanceProbeError.unsupported
    }

    func cleanup(olderThan age: TimeInterval, now: Date?) async throws -> WorktreeMaintenanceReport {
        cleanupAges.append(age)
        cleanupNowValues.append(now)
        records.removeAll { cleanupReport.removedIDs.contains($0.id) }
        return cleanupReport
    }

    func repair() async throws -> WorktreeMaintenanceReport {
        repairCount += 1
        return repairReport
    }

    func setCleanupReport(_ report: WorktreeMaintenanceReport) { cleanupReport = report }
    func setRepairReport(_ report: WorktreeMaintenanceReport) { repairReport = report }
    func setShouldFailList(_ value: Bool) { shouldFailList = value }
    func observedInspectionIDs() -> [UUID] { inspectionIDs }
    func observedCleanupAges() -> [TimeInterval] { cleanupAges }
    func observedCleanupNowValues() -> [Date?] { cleanupNowValues }
    func observedRepairCount() -> Int { repairCount }
}

final class ManagedWorktreeMaintenanceViewModelTests: XCTestCase {
    @MainActor
    func testRefreshAndInspectionShowVerifiedState() async throws {
        let record = makeRecord()
        let inspection = makeInspection(for: record, isClean: false)
        let probe = MaintenanceWorktreeProbe(record: record, inspection: inspection)
        let viewModel = AgentViewModel(worktreeService: probe)

        await viewModel.refreshManagedWorktrees()
        XCTAssertEqual(viewModel.managedWorktreeRecords.map(\.id), [record.id])
        XCTAssertTrue(viewModel.managedWorktreeInspections.isEmpty)

        await viewModel.inspectManagedWorktree(id: record.id)
        let inspectedIDs = await probe.observedInspectionIDs()
        XCTAssertEqual(viewModel.managedWorktreeInspections[record.id]?.isClean, false)
        XCTAssertEqual(inspectedIDs, [record.id])
        XCTAssertNil(viewModel.managedWorktreeMaintenanceError)
    }

    @MainActor
    func testCleanupUsesSevenDayCleanOnlyServicePolicyAndReloads() async throws {
        let record = makeRecord()
        let probe = MaintenanceWorktreeProbe(
            record: record,
            inspection: makeInspection(for: record, isClean: true)
        )
        var report = WorktreeMaintenanceReport()
        report.removedIDs = [record.id]
        await probe.setCleanupReport(report)
        let viewModel = AgentViewModel(worktreeService: probe)

        await viewModel.refreshManagedWorktrees()
        await viewModel.cleanupManagedWorktrees()

        let cleanupAges = await probe.observedCleanupAges()
        let cleanupNowValues = await probe.observedCleanupNowValues()
        XCTAssertEqual(cleanupAges, [ManagedWorktreeLimits.defaultCleanupAge])
        XCTAssertEqual(cleanupNowValues.count, 1)
        XCTAssertTrue(cleanupNowValues.allSatisfy { $0 == nil })
        XCTAssertEqual(viewModel.managedWorktreeMaintenanceReport?.removedIDs, [record.id])
        XCTAssertTrue(viewModel.managedWorktreeRecords.isEmpty)
    }

    @MainActor
    func testCleanupAndRepairRefuseActiveTaskAndReportCompletedRepair() async throws {
        let record = makeRecord()
        let probe = MaintenanceWorktreeProbe(
            record: record,
            inspection: makeInspection(for: record, isClean: true)
        )
        var report = WorktreeMaintenanceReport()
        report.repairedIDs = [record.id]
        await probe.setRepairReport(report)
        let viewModel = AgentViewModel(worktreeService: probe)

        let runningSession = AgentSession(mode: .agent)
        viewModel.beginRunTracking(runID: UUID(), session: runningSession, userRequest: nil)
        XCTAssertFalse(viewModel.canRunManagedWorktreeMaintenance)
        await viewModel.cleanupManagedWorktrees()
        let refusedCleanupAges = await probe.observedCleanupAges()
        XCTAssertTrue(refusedCleanupAges.isEmpty)
        XCTAssertTrue(viewModel.managedWorktreeMaintenanceError?.contains("清理") == true)
        await viewModel.repairManagedWorktrees()
        let refusedRepairCount = await probe.observedRepairCount()
        XCTAssertEqual(refusedRepairCount, 0)
        XCTAssertNotNil(viewModel.managedWorktreeMaintenanceError)

        let idleViewModel = AgentViewModel(worktreeService: probe)
        await idleViewModel.repairManagedWorktrees()
        let completedRepairCount = await probe.observedRepairCount()
        XCTAssertEqual(completedRepairCount, 1)
        XCTAssertEqual(idleViewModel.managedWorktreeMaintenanceReport?.repairedIDs, [record.id])
        XCTAssertNil(idleViewModel.managedWorktreeMaintenanceError)
    }

    @MainActor
    func testRegistryLoadFailureIsVisible() async throws {
        let record = makeRecord()
        let probe = MaintenanceWorktreeProbe(
            record: record,
            inspection: makeInspection(for: record, isClean: true)
        )
        await probe.setShouldFailList(true)
        let viewModel = AgentViewModel(worktreeService: probe)

        await viewModel.refreshManagedWorktrees()

        XCTAssertTrue(viewModel.managedWorktreeRecords.isEmpty)
        XCTAssertTrue(viewModel.managedWorktreeMaintenanceError?.contains("Injected registry load failure") == true)
        XCTAssertFalse(viewModel.isMaintainingManagedWorktrees)
    }

    private func makeRecord() -> ManagedWorktreeRecord {
        ManagedWorktreeRecord(
            repositoryRootPath: "/repository",
            sourceCheckoutPath: "/repository",
            worktreePath: "/managed/worktree",
            baseObjectID: String(repeating: "a", count: 40),
            headObjectID: String(repeating: "a", count: 40),
            branchName: "codex/test",
            createdBranch: true
        )
    }

    private func makeInspection(
        for record: ManagedWorktreeRecord,
        isClean: Bool
    ) -> ManagedWorktreeInspection {
        ManagedWorktreeInspection(
            worktreeID: record.id,
            state: .ready,
            worktreePath: record.worktreePath,
            exists: true,
            isRegistered: true,
            isClean: isClean,
            headObjectID: record.headObjectID,
            branchName: record.branchName,
            issues: [],
            inspectedAt: Date()
        )
    }
}
