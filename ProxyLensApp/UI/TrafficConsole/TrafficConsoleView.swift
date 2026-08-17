import SwiftUI

struct TrafficConsoleView: NSViewControllerRepresentable {
    @ObservedObject var viewModel: TrafficConsoleViewModel

    func makeNSViewController(context: Context) -> TrafficConsoleViewController {
        TrafficConsoleViewController(
            viewModel: viewModel,
            sourceListVisibilityStore: UserDefaultsTrafficSourceListVisibilityStore()
        )
    }

    func updateNSViewController(
        _ nsViewController: TrafficConsoleViewController,
        context: Context
    ) {}
}
