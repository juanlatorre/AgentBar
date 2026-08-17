import SwiftUI

extension Notification.Name {
    static let limitsChanged = Notification.Name("AgentBarLimitsChanged")
    static let notificationsSettingsChanged = Notification.Name("AgentBarNotificationsSettingsChanged")
    static let usageHistoryChanged = Notification.Name("AgentBarUsageHistoryChanged")
}

struct SettingsView: View {
    @AppStorage("launchAtLogin") var launchAtLogin = true
    @AppStorage("refreshInterval") var refreshInterval: Double = 60
    @AppStorage("notificationsEnabled") var notificationsEnabled = false
    @AppStorage("notificationTaskCompletedEnabled") var notificationTaskCompletedEnabled = true
    @AppStorage("notificationInputRequiredEnabled") var notificationInputRequiredEnabled = true
    @AppStorage("notificationCodexEventsEnabled") var notificationCodexEventsEnabled = true
    @AppStorage("notificationClaudeHookEventsEnabled") var notificationClaudeHookEventsEnabled = true
    @AppStorage("notificationOpencodeHookEventsEnabled") var notificationOpencodeHookEventsEnabled = true
    @AppStorage("notificationShowMessagePreview") var notificationShowMessagePreview = false
    @AppStorage(NotificationSoundMode.defaultsKey) var notificationSoundMode = NotificationSoundMode.system.rawValue
    #if AGENTBAR_NOTIFICATION_SOUNDS
    @AppStorage("notificationSoundPackPath") var notificationSoundPackPath: String = ""
    @AppStorage("notificationSoundVolume") var notificationSoundVolume: Double = 0.7
    #endif

    @AppStorage("claudeEnabled") var claudeEnabled = true
    @AppStorage("claudePlan") var claudePlan: String = ClaudePlan.pro.rawValue

    @AppStorage("codexEnabled") var codexEnabled = true
    @AppStorage("codexPlan") var codexPlan: String = CodexPlan.pro.rawValue
    @AppStorage("codexWeeklyLimit") var codexWeeklyLimit: Double = 100_000_000

    @AppStorage("geminiEnabled") var geminiEnabled = true
    @AppStorage("geminiDailyLimit") var geminiDailyLimit: Double = 1_000

    @AppStorage("copilotEnabled") var copilotEnabled = true
    @AppStorage(CopilotCredentialSettings.manualPATEnabledKey) var copilotManualPATEnabled = false

    @AppStorage("cursorEnabled") var cursorEnabled = true
    @AppStorage("cursorPlan") var cursorPlan: String = CursorPlan.pro.rawValue
    @AppStorage("cursorMonthlyLimit") var cursorMonthlyLimit: Double = 500

    @AppStorage("opencodeGoEnabled") var opencodeGoEnabled = true

    @AppStorage("zaiEnabled") var zaiEnabled = true
    @AppStorage("cmdEnabled") var cmdEnabled = true

    @State var selectedTab: SettingsTab = .usage
    #if AGENTBAR_NOTIFICATION_SOUNDS
    @State var showingSoundPackHelp = false
    @StateObject var soundPackVM = SoundPackViewModel()
    #endif
    @State var showingAgentSourcesHelp = false
    @State var copilotPAT: String = ""
    @State var hasSavedCopilotPAT = false
    @State var zaiAPIKey: String = ""
    @State var hasSavedZaiAPIKey = false
    @State var hookConfigurationStatus: AgentHookConfigurationStatus = .unknown
    @State var activeTokenSaveAlert: TokenSaveAlert?
    private let keychainSaveAction: @Sendable (String, String) throws -> Void

    init(
        keychainSaveAction: @escaping @Sendable (String, String) throws -> Void = { key, account in
            try KeychainManager.save(key: key, account: account)
        }
    ) {
        self.keychainSaveAction = keychainSaveAction
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            usageTab
                .tabItem { Label("Usage", systemImage: "chart.bar") }
                .tag(SettingsTab.usage)

            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)

