import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: AppSettingsStore

    var body: some View {
        Form {
            Section("Auto Refresh") {
                Picker("Refresh every", selection: $settingsStore.refreshIntervalMinutes) {
                    ForEach(AppSettingsStore.supportedRefreshIntervals, id: \.self) { minutes in
                        Text(intervalLabel(for: minutes))
                            .tag(minutes)
                    }
                }
                .pickerStyle(.menu)

                Text("Revenue metrics are refreshed in the background while the app is running.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 480)
    }

    private func intervalLabel(for minutes: Int) -> String {
        if minutes == 1 {
            return "1 minute"
        }
        if minutes == 60 {
            return "1 hour"
        }
        return "\(minutes) minutes"
    }
}
