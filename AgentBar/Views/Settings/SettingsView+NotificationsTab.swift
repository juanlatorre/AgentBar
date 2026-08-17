import SwiftUI

extension SettingsView {
    var notificationsTab: some View {
        Form {
            Section("Agent Notifications (Beta)") {
                Toggle("Enable notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("Task completed", isOn: $notificationTaskCompletedEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationTaskCompletedEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("Input required", isOn: $notificationInputRequiredEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationInputRequiredEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("Show message preview", isOn: $notificationShowMessagePreview)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationShowMessagePreview) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Text("Preview shows the agent output text in the notification body when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(!notificationsEnabled)

                Picker("Notification sound", selection: $notificationSoundMode) {
                    Text("System default").tag(NotificationSoundMode.system.rawValue)
                    Text("Mute").tag(NotificationSoundMode.mute.rawValue)
                }
                .disabled(!notificationsEnabled)
                .onChange(of: notificationSoundMode) { _ in
                    notifyNotificationsSettingsChanged()
                }

                Text("Mute keeps notifications visible while disabling all sounds, including the system default sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(!notificationsEnabled)

                Button("Request Notification Permission") {
                    AgentNotifyNotificationService.requestAuthorizationPrompt()
                }
                .disabled(!notificationsEnabled)
            }

            #if AGENTBAR_NOTIFICATION_SOUNDS
            Section {
                Picker("Language", selection: $soundPackVM.selectedLanguage) {
                    Text("All").tag("")
                    ForEach(soundPackVM.availableLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .disabled(!notificationsEnabled)

                HStack {
                    Picker("Sound pack", selection: $soundPackVM.selectedPackName) {
                        Text("None").tag("")
                        ForEach(soundPackVM.filteredPacks) { pack in
                            HStack {
                                Text(pack.display_name)
                                if !pack.formattedSize.isEmpty {
                                    Text("(\(pack.formattedSize))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(pack.name)
                        }
                    }
                    .disabled(!notificationsEnabled || soundPackVM.isLoadingRegistry)
                    .onChange(of: soundPackVM.selectedPackName) { newValue in
                        soundPackVM.selectPack(newValue)
                    }

                    if soundPackVM.isLoadingRegistry {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task { await soundPackVM.loadRegistry(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(soundPackVM.isLoadingRegistry)
                }

                if soundPackVM.isDownloading {
                    ProgressView(value: soundPackVM.downloadProgress)
                        .progressViewStyle(.linear)
                }

                if let error = soundPackVM.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Test task.complete") {
                        _ = NotifySoundManager.shared.playTest(category: "task.complete")
                    }
                    .disabled(!notificationsEnabled || notificationSoundPackPath.isEmpty)

                    Button("Test input.required") {
                        _ = NotifySoundManager.shared.playTest(category: "input.required")
                    }
                    .disabled(!notificationsEnabled || notificationSoundPackPath.isEmpty)
                }

                agentSoundOverridesSection

                HStack {
                    Text("Volume:")
                    Slider(value: $notificationSoundVolume, in: 0...1, step: 0.1)
                        .frame(width: 150)
                    Text(String(format: "%.0f%%", notificationSoundVolume * 100))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!notificationsEnabled)
            } header: {
                HStack {
                    Text("Notification Sounds")
                    Spacer()
                    Button {
                        showingSoundPackHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            #endif

            Section {
                Toggle("Codex file watcher", isOn: $notificationCodexEventsEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationCodexEventsEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("Claude hook", isOn: $notificationClaudeHookEventsEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationClaudeHookEventsEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("OpenCode hook", isOn: $notificationOpencodeHookEventsEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationOpencodeHookEventsEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                HookConfigurationStatusRow(
                    title: "Codex notify hook",
                    status: hookConfigurationStatus.codex
                )

                HookConfigurationStatusRow(
                    title: "Claude hook command",
                    status: hookConfigurationStatus.claude
                )

                HStack {
                    Button("Re-check hook configuration") {
                        refreshHookConfigurationStatus()
                    }
                    Spacer()
                    if hookConfigurationStatus.checkedAt != .distantPast {
                        Text(hookConfigurationStatus.checkedAt.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                    }
                }
            } header: {
                HStack {
                    Text("Agent Sources")
                    Spacer()
                    Button {
                        showingAgentSourcesHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        #if AGENTBAR_NOTIFICATION_SOUNDS
        .onAppear {
            Task { await soundPackVM.loadRegistry() }
        }
        #endif
    }
}