            historyTab
                .tabItem { Label("History", systemImage: "calendar") }
                .tag(SettingsTab.history)
        }
        .frame(width: 450, height: 750)
        .onAppear {
            migrateLegacyClaudePlanIfNeeded()
            migrateLegacyCursorPlanIfNeeded()
            sanitizeNotificationSoundModeIfNeeded()
            migrateLegacyCopilotManualPATIfNeeded()
            loadAPIKeys()
            refreshHookConfigurationStatus()
        }
        .alert(item: $activeTokenSaveAlert) { alert in
            switch alert {
            case .saved:
                return Alert(
                    title: Text("Saved"),
                    dismissButton: .cancel(Text("OK"))
                )
            case .saveFailed(let message):
                return Alert(
                    title: Text("Save Failed"),
                    message: Text(message),
                    dismissButton: .cancel(Text("OK"))
                )
            }
        }
        #if AGENTBAR_NOTIFICATION_SOUNDS
        .sheet(isPresented: $showingSoundPackHelp) {
            SoundPackHelpSheet()
        }
        #endif
        .sheet(isPresented: $showingAgentSourcesHelp) {
            AgentSourcesHelpSheet()
        }
    }

    // MARK: - Usage Tab


    // MARK: - Notifications Tab

    private var historyTab: some View {
        UsageHistoryTabView()
    }

    // MARK: - Notifications Tab


    #if AGENTBAR_NOTIFICATION_SOUNDS
    #endif

    @discardableResult
    func saveCopilotPAT() -> Bool {
        let outcome = saveTokenWithUIState(
            copilotPAT,
            account: ServiceType.copilot.keychainAccount,
            hasSavedToken: hasSavedCopilotPAT
        )
        hasSavedCopilotPAT = outcome.hasSavedToken
        if outcome.didSave {
            copilotManualPATEnabled = true
        }
        copilotPAT = outcome.tokenFieldValue
        return outcome.didSave
    }

    @discardableResult
    func saveZaiAPIKey() -> Bool {
        let outcome = saveTokenWithUIState(
            zaiAPIKey,
            account: ServiceType.zai.keychainAccount,
            hasSavedToken: hasSavedZaiAPIKey
        )
        hasSavedZaiAPIKey = outcome.hasSavedToken
        zaiAPIKey = outcome.tokenFieldValue
        return outcome.didSave
    }

    func saveTokenWithUIState(
        _ token: String,
        account: String,
        hasSavedToken: Bool
    ) -> TokenSaveUIOutcome {
        let outcome = Self.tokenSaveUIOutcome(
            currentToken: token,
            hasSavedToken: hasSavedToken,
            account: account,
            save: keychainSaveAction
        )
        if outcome.showSavedAlert {
            activeTokenSaveAlert = .saved
        } else if outcome.showSaveErrorAlert {
            activeTokenSaveAlert = .saveFailed(outcome.saveErrorMessage)
        } else {
            activeTokenSaveAlert = nil
        }
        return outcome
    }

    private func migrateLegacyClaudePlanIfNeeded() {
        if claudePlan == "Max" {
            claudePlan = ClaudePlan.max5x.rawValue
        }
        if ClaudePlan(rawValue: claudePlan) == nil {
            claudePlan = ClaudePlan.pro.rawValue
        }
    }

    private func migrateLegacyCursorPlanIfNeeded() {
        let resolvedPlan = CursorPlan.resolveAndMigrateStoredPlan()
        guard resolvedPlan.rawValue != cursorPlan else { return }

        cursorPlan = resolvedPlan.rawValue
        if resolvedPlan != .custom {
            cursorMonthlyLimit = resolvedPlan.monthlyRequestEstimate
        }
    }

    private func sanitizeNotificationSoundModeIfNeeded() {
        guard NotificationSoundMode(rawValue: notificationSoundMode) == nil else { return }
        notificationSoundMode = NotificationSoundMode.system.rawValue
    }

    private func migrateLegacyCopilotManualPATIfNeeded() {
        CopilotCredentialSettings.migrateLegacyManualPATIfNeeded(in: .standard)
        copilotManualPATEnabled = CopilotCredentialSettings.isManualPATEnabled(in: .standard)
    }

    func loadAPIKeys() {
        if copilotManualPATEnabled {
            hasSavedCopilotPAT = KeychainManager.load(account: ServiceType.copilot.keychainAccount) != nil
        } else {
            hasSavedCopilotPAT = false
        }
        hasSavedZaiAPIKey = KeychainManager.load(account: ServiceType.zai.keychainAccount) != nil
        copilotPAT = ""
        zaiAPIKey = ""
    }

    func refreshHookConfigurationStatus() {
        let checker = AgentHookConfigurationChecker()
        hookConfigurationStatus = checker.check()
    }

    func notifyNotificationsSettingsChanged() {
        NotificationCenter.default.post(name: .notificationsSettingsChanged, object: nil)
    }

    func notifyLimitsChanged() {
        NotificationCenter.default.post(name: .limitsChanged, object: nil)
    }

    struct TokenSaveUIOutcome: Equatable {
        let didSave: Bool
        let hasSavedToken: Bool
        let tokenFieldValue: String
        let showSavedAlert: Bool
        let showSaveErrorAlert: Bool
        let saveErrorMessage: String
    }

    enum TokenSaveAlert: Identifiable {
        case saved
        case saveFailed(String)

        var id: String {
            switch self {
            case .saved:
                return "saved"
            case .saveFailed(let message):
                return "saveFailed:\(message)"
            }
        }
    }

    enum SaveResult {
        case success
        case failure(String)
    }

    static func saveAPIKeyResult(
        _ key: String,
        account: String,
        save: (String, String) throws -> Void = { key, account in
            try KeychainManager.save(key: key, account: account)
        }
    ) -> SaveResult {
        guard let sanitizedKey = sanitizedTokenForSaving(key) else {
            return .failure("Please enter a valid token before saving.")
        }
        do {
            try save(sanitizedKey, account)
            return .success
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return .failure("Failed to save token to Keychain.")
            }
            return .failure(message)
        }
    }

    static func tokenSaveUIOutcome(
        currentToken: String,
        hasSavedToken: Bool,
        account: String,
        save: (String, String) throws -> Void = { key, account in
            try KeychainManager.save(key: key, account: account)
        }
    ) -> TokenSaveUIOutcome {
        switch saveAPIKeyResult(currentToken, account: account, save: save) {
        case .success:
            return TokenSaveUIOutcome(
                didSave: true,
                hasSavedToken: true,
                tokenFieldValue: "",
                showSavedAlert: true,
                showSaveErrorAlert: false,
                saveErrorMessage: ""
            )
        case .failure(let message):
            return TokenSaveUIOutcome(
                didSave: false,
                hasSavedToken: hasSavedToken,
                tokenFieldValue: currentToken,
                showSavedAlert: false,
                showSaveErrorAlert: true,
                saveErrorMessage: message
            )
        }
    }

    static func sanitizedTokenForSaving(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveToken(trimmed) else { return nil }
        return trimmed
    }

    static func canSaveToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.allSatisfy { $0 == "*" }
    }
}

