import SwiftUI

/// Menu bar status item: shows the most critical service as icon + remaining
/// percentage (e.g. "CX 96%"), cycling through all services every few seconds.
/// Hovering jumps back to the top service and pauses the cycle.
struct StatusBarUsageView: View {
    let services: [UsageData]
    var hasError: Bool = false

    @State private var currentScrollIndex = 0
    @State private var isHovered = false

    private var rankedServices: [UsageData] {
        StatusBarDisplayPlanner.rankedServices(from: services)
    }

    private var currentService: UsageData? {
        guard !rankedServices.isEmpty else { return nil }
        return rankedServices[min(currentScrollIndex, rankedServices.count - 1)]
    }

    private var cycleTaskID: String {
        let signature = rankedServices
            .map { usage in
                let fiveHour = Int((usage.fiveHourUsage.remainingPercentage * 1000).rounded())
                let weekly = Int(((usage.weeklyUsage?.remainingPercentage ?? 0) * 1000).rounded())
                let monthly = Int(((usage.monthlyUsage?.remainingPercentage ?? 0) * 1000).rounded())
                return "\(usage.service.rawValue):\(fiveHour):\(weekly):\(monthly)"
            }
            .joined(separator: "|")
        return "\(signature)#hover:\(isHovered ? 1 : 0)"
    }

    var body: some View {
        if rankedServices.isEmpty {
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
            HStack(spacing: 3) {
                Text(currentService!.service.shortName)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(currentService!.service.darkColor)
                Text("\(Int(StatusBarDisplayPlanner.criticalRemainingPercentage(for: currentService!) * 100))%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    jumpToTopImmediately()
                }
            }
            .task(id: cycleTaskID) {
                await runScrollLoop()
            }
        }
    }

    @MainActor
    private func runScrollLoop() async {
        jumpToTopImmediately()

        let maxIndex = StatusBarDisplayPlanner.maxScrollIndex(for: rankedServices)
        guard maxIndex > 0 else { return }

        while !Task.isCancelled {
            if isHovered {
                jumpToTopImmediately()
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            let duration = currentScrollIndex == 0
                ? StatusBarDisplayPlanner.topPriorityHoldSeconds
                : StatusBarDisplayPlanner.scrollStepHoldSeconds
            let nanoseconds = UInt64(duration * 1_000_000_000)

            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard !isHovered else { continue }

            if currentScrollIndex < maxIndex {
                withAnimation(.easeInOut(duration: StatusBarDisplayPlanner.scrollTransitionSeconds)) {
                    currentScrollIndex += 1
                }
            } else {
                jumpToTopImmediately()
            }
        }
    }

    @MainActor
    private func jumpToTopImmediately() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentScrollIndex = 0
        }
    }
}
