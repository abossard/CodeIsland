import XCTest
@testable import CodeIslandCore

final class SessionSnapshotReplyCompletePlaceholderTests: XCTestCase {
    func testReplyCompleteFallbackUsesInjectedPlaceholder() throws {
        struct Case {
            let name: String
            let eventName: String
            let source: String
            let expectedStatus: AgentStatus
        }

        let cases = [
            Case(name: "stop", eventName: "agentStop", source: "copilot", expectedStatus: .idle),
            Case(name: "task round complete", eventName: "TaskComplete", source: "cline", expectedStatus: .idle),
        ]

        for testCase in cases {
            let sessionId = "reply-\(testCase.name.replacingOccurrences(of: " ", with: "-"))"
            let placeholder = "TEST_PLACEHOLDER_\(testCase.name)"
            var session = SessionSnapshot()
            session.source = testCase.source
            session.addRecentMessage(ChatMessage(isUser: true, text: "Please summarize this."))
            var sessions = [sessionId: session]
            let event = try decode([
                "hook_event_name": testCase.eventName,
                "session_id": sessionId,
                "_source": testCase.source,
            ])

            _ = reduceEvent(
                sessions: &sessions,
                event: event,
                maxHistory: 10,
                replyCompletePlaceholder: placeholder
            )

            XCTAssertEqual(sessions[sessionId]?.status, testCase.expectedStatus, testCase.name)
            XCTAssertEqual(sessions[sessionId]?.recentMessages.last?.isUser, false, testCase.name)
            XCTAssertEqual(sessions[sessionId]?.recentMessages.last?.text, placeholder, testCase.name)
            XCTAssertFalse(sessions[sessionId]?.recentMessages.contains { $0.text == "[回复完成]" } ?? true, testCase.name)
        }
    }

    func testReplyCompletePlaceholderIsNotUsedWhenAssistantTextExists() throws {
        let sessionId = "reply-with-text"
        let placeholder = "TEST_PLACEHOLDER"
        var session = SessionSnapshot()
        session.source = "copilot"
        session.addRecentMessage(ChatMessage(isUser: true, text: "Please summarize this."))
        var sessions = [sessionId: session]
        let event = try decode([
            "hook_event_name": "agentStop",
            "session_id": sessionId,
            "_source": "copilot",
            "last_assistant_message": "Done with summary.",
        ])

        _ = reduceEvent(
            sessions: &sessions,
            event: event,
            maxHistory: 10,
            replyCompletePlaceholder: placeholder
        )

        XCTAssertEqual(sessions[sessionId]?.lastAssistantMessage, "Done with summary.")
        XCTAssertEqual(sessions[sessionId]?.recentMessages.last?.text, "Done with summary.")
        XCTAssertFalse(sessions[sessionId]?.recentMessages.contains { $0.text == placeholder } ?? true)
    }

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "SessionSnapshotReplyCompletePlaceholderTests", code: 1)
        }
        return event
    }
}