enum SettingsTab {
    case usage
    case history
    case notifications
}

#if AGENTBAR_NOTIFICATION_SOUNDS
private struct SoundPackHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notification Sounds (CESP)")
                .font(.headline)

            Text("Sound packs are fetched from the **PeonPing** registry and downloaded automatically when selected.")
                .font(.body)

            GroupBox("How It Works") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Select a sound pack from the dropdown")
                    Text("2. The pack is downloaded to **~/.openpeon/packs/**")
                    Text("3. Sounds play automatically for agent events")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Sound Categories") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("**task.complete** — played when an agent finishes a task")
                    Text("**input.required** — played when an agent needs user input")
                    Text("Multiple files per category are rotated randomly without repeats.")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Supported formats:** WAV, MP3, AIFF, M4A, CAF")
                    Text("**Registry:** peonping.github.io/registry")
                    Text("**Local storage:** ~/.openpeon/packs/")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
#endif

private struct AgentSourcesHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Sources")
                .font(.headline)

            Text("AgentBar receives agent events through the following sources.")
                .font(.body)

            GroupBox("Claude Hook") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Receives events via Unix socket at **~/.agentbar/events.sock**.")
                    Text("Register the hook with **scripts/agentbar-hook.sh** in your Claude configuration.")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Codex File Watcher") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Monitors **~/.codex/sessions** for session file changes.")
                    Text("Fallback for users without hook configuration. Register **scripts/agentbar-codex-hook.sh** for socket-based delivery instead.")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("OpenCode Hook") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Receives OpenCode events via plugin and forwards to **~/.agentbar/events.sock**.")
                    Text("OpenCode permission/question prompts are normalized as **Input required** notifications.")
                    Text("Install with **scripts/install-agent-hooks.sh** (creates **~/.config/opencode/plugins/agentbar-notify.js**).")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Safe Hook Install") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run **scripts/install-agent-hooks.sh** to configure Codex/Claude/Gemini/OpenCode hooks.")
                    Text("The installer never overwrites configs without backup. Copies are saved under **~/.agentbar/backups/**.")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct HookConfigurationStatusRow: View {
    let title: String
    let status: AgentHookSourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(status.isConfigured ? "Configured" : "Not configured")
                    .font(.caption)
                    .foregroundStyle(status.isConfigured ? .green : .secondary)
            }
            Text(status.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}


// MARK: - usageTab
