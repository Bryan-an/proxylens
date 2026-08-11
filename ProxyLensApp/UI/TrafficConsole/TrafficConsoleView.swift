import SwiftUI

struct TrafficConsoleView: NSViewControllerRepresentable {
    @ObservedObject var viewModel: TrafficConsoleViewModel

    func makeNSViewController(context: Context) -> TrafficConsoleViewController {
        TrafficConsoleViewController(viewModel: viewModel)
    }

    func updateNSViewController(
        _ nsViewController: TrafficConsoleViewController,
        context: Context
    ) {}
}
