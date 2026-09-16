import XCTest

@testable import LumaChat

final class AgentDetailSurfacePolicyTests: XCTestCase {
    private let reviewTask = AgentTaskType.review(
        sourceSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
    )

    func testDedicatedReviewTaskHidesReviewAndTerminalPanes() {
        XCTAssertFalse(
            AgentDetailSurfacePolicy.allowsAuxiliaryPanes(for: reviewTask)
        )
        XCTAssertTrue(
            AgentDetailSurfacePolicy.allowsAuxiliaryPanes(for: .coding)
        )
    }

    func testDedicatedReviewTaskNeverOffersExecutePlan() {
        XCTAssertFalse(
            AgentDetailSurfacePolicy.showsExecutePlan(
                taskType: reviewTask,
                mode: .plan,
                state: .completed
            )
        )
        XCTAssertTrue(
            AgentDetailSurfacePolicy.showsExecutePlan(
                taskType: .coding,
                mode: .plan,
                state: .completed
            )
        )
        XCTAssertFalse(
            AgentDetailSurfacePolicy.showsExecutePlan(
                taskType: .coding,
                mode: .plan,
                state: .running
            )
        )
    }
}
