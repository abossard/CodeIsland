import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class CopilotPermissionModeTests: XCTestCase {
    private var savedModeRaw: String?
    private var savedAutoApproveTools: Set<String> = []
    private var savedLanguage = "system"

    override func setUp() {
        super.setUp()
        savedModeRaw = UserDefaults.standard.string(forKey: SettingsKey.copilotPermissionMode)
        savedAutoApproveTools = SettingsManager.shared.autoApproveTools
        savedLanguage = L10n.shared.language
        SettingsManager.shared.autoApproveTools = []
        SettingsManager.shared.copilotPermissionMode = .headsUp
    }

    override func tearDown() {
        SettingsManager.shared.autoApproveTools = savedAutoApproveTools
        if let savedModeRaw {
            UserDefaults.standard.set(savedModeRaw, forKey: SettingsKey.copilotPermissionMode)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.copilotPermissionMode)
        }
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    func testCopilotInterceptPermissionRequestsRouteToExistingPermissionUI() throws {
        let event = try makePermissionRequestEvent(source: "copilot")

        let action = HookServer.permissionRouteAction(for: event, copilotPermissionMode: .intercept)

        XCTAssertEqual(action, .intercept)
        XCTAssertNil(action.immediateResponse)
    }

    func testCopilotHeadsUpPermissionRequestsPassThroughToProvider() throws {
        SettingsManager.shared.autoApproveTools = ["copilot:shell"]
        let event = try makePermissionRequestEvent(source: "copilot")

        let action = HookServer.permissionRouteAction(for: event, copilotPermissionMode: .headsUp)

        XCTAssertEqual(action, .providerPassthrough)
        XCTAssertEqual(action.immediateResponse, Data("{}".utf8))
    }

    func testCopilotHeadsUpPermissionPromptNotificationShowsWaitingApprovalAndMessage() throws {
        var session = SessionSnapshot()
        session.source = "copilot"
        session.status = .running
        var sessions = ["copilot-session": session]
        let event = try makeNotificationEvent(
            notificationType: "permission_prompt",
            message: "Allow npm install?"
        )

        _ = reduceEvent(
            sessions: &sessions,
            event: event,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )

        XCTAssertEqual(sessions["copilot-session"]?.status, .waitingApproval)
        XCTAssertEqual(sessions["copilot-session"]?.toolDescription, "Allow npm install?")
        XCTAssertEqual(sessions["copilot-session"]?.waitingApprovalNeedsClearOnNextEvent, true)
    }

    func testCopilotHeadsUpWaitingApprovalClearsOnNextPreToolUse() throws {
        var session = SessionSnapshot()
        session.source = "copilot"
        session.status = .running
        var sessions = ["copilot-session": session]
        let notification = try makeNotificationEvent(
            notificationType: "permission_prompt",
            message: "Allow stale install?"
        )
        let preToolUse = try makeToolEvent(
            name: "PreToolUse",
            toolName: "Bash",
            toolInput: [
                "description": "List package files",
                "command": "ls Sources"
            ],
            source: "copilot"
        )

        _ = reduceEvent(
            sessions: &sessions,
            event: notification,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )
        _ = reduceEvent(
            sessions: &sessions,
            event: preToolUse,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )

        XCTAssertEqual(sessions["copilot-session"]?.status, .running)
        XCTAssertEqual(sessions["copilot-session"]?.currentTool, "Bash")
        XCTAssertEqual(sessions["copilot-session"]?.toolDescription, "List package files\nCommand:\nls Sources")
        XCTAssertEqual(sessions["copilot-session"]?.waitingApprovalNeedsClearOnNextEvent, false)
    }

    func testCopilotHeadsUpWaitingApprovalClearsOnNextPostToolUse() throws {
        var session = SessionSnapshot()
        session.source = "copilot"
        session.status = .running
        var sessions = ["copilot-session": session]
        let notification = try makeNotificationEvent(
            notificationType: "permission_prompt",
            message: "Allow stale install?"
        )
        let postToolUse = try makeToolEvent(
            name: "PostToolUse",
            toolName: "Bash",
            toolInput: ["command": "npm test"],
            source: "copilot"
        )

        _ = reduceEvent(
            sessions: &sessions,
            event: notification,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )
        _ = reduceEvent(
            sessions: &sessions,
            event: postToolUse,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )

        XCTAssertEqual(sessions["copilot-session"]?.status, .processing)
        XCTAssertNil(sessions["copilot-session"]?.currentTool)
        XCTAssertNil(sessions["copilot-session"]?.toolDescription)
        XCTAssertEqual(sessions["copilot-session"]?.waitingApprovalNeedsClearOnNextEvent, false)
    }

    func testCopilotHeadsUpWaitingApprovalClearsOnUserPromptSubmit() throws {
        var session = SessionSnapshot()
        session.source = "copilot"
        session.status = .running
        var sessions = ["copilot-session": session]
        let notification = try makeNotificationEvent(
            notificationType: "permission_prompt",
            message: "Allow stale install?"
        )
        let prompt = try makeUserPromptSubmitEvent(prompt: "Continue after provider prompt")

        _ = reduceEvent(
            sessions: &sessions,
            event: notification,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )
        _ = reduceEvent(
            sessions: &sessions,
            event: prompt,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )

        XCTAssertEqual(sessions["copilot-session"]?.status, .processing)
        XCTAssertNil(sessions["copilot-session"]?.currentTool)
        XCTAssertNil(sessions["copilot-session"]?.toolDescription)
        XCTAssertEqual(sessions["copilot-session"]?.lastUserPrompt, "Continue after provider prompt")
        XCTAssertEqual(sessions["copilot-session"]?.waitingApprovalNeedsClearOnNextEvent, false)
    }

    func testCopilotInterceptWaitingApprovalDoesNotClearOnNextPreToolUse() throws {
        var session = SessionSnapshot()
        session.source = "copilot"
        session.status = .waitingApproval
        session.currentTool = "Bash"
        session.toolDescription = "Allow pending intercepted command?"
        var sessions = ["copilot-session": session]
        let preToolUse = try makeToolEvent(
            name: "PreToolUse",
            toolName: "Bash",
            toolInput: [
                "description": "Unexpected later tool",
                "command": "whoami"
            ],
            source: "copilot"
        )

        _ = reduceEvent(
            sessions: &sessions,
            event: preToolUse,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )

        XCTAssertEqual(sessions["copilot-session"]?.status, .waitingApproval)
        XCTAssertEqual(sessions["copilot-session"]?.currentTool, "Bash")
        XCTAssertEqual(sessions["copilot-session"]?.toolDescription, "Allow pending intercepted command?")
        XCTAssertEqual(sessions["copilot-session"]?.waitingApprovalNeedsClearOnNextEvent, false)
    }

    func testHeadsUpClearBackDoesNotAffectNonCopilotWaitingSessions() throws {
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .waitingApproval
        session.currentTool = "Bash"
        session.toolDescription = "Allow Claude command?"
        var sessions = ["copilot-session": session]
        let preToolUse = try makeToolEvent(
            name: "PreToolUse",
            toolName: "Bash",
            toolInput: [
                "description": "New Claude command",
                "command": "pwd"
            ],
            source: "claude"
        )

        _ = reduceEvent(
            sessions: &sessions,
            event: preToolUse,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: true
        )

        XCTAssertEqual(sessions["copilot-session"]?.status, .waitingApproval)
        XCTAssertEqual(sessions["copilot-session"]?.currentTool, "Bash")
        XCTAssertEqual(sessions["copilot-session"]?.toolDescription, "Allow Claude command?")
        XCTAssertEqual(sessions["copilot-session"]?.waitingApprovalNeedsClearOnNextEvent, false)
    }

    func testCopilotOffPermissionRequestsPassThroughWithoutPermissionUI() throws {
        SettingsManager.shared.autoApproveTools = ["copilot:shell"]
        let event = try makePermissionRequestEvent(source: "copilot")

        let action = HookServer.permissionRouteAction(for: event, copilotPermissionMode: .off)

        XCTAssertEqual(action, .providerPassthrough)
        XCTAssertEqual(action.immediateResponse, Data("{}".utf8))
    }

    func testCopilotOffPermissionPromptNotificationDoesNotChangeStatusOrMessage() throws {
        var session = SessionSnapshot()
        session.source = "copilot"
        session.status = .running
        session.toolDescription = "Still running shell"
        var sessions = ["copilot-session": session]
        let event = try makeNotificationEvent(
            notificationType: "permission_prompt",
            message: "Allow rm -rf build?"
        )

        _ = reduceEvent(
            sessions: &sessions,
            event: event,
            maxHistory: 10,
            showCopilotPermissionPromptNotifications: false
        )

        XCTAssertEqual(sessions["copilot-session"]?.status, .running)
        XCTAssertEqual(sessions["copilot-session"]?.toolDescription, "Still running shell")
        XCTAssertEqual(sessions["copilot-session"]?.waitingApprovalNeedsClearOnNextEvent, false)
    }

    func testSettingRoundTripsValidModesAndFallsBackForInvalidOrMissingValues() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.copilotPermissionMode)
        XCTAssertEqual(SettingsManager.shared.copilotPermissionMode, .headsUp)

        for mode in CopilotPermissionMode.allCases {
            SettingsManager.shared.copilotPermissionMode = mode
            XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKey.copilotPermissionMode), mode.rawValue)
            XCTAssertEqual(SettingsManager.shared.copilotPermissionMode, mode)
        }

        UserDefaults.standard.set("surprise", forKey: SettingsKey.copilotPermissionMode)
        XCTAssertEqual(SettingsManager.shared.copilotPermissionMode, .headsUp)
    }

    func testNonCopilotPermissionRoutingIgnoresCopilotMode() throws {
        let sources = ["claude", "codex", "trae", "kimi"]

        for mode in CopilotPermissionMode.allCases {
            for source in sources {
                let event = try makePermissionRequestEvent(source: source)
                XCTAssertEqual(
                    HookServer.permissionRouteAction(for: event, copilotPermissionMode: mode),
                    .intercept,
                    "\(source) should keep existing route while Copilot mode is \(mode.rawValue)"
                )
            }
        }
    }

    func testCopilotAskUserQuestionRoutesToQuestionBarInEveryMode() throws {
        let event = try makePermissionRequestEvent(toolName: "AskUserQuestion", source: "copilot")

        for mode in CopilotPermissionMode.allCases {
            XCTAssertEqual(
                HookServer.permissionRouteAction(for: event, copilotPermissionMode: mode),
                .askUserQuestion,
                "AskUserQuestion must bypass Copilot permission mode \(mode.rawValue)"
            )
        }
    }

    func testLocalizationKeysResolveForAllLanguages() {
        let keys = [
            "copilot_permission_mode",
            "copilot_permission_mode_desc",
            "copilot_permission_mode_intercept",
            "copilot_permission_mode_headsUp",
            "copilot_permission_mode_off",
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

    func testInterceptModeCopilotAutoApproveUsesNamespacedEntryWithoutLeakingToOtherCLIs() throws {
        SettingsManager.shared.autoApproveTools = ["copilot:shell"]
        let copilotEvent = try makePermissionRequestEvent(source: "copilot")
        let claudeEvent = try makePermissionRequestEvent(source: "claude")

        XCTAssertEqual(
            HookServer.permissionRouteAction(for: copilotEvent, copilotPermissionMode: .intercept),
            .autoApprove
        )
        XCTAssertTrue(HookServer.shouldAutoApprove(toolName: "shell", source: "copilot"))
        XCTAssertFalse(HookServer.shouldAutoApprove(toolName: "shell", source: "claude"))
        XCTAssertEqual(
            HookServer.permissionRouteAction(for: claudeEvent, copilotPermissionMode: .intercept),
            .intercept
        )
    }

    private func makePermissionRequestEvent(
        toolName: String = "shell",
        source: String
    ) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "copilot-session",
            "tool_name": toolName,
            "tool_input": ["command": "echo test"],
            "_source": source,
        ]
        return try decodeHookEvent(payload)
    }

    private func makeNotificationEvent(
        notificationType: String,
        message: String,
        source: String = "copilot"
    ) throws -> HookEvent {
        try decodeHookEvent([
            "hook_event_name": "notification",
            "session_id": "copilot-session",
            "_source": source,
            "notification_type": notificationType,
            "message": message,
        ])
    }

    private func makeToolEvent(
        name: String,
        toolName: String,
        toolInput: [String: Any],
        source: String
    ) throws -> HookEvent {
        try decodeHookEvent([
            "hook_event_name": name,
            "session_id": "copilot-session",
            "tool_name": toolName,
            "tool_input": toolInput,
            "_source": source,
        ])
    }

    private func makeUserPromptSubmitEvent(prompt: String) throws -> HookEvent {
        try decodeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "copilot-session",
            "_source": "copilot",
            "prompt": prompt,
        ])
    }

    private func decodeHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "CopilotPermissionModeTests", code: 1)
        }
        return event
    }
}
