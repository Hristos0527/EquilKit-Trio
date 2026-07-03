import LoopKitUI
import SwiftUI

struct EquilPairingView: View {
    @ObservedObject var viewModel: EquilPairingViewModel
    let paired: () -> Void

    var body: some View {
        List {
            Section(
                header: Text("Pumps in range"),
                footer: Text(
                    "The pump name contains the serial number (e.g. \"Equil - A09F2A\"). The serial number is read automatically."
                )
            ) {
                if viewModel.pumps.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Searching for pumps…")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(viewModel.pumps) { pump in
                        Button { viewModel.pair(with: pump) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pump.name)
                                        .foregroundColor(.primary)
                                    Text("SN: \(pump.serial)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(viewModel.pairing)
                    }
                }
            }

            Section {
                HStack {
                    if viewModel.pairing { ProgressView() }
                    Text(viewModel.status)
                        .foregroundColor(.secondary)
                }
                if let err = viewModel.errorText {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.subheadline)
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear { viewModel.startScan() }
        .onDisappear { viewModel.stopScan() }
        .onChange(of: viewModel.pairedOK) { ok in
            if ok { paired() }
        }
    }
}
