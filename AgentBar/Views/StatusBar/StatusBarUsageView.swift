import SwiftUI

/// Menu bar status item: shows three pinned services at once (Claude, Codex,
/// OpenCode) as icon + remaining percentage. Services with a 5h and a weekly
/// window (Claude, OpenCode) stack both percentages; Codex shows its single
/// weekly percentage.
struct StatusBarUsageView: View {
    let services: [UsageData]
    var hasError: Bool = false

    /// The three services pinned in the menu bar, in display order.
    private static let pinnedServices: [ServiceType] = [.claude, .codex, .opencode]

    private var displayed: [UsageData] {
        Self.pinnedServices.compactMap { pinned in
            services.first { $0.service == pinned && $0.isAvailable }
        }
    }

    var body: some View {
        if displayed.isEmpty {
            HStack(spacing: 2) {
                if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 20)
        } else {
            HStack(alignment: .center, spacing: 10) {
                ForEach(displayed) { usage in
                    ServiceUsageStack(usage: usage)
                }
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ServiceUsageStack: View {
    let usage: UsageData

    private var fiveHourPercent: String {
        percentString(usage.fiveHourUsage.remainingPercentage)
    }

    private var weeklyPercent: String {
        guard let weekly = usage.weeklyUsage else { return "" }
        return percentString(weekly.remainingPercentage)
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(usage.service.shortName)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(usage.service.darkColor)
                .frame(width: 18, alignment: .leading)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                percentLine(label: usage.service.fiveHourLabel, value: fiveHourPercent)
                if usage.weeklyUsage != nil {
                    percentLine(label: usage.service.weeklyLabel, value: weeklyPercent)
                }
            }
        }
        .fixedSize()
    }

    private func percentLine(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 6.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private func percentString(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
