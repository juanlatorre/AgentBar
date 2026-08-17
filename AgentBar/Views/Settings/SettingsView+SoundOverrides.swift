import SwiftUI

extension SettingsView {
    var agentSoundOverridesSection: some View {
        DisclosureGroup("Agent Sound Overrides") {
            ForEach(SoundPackViewModel.overridableAgents, id: \.rawValue) { service in
                let account = service.keychainAccount
                let overrideValue = soundPackVM.agentOverrides[account] ?? ""
                let binding = Binding<String>(
                    get: { overrideValue },
                    set: { soundPackVM.selectAgentPack(service, name: $0) }
                )
                HStack {
                    Picker(service.rawValue, selection: binding) {
                        Text("Default").tag("")
                        Text("None").tag("__none__")
                        ForEach(soundPackVM.filteredPacks) { pack in
                            Text(pack.display_name).tag(pack.name)
                        }
                    }
                    .disabled(!notificationsEnabled)

                    Button {
                        _ = NotifySoundManager.shared.playTest(
                            category: "task.complete",
                            service: service
                        )
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(!notificationsEnabled || overrideValue == "__none__")
                    .help("Test \(service.rawValue) sound")
                }
            }
        }
        .disabled(!notificationsEnabled)
    }
}
