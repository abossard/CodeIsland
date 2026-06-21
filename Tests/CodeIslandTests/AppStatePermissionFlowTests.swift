import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStatePermissionFlowTests: XCTestCase {
    private var savedCodexHome: String?
    private var savedAutoApproveTools: Set<String> = []

    override func setUp() {
        super.setUp()
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        savedAutoApproveTools = SettingsManager.shared.autoApproveTools
    }

    override func tearDown() {
        SettingsManager.shared.autoApproveTools = savedAutoApproveTools
        if let savedCodexHome {
            setenv("CODEX_HOME", savedCodexHome, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        super.tearDown()
    }

    func testDismissPermissionSkipsAlreadyDismissedSessions() async throws {
        let appState = AppState()

        let eventA = try makePermissionRequestEvent(sessionId: "s1", toolName: "Bash")
        let eventB = try makePermissionRequestEvent(sessionId: "s2", toolName: "Read")

        let responseTaskA = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(eventA, continuation: continuation)
            }
        }
        let responseTaskB = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(eventB, continuation: continuation)
            }
        }

        await Task.yield()

        XCTAssertEqual(appState.permissionQueue.count, 2)
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s1"))

        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s2"))
        XCTAssertEqual(appState.permissionQueue.count, 2)

        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 2)

        await assertTaskNotResolved(responseTaskA)
        await assertTaskNotResolved(responseTaskB)

        appState.handlePeerDisconnect(sessionId: "s1")
        appState.handlePeerDisconnect(sessionId: "s2")

        let responseA = await responseTaskA.value
        let responseB = await responseTaskB.value

        XCTAssertEqual(try extractPermissionBehavior(from: responseA), "deny")
        XCTAssertEqual(try extractPermissionBehavior(from: responseB), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testDismissSinglePermissionCollapsesAndKeepsPending() async throws {
        let appState = AppState()
        let sessionId = "s-single"
        let event = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Bash")

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }

        await Task.yield()

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: sessionId))
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval)

        appState.dismissPermissionPrompt()

        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval)

        await assertTaskNotResolved(responseTask)

        appState.handlePeerDisconnect(sessionId: sessionId)
        let response = await responseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "deny")
    }

    func testDismissedSessionGetsShownAgainWhenNewPermissionArrivesAfterDrain() async throws {
        let appState = AppState()
        let sessionId = "s-reappear"

        let firstEvent = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Edit")
        let firstResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(firstEvent, continuation: continuation)
            }
        }

        await Task.yield()
        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handlePeerDisconnect(sessionId: sessionId)
        let firstResponse = await firstResponseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: firstResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)

        let secondEvent = try makePermissionRequestEvent(sessionId: sessionId, toolName: "Write")
        let secondResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(secondEvent, continuation: continuation)
            }
        }

        await Task.yield()

        XCTAssertEqual(appState.surface, .approvalCard(sessionId: sessionId))
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.approvePermission()

        let secondResponse = await secondResponseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: secondResponse), "allow")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testBuddyApproveCommandResolvesPendingPermission() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(sessionId: "s-buddy-approve", toolName: "Bash")

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handleBuddyControlCommand(.approveCurrentPermission)

        let response = await responseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testBuddyDenyCommandResolvesPendingPermission() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(sessionId: "s-buddy-deny", toolName: "Bash")

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.handleBuddyControlCommand(.denyCurrentPermission)

        let response = await responseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPendingApprovalPreviewSplitsLongDescriptionAcrossMultipleWatchFrames() async throws {
        let appState = AppState()
        let sessionId = "s-buddy-preview"
        let description = "Allow npm run build --filter watch package and update generated artifacts before merge"
        let command = "npm run build --filter watch -- --mode production"
        let expectedDetail = "\(description)\nCommand:\n\(command)"
        let event = try makePermissionRequestEvent(
            sessionId: sessionId,
            toolName: "Bash",
            toolInput: [
                "description": description,
                "command": command
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }

        await Task.yield()

        let previews = appState.esp32MessagePreviewPayloads()
        XCTAssertGreaterThan(previews.count, 1)
        XCTAssertTrue(previews.allSatisfy { ($0.text ?? "").utf8.count <= ESP32Protocol.maxMessagePreviewBytes })
        XCTAssertEqual(previews.map(\.total).last, UInt8(previews.count))
        XCTAssertEqual(previews.compactMap(\.text).joined(), expectedDetail)

        appState.handlePeerDisconnect(sessionId: sessionId)
        _ = await responseTask.value
    }

    func testInteractiveDeliveryKeyChangesWhenApprovalDescriptionChanges() {
        let appState = AppState()
        let first = appState.esp32MessagePreviewSegments(text: "Need approval for npm run build --filter watch")
        let second = appState.esp32MessagePreviewSegments(text: "Need approval for npm run build --filter watch and package")

        XCTAssertNotEqual(first.joined(separator: "|"), second.joined(separator: "|"))
    }

    func testCopilotAlwaysAllowPersistsAutoApproveToolOnlyForCopilot() async throws {
        SettingsManager.shared.autoApproveTools = ["TaskList"]
        let appState = AppState()
        let copilotEvent = try makePermissionRequestEvent(
            sessionId: "s-copilot-always-allow",
            toolName: "shell",
            source: "copilot"
        )

        let copilotResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(copilotEvent, continuation: continuation)
            }
        }

        await Task.yield()
        appState.approvePermission(always: true)

        let copilotDecision = try extractPermissionDecision(from: await copilotResponseTask.value)
        XCTAssertEqual(copilotDecision["behavior"] as? String, "allow")
        XCTAssertNil(copilotDecision["updatedPermissions"])
        XCTAssertEqual(SettingsManager.shared.autoApproveTools, ["TaskList", "copilot:shell"])

        let claudeEvent = try makePermissionRequestEvent(
            sessionId: "s-claude-always-allow",
            toolName: "Bash"
        )
        let claudeResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(claudeEvent, continuation: continuation)
            }
        }

        await Task.yield()
        appState.approvePermission(always: true)

        let claudeDecision = try extractPermissionDecision(from: await claudeResponseTask.value)
        XCTAssertEqual(claudeDecision["behavior"] as? String, "allow")
        XCTAssertNotNil(claudeDecision["updatedPermissions"])
        XCTAssertFalse(SettingsManager.shared.autoApproveTools.contains("Bash"))
    }

    func testQueuedPermissionRequestStillBlocksToolEvents() async throws {
        let appState = AppState()
        let sessionId = "s-copilot-intercept"
        let permission = try makePermissionRequestEvent(
            sessionId: sessionId,
            toolName: "Bash",
            toolInput: [
                "description": "Approve intercepted install",
                "command": "npm install"
            ],
            source: "copilot"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(permission, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval)
        XCTAssertEqual(appState.sessions[sessionId]?.currentTool, "Bash")
        XCTAssertEqual(appState.sessions[sessionId]?.toolDescription, "Approve intercepted install\nCommand:\nnpm install")

        appState.handleEvent(try makeToolEvent(
            name: "PreToolUse",
            sessionId: sessionId,
            toolName: "Bash",
            toolInput: [
                "description": "Later provider-owned command",
                "command": "whoami"
            ],
            source: "copilot"
        ))
        appState.handleEvent(try makeToolEvent(
            name: "PostToolUse",
            sessionId: sessionId,
            toolName: "Bash",
            toolInput: ["command": "whoami"],
            source: "copilot"
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.sessions[sessionId]?.status, .waitingApproval)
        XCTAssertEqual(appState.sessions[sessionId]?.currentTool, "Bash")
        XCTAssertEqual(appState.sessions[sessionId]?.toolDescription, "Approve intercepted install\nCommand:\nnpm install")
        await assertTaskNotResolved(responseTask)

        appState.approvePermission()
        let response = await responseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testCopilotAlwaysAllowDoesNotLeakToClaudeAutoApprove() async throws {
        SettingsManager.shared.autoApproveTools = []
        let appState = AppState()
        let copilotEvent = try makePermissionRequestEvent(
            sessionId: "s-copilot-isolated-always-allow",
            toolName: "shell",
            source: "copilot"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(copilotEvent, continuation: continuation)
            }
        }

        await Task.yield()
        appState.approvePermission(always: true)

        let decision = try extractPermissionDecision(from: await responseTask.value)
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertTrue(SettingsManager.shared.autoApproveTools.contains("copilot:shell"))
        XCTAssertFalse(HookServer.shouldAutoApprove(toolName: "shell", source: "claude"))
        XCTAssertFalse(HookServer.shouldAutoApprove(toolName: "shell", source: nil))
        XCTAssertTrue(HookServer.shouldAutoApprove(toolName: "shell", source: "copilot"))
    }

    func testAutoApproveNamespacedEntriesDoNotLeakAndLegacyEntriesStillMatch() {
        SettingsManager.shared.autoApproveTools = ["shell"]
        XCTAssertTrue(HookServer.shouldAutoApprove(toolName: "shell", source: "copilot"))
        XCTAssertTrue(HookServer.shouldAutoApprove(toolName: "shell", source: "claude"))
        XCTAssertTrue(HookServer.shouldAutoApprove(toolName: "shell", source: nil))

        SettingsManager.shared.autoApproveTools = ["copilot:shell"]
        XCTAssertTrue(HookServer.shouldAutoApprove(toolName: "shell", source: "copilot"))
        XCTAssertFalse(HookServer.shouldAutoApprove(toolName: "shell", source: "claude"))
        XCTAssertFalse(HookServer.shouldAutoApprove(toolName: "shell", source: "codex"))
        XCTAssertFalse(HookServer.shouldAutoApprove(toolName: "shell", source: nil))
    }

    func testAutoApproveToolEntryFallsBackToLegacyWhenSourceMissing() {
        XCTAssertEqual(AppState.autoApproveToolEntry(toolName: "shell", source: nil), "shell")
        XCTAssertEqual(AppState.autoApproveToolEntry(toolName: "shell", source: "unknown-cli"), "shell")
        XCTAssertEqual(AppState.autoApproveToolEntry(toolName: "shell", source: "copilot"), "copilot:shell")
    }

    func testCodexAlwaysAllowPersistsRuleWithoutUnsupportedUpdatedPermissions() async throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-always-allow",
            toolName: "Bash",
            toolInput: [
                "command": "php vendor/bin/phpstan analyse $(git diff --name-only origin/master...HEAD | rg '\\.php$' | tr '\\n' ' ' )"
            ],
            source: "codex"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.approvePermission(always: true)

        let decision = try extractPermissionDecision(from: await responseTask.value)
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNil(decision["updatedPermissions"])

        let rules = try readCodeIslandRules(in: codexHome)
        XCTAssertTrue(rules.contains(#"pattern = ["php", "vendor/bin/phpstan", "analyse"]"#))
        XCTAssertTrue(rules.contains(#"decision = "allow""#))
    }

    /// #224: "Always allow" for an MCP tool (`mcp__server__tool`) must emit a
    /// bare-tool-name rule with NO `ruleContent` specifier. Claude Code's MCP
    /// permission rules don't take a specifier; sending `ruleContent: "*"`
    /// assembles `mcp__server__tool(*)`, which never matches a real MCP call, so
    /// the rule silently fails to persist and the same approval re-prompts.
    func testAlwaysAllowMCPToolOmitsRuleSpecifier() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-mcp-always",
            toolName: "mcp__sh_wiki__fetch_page",
            toolInput: ["page_id": "432458668"]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.approvePermission(always: true)

        let rule = try firstAlwaysAllowRule(from: await responseTask.value)
        XCTAssertEqual(rule["toolName"] as? String, "mcp__sh_wiki__fetch_page")
        XCTAssertNil(rule["ruleContent"], "MCP tool rules must not carry a specifier (#224)")
    }

    /// Non-MCP tools keep the wildcard specifier so "always allow" still applies
    /// to every future call of that tool. The #224 fix must not change them.
    func testAlwaysAllowNonMCPToolKeepsWildcardSpecifier() async throws {
        let appState = AppState()
        let event = try makePermissionRequestEvent(
            sessionId: "s-bash-always",
            toolName: "Bash"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.approvePermission(always: true)

        let rule = try firstAlwaysAllowRule(from: await responseTask.value)
        XCTAssertEqual(rule["toolName"] as? String, "Bash")
        XCTAssertEqual(rule["ruleContent"] as? String, "*")
    }

    func testCodexAlwaysAllowDoesNotDuplicateExistingCodeIslandRule() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-dedupe",
            toolName: "Bash",
            toolInput: ["command": "npm run build -- --mode production"],
            source: "codex"
        )

        let rules = CodexPermissionRules()
        XCTAssertTrue(rules.persistAlwaysAllowRule(for: event))
        XCTAssertTrue(rules.persistAlwaysAllowRule(for: event))

        let contents = try readCodeIslandRules(in: codexHome)
        XCTAssertEqual(contents.components(separatedBy: #"pattern = ["npm", "run", "build"]"#).count - 1, 1)
    }

    func testCodexAutoReviewConfigDefersPermissionRequestToCodex() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try #"approvals_reviewer = "auto_review""#
            .write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-auto-review",
            toolName: "Bash",
            source: "codex"
        )

        XCTAssertTrue(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testCodexAutoReviewConfigDoesNotDeferAskUserQuestion() throws {
        let codexHome = makeTemporaryCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try #"approvals_reviewer = "guardian_subagent""#
            .write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let event = try makePermissionRequestEvent(
            sessionId: "s-codex-question",
            toolName: "AskUserQuestion",
            toolInput: ["question": "Continue?", "options": ["Yes", "No"]],
            source: "codex"
        )

        XCTAssertFalse(HookServer.shouldDeferPermissionRequestToProvider(event))
    }

    func testCodexProfileAutoReviewConfigIsDetected() throws {
        let config = """
        profile = "work"
        approvals_reviewer = "user"

        [profiles.work]
        approvals_reviewer = "auto_review"
        """

        XCTAssertTrue(CodexPermissionRules.configEnablesAutoReview(config))
    }

    func testCodexUserReviewerConfigDoesNotDefer() throws {
        let config = """
        approvals_reviewer = "user"

        [profiles.work]
        approvals_reviewer = "auto_review"
        """

        XCTAssertFalse(CodexPermissionRules.configEnablesAutoReview(config))
    }

    // MARK: - Helpers

    private func makeTemporaryCodexHome() -> URL {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        setenv("CODEX_HOME", codexHome.path, 1)
        return codexHome
    }

    private func codeIslandRulesPath(in codexHome: URL) -> URL {
        codexHome
            .appendingPathComponent("rules", isDirectory: true)
            .appendingPathComponent("codeisland.rules")
    }

    private func readCodeIslandRules(in codexHome: URL) throws -> String {
        try String(contentsOf: codeIslandRulesPath(in: codexHome), encoding: .utf8)
    }

    private func makePermissionRequestEvent(
        sessionId: String,
        toolName: String,
        toolInput: [String: Any] = ["command": "echo test"],
        source: String? = nil
    ) throws -> HookEvent {
        try makeToolEvent(
            name: "PermissionRequest",
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            source: source
        )
    }

    private func makeToolEvent(
        name: String,
        sessionId: String,
        toolName: String,
        toolInput: [String: Any],
        source: String? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId,
            "tool_name": toolName,
            "tool_input": toolInput
        ]
        if let source {
            payload["_source"] = source
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStatePermissionFlowTests", code: 1)
        }
        return event
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let decision = try extractPermissionDecision(from: responseData)
        return try XCTUnwrap(decision["behavior"] as? String)
    }

    private func extractPermissionDecision(from responseData: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        return try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
    }

    private func firstAlwaysAllowRule(from responseData: Data) throws -> [String: Any] {
        let decision = try extractPermissionDecision(from: responseData)
        let updated = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        let first = try XCTUnwrap(updated.first)
        let rules = try XCTUnwrap(first["rules"] as? [[String: Any]])
        return try XCTUnwrap(rules.first)
    }

    private func assertTaskNotResolved(_ task: Task<Data, Never>, timeout: TimeInterval = 0.05) async {
        let exp = expectation(description: "task should stay pending")
        exp.isInverted = true

        Task {
            _ = await task.value
            exp.fulfill()
        }

        await fulfillment(of: [exp], timeout: timeout)
    }
}
