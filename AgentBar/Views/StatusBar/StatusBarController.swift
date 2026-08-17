import Cocoa
import SwiftUI
import Combine

@MainActor
final class StatusBarController {
    /// Fixed width for the status item and its hosting view.
    private static let statusItemLength: CGFloat = 200

    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<StatusBarUsageView>?
    private var cancellables: Set<AnyCancellable> = []
    private var setupRetryCount = 0
    private let maxSetupRetries = 10

    private let viewModel: UsageViewModel

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
    }

    func setup() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: Self.statusItemLength)
        }

        guard let button = statusItem?.button else {
            retrySetup()
            return
        }

        setupRetryCount = 0
        hostingView?.removeFromSuperview()

        let barView = StatusBarUsageView(services: viewModel.usageData)
        let hosting = NSHostingView(rootView: barView)
        // Fixed frame matching the status item width: with a fresh status item the
        // button bounds can still be empty at setup time, and a zero frame would
        // render an invisible strip that never re-layouts. A fixed non-zero frame
        // plus autoresizing keeps the hosting view visible as the button grows.
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.statusItemLength,
            height: 24
        )
        hosting.autoresizingMask = [.width, .height]
        button.addSubview(hosting)
        self.hostingView = hosting

        if cancellables.isEmpty {
            // Observe ViewModel changes
            viewModel.$usageData
                .combineLatest(viewModel.$lastError)
                .receive(on: RunLoop.main)
                .sink { [weak self] data, error in
                    self?.hostingView?.rootView = StatusBarUsageView(
                        services: data,
                        hasError: error != nil
                    )
                }
                .store(in: &cancellables)
        }

        // Click action — toggle popover
        button.target = self
        button.action = #selector(statusItemClicked)
    }

    private func retrySetup() {
        guard setupRetryCount < maxSetupRetries else { return }
        setupRetryCount += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.setup()
        }
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        PopoverController.shared.toggle(relativeTo: button, viewModel: viewModel)
    }
}
