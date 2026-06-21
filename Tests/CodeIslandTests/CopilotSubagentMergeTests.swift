import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class CopilotSubagentRoutingTests: XCTestCase {
    private var savedPluginMode: Any?
    private var savedCopilotSubagentMode: Any?
    private var savedCopilotPermissionMode: Any?

    override func setUp() {
        super.setUp()
        savedPluginMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        savedCopilotSubagentMode = UserDefaults.standard.object(forKey: SettingsKey.copilotSubagentMode)
        savedCopilotPermissionMode = UserDefaults.standard.object(forKey: SettingsKey.copilotPermissionMode)
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.removeObject(forKey: SettingsKey.copilotSubagentMode)
        SettingsManager.shared.copilotPermissionMode = .headsUp
    }

    override func tearDown() {
        restore(savedPluginMode, forKey: SettingsKey.pluginSessionMode)
        restore(savedCopilotSubagentMode, forKey: SettingsKey.copilotSubagentMode)
        restore(savedCopilotPermissionMode, forKey: SettingsKey.copilotPermissionMode)
        super.tearDown()
    }

    func testDefaultMergeDoesNotCreateTopLevelTooluSession() async throws {
        let childId = "toolu_vrtx_child_default"
        let appState = appStateWithParent(source: "copilot", ppid: 4242)
        let server = HookServer(appState: appState)
        let payload = makePayload(sessionId: childId, source: "copilot", ppid: 4242)

        let routed = server.routeSubsessionPayloadIfNeeded(data: try data(from: payload))
        XCTAssertNil(routed.responseData)
        let event = try XCTUnwrap(HookEvent(from: routed.processedData))
        appState.handleEvent(event)

        XCTAssertNil(appState.sessions[childId])
        let parent = try XCTUnwrap(appState.sessions["parent"])
        XCTAssertEqual(parent.subagents.count, 1)
        XCTAssertEqual(parent.subagents[childId]?.currentTool, "shell")
    }

    func testMatchingParentRewritesCopilotSubagentFields() async throws {
        let childId = "toolu_vrtx_child_rewrite"
        let appState = appStateWithParent(source: "copilot", ppid: 5151)
        let server = HookServer(appState: appState)
        let payload = makePayload(sessionId: childId, source: "copilot", ppid: 5151, eventName: "pre_tool_use")

        let routed = server.routeSubsessionPayloadIfNeeded(data: try data(from: payload))
        let rewritten = try decodedObject(from: routed.processedData)

        XCTAssertNil(routed.responseData)
        XCTAssertEqual(rewritten["session_id"] as? String, "parent")
        XCTAssertEqual(rewritten["agent_id"] as? String, childId)
        XCTAssertEqual(rewritten["agent_type"] as? String, "Copilot")
        XCTAssertEqual(rewritten["_copilot_subagent"] as? Bool, true)
        XCTAssertEqual(rewritten["_copilot_subagent_session_id"] as? String, childId)
        XCTAssertEqual(rewritten["_copilot_subagent_event"] as? String, "PreToolUse")
        XCTAssertNil(rewritten["_codex_subagent"])
        XCTAssertNil(rewritten["_codex_subagent_session_id"])
        XCTAssertNil(rewritten["_codex_subagent_event"])
    }

    func testMissingParentDropsCopilotTooluPayload() async throws {
        let appState = AppState()
        let server = HookServer(appState: appState)
        let payload = makePayload(sessionId: "toolu_vrtx_missing_parent", source: "copilot", ppid: 6161)

        let routed = server.routeSubsessionPayloadIfNeeded(data: try data(from: payload))

        XCTAssertEqual(routed.responseData, Data("{}".utf8))
        XCTAssertTrue(appState.sessions.isEmpty)
    }

    func testHideModeSuppressesCopilotTooluPayload() async throws {
        UserDefaults.standard.set("hide", forKey: SettingsKey.copilotSubagentMode)
        let appState = appStateWithParent(source: "copilot", ppid: 6262)
        let server = HookServer(appState: appState)
        let payload = makePayload(sessionId: "toolu_vrtx_hidden", source: "copilot", ppid: 6262)

        let routed = server.routeSubsessionPayloadIfNeeded(data: try data(from: payload))

        XCTAssertEqual(routed.responseData, Data("{}".utf8))
    }

    func testLegacySeparateModeMergesCopilotTooluPayload() async throws {
        UserDefaults.standard.set("separate", forKey: SettingsKey.copilotSubagentMode)
        let childId = "toolu_vrtx_legacy_separate"
        let appState = appStateWithParent(source: "copilot", ppid: 6363)
        let server = HookServer(appState: appState)
        let payload = makePayload(sessionId: childId, source: "copilot", ppid: 6363)

        let routed = server.routeSubsessionPayloadIfNeeded(data: try data(from: payload))
        let rewritten = try decodedObject(from: routed.processedData)

        XCTAssertNil(routed.responseData)
        XCTAssertEqual(SettingsManager.shared.copilotSubagentMode, "merge")
        XCTAssertEqual(rewritten["session_id"] as? String, "parent")
        XCTAssertEqual(rewritten["_copilot_subagent"] as? Bool, true)
        XCTAssertEqual(rewritten["_copilot_subagent_session_id"] as? String, childId)
    }

    func testCopilotPermissionModeStillAppliesAfterSubagentRewrite() async throws {
        let childId = "toolu_vrtx_permission"
        let appState = appStateWithParent(source: "copilot", ppid: 6464)
        let server = HookServer(appState: appState)
        let payload = makePayload(
            sessionId: childId,
            source: "copilot",
            ppid: 6464,
            eventName: "PermissionRequest"
        )

        let routed = server.routeSubsessionPayloadIfNeeded(data: try data(from: payload))
        let event = try XCTUnwrap(HookEvent(from: routed.processedData))

        XCTAssertEqual(event.sessionId, "parent")
        XCTAssertEqual(event.agentId, childId)
        XCTAssertEqual(HookServer.permissionRouteAction(for: event, copilotPermissionMode: .intercept), .intercept)
        XCTAssertEqual(HookServer.permissionRouteAction(for: event, copilotPermissionMode: .headsUp), .providerPassthrough)
        XCTAssertEqual(HookServer.permissionRouteAction(for: event, copilotPermissionMode: .off), .providerPassthrough)
    }

    func testCopilotMergedSubagentPermissionPromptSetsClearBackFlagOnParent() async throws {
        let childId = "toolu_test_child"
        let appState = appStateWithParent(source: "copilot", ppid: 6868)
        let server = HookServer(appState: appState)
        var notificationPayload = makePayload(
            sessionId: childId,
            source: "copilot",
            ppid: 6868,
            eventName: "notification"
        )
        notificationPayload["notification_type"] = "permission_prompt"
        notificationPayload["message"] = "Allow child shell command?"

        let routed = server.routeSubsessionPayloadIfNeeded(data: try data(from: notificationPayload))
        let notification = try XCTUnwrap(HookEvent(from: routed.processedData))
        _ = reduceEvent(
            sessions: &appState.sessions,
            event: notification,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )

        XCTAssertNil(routed.responseData)
        XCTAssertEqual(notification.sessionId, "parent")
        XCTAssertEqual(notification.agentId, childId)
        XCTAssertNil(appState.sessions[childId])
        XCTAssertEqual(appState.sessions["parent"]?.status, .waitingApproval)
        XCTAssertEqual(appState.sessions["parent"]?.toolDescription, "Allow child shell command?")
        XCTAssertEqual(appState.sessions["parent"]?.waitingApprovalNeedsClearOnNextEvent, true)

        let parentPreToolUse = try XCTUnwrap(HookEvent(from: data(from: [
            "hook_event_name": "PreToolUse",
            "session_id": "parent",
            "tool_name": "shell",
            "tool_input": [
                "description": "List parent files",
                "command": "ls Sources",
            ],
            "_source": "copilot",
        ])))
        _ = reduceEvent(
            sessions: &appState.sessions,
            event: parentPreToolUse,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )

        XCTAssertEqual(appState.sessions["parent"]?.status, .running)
        XCTAssertEqual(appState.sessions["parent"]?.currentTool, "shell")
        XCTAssertEqual(appState.sessions["parent"]?.toolDescription, "ls Sources")
        XCTAssertEqual(appState.sessions["parent"]?.waitingApprovalNeedsClearOnNextEvent, false)
    }

    func testCodexNativeSubagentRoutingStillUsesCodexFields() async throws {
        let childId = "codex-child"
        let appState = appStateWithParent(source: "codex", ppid: 6565)
        let server = HookServer(appState: appState)
        let payload = makePayload(sessionId: childId, source: "codex", ppid: 6565)

        let routed = server.routeSubsessionPayloadIfNeeded(data: try data(from: payload))
        let rewritten = try decodedObject(from: routed.processedData)

        XCTAssertNil(routed.responseData)
        XCTAssertEqual(rewritten["session_id"] as? String, "parent")
        XCTAssertEqual(rewritten["_codex_subagent"] as? Bool, true)
        XCTAssertEqual(rewritten["_codex_subagent_session_id"] as? String, childId)
        XCTAssertNil(rewritten["_copilot_subagent"])
        XCTAssertNil(rewritten["_copilot_subagent_session_id"])
    }

    func testPluginRoutingStillUsesPluginSessionMode() async throws {
        UserDefaults.standard.set("hide", forKey: SettingsKey.copilotSubagentMode)
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        let appState = appStateWithParent(source: "opencode", ppid: 6666)
        let server = HookServer(appState: appState)
        var payload = makePayload(sessionId: "plugin-child", source: "opencode", ppid: 6666)
        payload["_via_plugin"] = true

        let routed = server.routeSubsessionPayloadIfNeeded(data: try data(from: payload))
        let rewritten = try decodedObject(from: routed.processedData)

        XCTAssertNil(routed.responseData)
        XCTAssertEqual(rewritten["session_id"] as? String, "parent")
        XCTAssertNil(rewritten["_copilot_subagent"])
    }

    func testTooluSessionFromNonCopilotSourcePassesThrough() async throws {
        let appState = appStateWithParent(source: "copilot", ppid: 6767)
        let server = HookServer(appState: appState)
        let cases: [(String?, String)] = [
            ("claude", "toolu_vrtx_claude"),
            ("codex", "toolu_vrtx_codex"),
            (nil, "toolu_vrtx_missing_source"),
        ]

        for (source, childId) in cases {
            let routed = server.routeSubsessionPayloadIfNeeded(
                data: try data(from: makePayload(sessionId: childId, source: source, ppid: 6767))
            )
            let decoded = try decodedObject(from: routed.processedData)
            XCTAssertNil(routed.responseData, "\(source ?? "nil") should pass through")
            XCTAssertEqual(decoded["session_id"] as? String, childId)
            XCTAssertNil(decoded["_copilot_subagent"])
        }
    }

    private func appStateWithParent(source: String, ppid: Int32) -> AppState {
        let appState = AppState()
        var parent = SessionSnapshot(startTime: Date(timeIntervalSince1970: 100))
        parent.source = source
        parent.status = .running
        parent.cliPid = ppid
        parent.lastActivity = Date()
        appState.sessions["parent"] = parent
        return appState
    }

    private func makePayload(
        sessionId: String,
        source: String?,
        ppid: Int,
        eventName: String = "PreToolUse"
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "hook_event_name": eventName,
            "session_id": sessionId,
            "tool_name": "shell",
            "tool_input": ["command": "pwd"],
            "cwd": "/repo",
            "_ppid": ppid,
        ]
        if let source {
            payload["_source"] = source
        }
        return payload
    }

    private func data(from payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload)
    }

    private func decodedObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

