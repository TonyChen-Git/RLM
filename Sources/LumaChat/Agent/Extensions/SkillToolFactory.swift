import Foundation

enum SkillToolFactory {
    static func makeTools(service: SkillService) -> [any AgentTool] {
        [SkillResourceReadTool(service: service)]
    }
}

private struct SkillResourceReadTool: AgentTool {
    let id = "builtin.skill-read-resource"
    let name = "skill_read_resource"
    let displayName = "Read Skill Resource"
    let description = "Read one bounded UTF-8 reference/template file from a Skill already loaded for this Task. Paths are relative to the Skill root."
    let inputSchema = JSONValue.objectSchema(
        properties: [
            "skill_id": .stringSchema(description: "Exact loaded Skill ID"),
            "path": .stringSchema(description: "Skill-relative text resource path")
        ],
        required: ["skill_id", "path"]
    )
    let category = AgentToolCategory.filesystem
    let permissionLevel = AgentPermissionLevel.read
    let requiresNetwork = false
    let supportsParallelExecution = true
    let service: SkillService

    func isAvailable(in context: AgentToolContext) -> Bool {
        !context.loadedSkillIDs.isEmpty
    }

    func execute(
        arguments: JSONValue,
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let values = try ToolArguments(arguments)
        let skillID = values.string("skill_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = values.string("path")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !skillID.isEmpty, !path.isEmpty else {
            throw AgentRuntimeError.invalidArguments("skill_id 與 path 為必填")
        }
        let text = try await service.readResource(
            skillID: skillID,
            relativePath: path,
            allowedSkillIDs: context.loadedSkillIDs
        )
        let maximum = min(context.maximumToolResultCharacters, 48_000)
        let bounded = String(text.prefix(maximum))
        return AgentToolResult(
            content: bounded,
            truncated: bounded.count < text.count
        )
    }
}
