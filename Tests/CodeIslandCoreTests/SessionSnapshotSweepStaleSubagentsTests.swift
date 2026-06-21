import XCTest
@testable import CodeIslandCore

final class SessionSnapshotSweepStaleSubagentsTests: XCTestCase {
    func testCopilotParentStopSweepsTooluSubagents() throws {
        let sessionId = "B3F2F7E8-0D79-4F0D-A95D-1C3A9B25E3E1"
        var parent = SessionSnapshot()
        parent.source = "copilot"
        parent.status = .running
        parent.currentTool = "Agent"
        parent.toolDescription = "general-purpose"
        parent.subagents["toolu_abc"] = SubagentState(agentId: "toolu_abc", agentType: "general-purpose")
        var sessions = [sessionId: parent]
        let event = try decode([
            "hook_event_name": "agentStop",
            "session_id": sessionId,
            "_source": "copilot",
        ])

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(sessions[sessionId]?.subagents.isEmpty == true)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        XCTAssertNil(sessions[sessionId]?.currentTool)
        XCTAssertNil(sessions[sessionId]?.toolDescription)
        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: sessionId)))
    }

    func testCopilotParentStopPreservesNonTooluSubagents() throws {
        let sessionId = "A88E7D19-35D2-4B9E-B128-F5145E8C1D8A"
        var preserved = SubagentState(agentId: "subagent_123", agentType: "general-purpose")
        preserved.status = .processing
        preserved.currentTool = "Read"
        preserved.toolDescription = "Inspect files"
        var parent = SessionSnapshot()
        parent.source = "copilot"
        parent.status = .running
        parent.subagents["toolu_abc"] = SubagentState(agentId: "toolu_abc", agentType: "general-purpose")
        parent.subagents["subagent_123"] = preserved
        var sessions = [sessionId: parent]
        let event = try decode([
            "hook_event_name": "agentStop",
            "session_id": sessionId,
            "_source": "copilot",
        ])

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertNil(sessions[sessionId]?.subagents["toolu_abc"])
        XCTAssertEqual(sessions[sessionId]?.subagents.count, 1)
        XCTAssertEqual(sessions[sessionId]?.subagents["subagent_123"]?.agentType, "general-purpose")
        XCTAssertEqual(sessions[sessionId]?.subagents["subagent_123"]?.status, .processing)
        XCTAssertEqual(sessions[sessionId]?.subagents["subagent_123"]?.currentTool, "Read")
        XCTAssertEqual(sessions[sessionId]?.subagents["subagent_123"]?.toolDescription, "Inspect files")
    }

    func testCodexParentStopDoesNotSweepSubagents() throws {
        let sessionId = "9F1A9DF7-BFD6-4B5E-9D33-C8AE302B76A4"
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.subagents["toolu_abc"] = SubagentState(agentId: "toolu_abc", agentType: "default")
        parent.subagents["agent_foo"] = SubagentState(agentId: "agent_foo", agentType: "default")
        var sessions = [sessionId: parent]
        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": sessionId,
            "_source": "codex",
        ])

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertNotNil(sessions[sessionId]?.subagents["toolu_abc"])
        XCTAssertNotNil(sessions[sessionId]?.subagents["agent_foo"])
        let remainingKeys = Set(sessions[sessionId]?.subagents.keys.map { $0 } ?? [])
        XCTAssertEqual(remainingKeys, ["toolu_abc", "agent_foo"])
    }

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "SessionSnapshotSweepStaleSubagentsTests", code: 1)
        }
        return event
    }
}