@MainActor
final class AppStateCopilotSubsessionTests: XCTestCase {
    private var savedCopilotSubagentMode: Any?

    override func setUp() {
        super.setUp()
        savedCopilotSubagentMode = UserDefaults.standard.object(forKey: SettingsKey.copilotSubagentMode)
        UserDefaults.standard.removeObject(forKey: SettingsKey.copilotSubagentMode)
    }

    override func tearDown() {
        if let savedCopilotSubagentMode {
            UserDefaults.standard.set(savedCopilotSubagentMode, forKey: SettingsKey.copilotSubagentMode)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.copilotSubagentMode)
        }
        super.tearDown()
    }

    func testKnownTooluSessionMergesIntoSamePidParent() async {
        let appState = AppState()
        var parent = SessionSnapshot(startTime: Date(timeIntervalSince1970: 100))
        parent.source = "copilot"
        parent.cliPid = 7777
        parent.status = .processing
        parent.lastActivity = Date()

        var child = SessionSnapshot(startTime: Date(timeIntervalSince1970: 200))
        child.source = "copilot"
        child.cliPid = 7777
        child.status = .running
        child.currentTool = "shell"
        child.toolDescription = "npm test"
        child.lastActivity = Date()

        appState.sessions["parent"] = parent
        appState.sessions["toolu_vrtx_known"] = child

        XCTAssertTrue(appState.applyCopilotSubagentModeToKnownSessions())

        XCTAssertNil(appState.sessions["toolu_vrtx_known"])
        XCTAssertEqual(appState.sessions["parent"]?.subagents["toolu_vrtx_known"]?.currentTool, "shell")
        XCTAssertEqual(appState.sessions["parent"]?.subagents["toolu_vrtx_known"]?.toolDescription, "npm test")
        XCTAssertEqual(appState.activeSessionId, "parent")
    }
}

@MainActor
final class CopilotSubagentModeTests: XCTestCase {
    private var savedCopilotSubagentMode: Any?
    private var savedPluginMode: Any?
    private var savedLanguage = "system"

    override func setUp() {
        super.setUp()
        savedCopilotSubagentMode = UserDefaults.standard.object(forKey: SettingsKey.copilotSubagentMode)
        savedPluginMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        restore(savedCopilotSubagentMode, forKey: SettingsKey.copilotSubagentMode)
        restore(savedPluginMode, forKey: SettingsKey.pluginSessionMode)
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    func testSettingDefaultsAndRoundTrips() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.copilotSubagentMode)
        UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
        XCTAssertEqual(SettingsManager.shared.copilotSubagentMode, "merge")
        XCTAssertEqual(SettingsDefaults.pluginSessionMode, "separate")

        for mode in ["merge", "hide"] {
            SettingsManager.shared.copilotSubagentMode = mode
            XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKey.copilotSubagentMode), mode)
            XCTAssertEqual(SettingsManager.shared.copilotSubagentMode, mode)
        }

        UserDefaults.standard.set("separate", forKey: SettingsKey.copilotSubagentMode)
        XCTAssertEqual(SettingsManager.shared.copilotSubagentMode, "merge")

        SettingsManager.shared.copilotSubagentMode = "separate"
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKey.copilotSubagentMode), "merge")
        XCTAssertEqual(SettingsManager.shared.copilotSubagentMode, "merge")

        UserDefaults.standard.set("unexpected", forKey: SettingsKey.copilotSubagentMode)
        XCTAssertEqual(SettingsManager.shared.copilotSubagentMode, "merge")
    }

    func testLocalizationKeysResolveForAllLanguages() {
        let keys = [
            "copilot_subagent_mode",
            "copilot_subagent_mode_desc",
            "copilot_subagent_mode_merge",
            "copilot_subagent_mode_hide",
        ]

        for language in ["en", "zh", "ja", "ko", "tr"] {
            L10n.shared.language = language
            for key in keys {
                let value = L10n.shared[key]
                XCTAssertNotEqual(value, key, "Missing \(key) for \(language)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    func testPersistenceCleanupDropsTooluEntriesOnLoad() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/codeisland-test-artifacts/CopilotSubagentMergeTests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("sessions.json")
        let now = Date()
        let persisted = [
            PersistedSession(
                sessionId: "parent",
                cwd: "/repo",
                source: "copilot",
                model: nil,
                sessionTitle: nil,
                sessionTitleSource: nil,
                providerSessionId: nil,
                lastUserPrompt: nil,
                lastAssistantMessage: nil,
                termApp: nil,
                itermSessionId: nil,
                ttyPath: nil,
                kittyWindowId: nil,
                tmuxPane: nil,
                tmuxClientTty: nil,
                tmuxEnv: nil,
                termBundleId: nil,
                cmuxSurfaceId: nil,
                cmuxWorkspaceId: nil,
                zellijPaneId: nil,
                zellijSessionName: nil,
                weztermPaneId: nil,
                cliPid: 8888,
                cliStartTime: nil,
                startTime: now,
                lastActivity: now
            ),
            PersistedSession(
                sessionId: "toolu_vrtx_persisted",
                cwd: "/repo",
                source: "copilot",
                model: nil,
                sessionTitle: nil,
                sessionTitleSource: nil,
                providerSessionId: nil,
                lastUserPrompt: nil,
                lastAssistantMessage: nil,
                termApp: nil,
                itermSessionId: nil,
                ttyPath: nil,
                kittyWindowId: nil,
                tmuxPane: nil,
                tmuxClientTty: nil,
                tmuxEnv: nil,
                termBundleId: nil,
                cmuxSurfaceId: nil,
                cmuxWorkspaceId: nil,
                zellijPaneId: nil,
                zellijSessionName: nil,
                weztermPaneId: nil,
                cliPid: 8888,
                cliStartTime: nil,
                startTime: now,
                lastActivity: now
            ),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(persisted).write(to: fileURL, options: .atomic)

        let loaded = SessionPersistence.load(from: fileURL)

        XCTAssertEqual(loaded.map(\.sessionId), ["parent"])
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
