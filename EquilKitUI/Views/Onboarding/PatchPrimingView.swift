import LoopKitUI
import SwiftUI

struct PatchPrimingView: View {
    @ObservedObject var viewModel: PatchPrimingViewModel

    var body: some View {
        VStack {
            List {
                Section {
                    PumpImage(is300u: viewModel.is300u, height: 120)
                    instructionRow(
                        number: "1.",
                        text: String(
                            localized: "Connect your pump base to the patch.",
                            comment: "Label for prime step 2.1"
                        )
                    )
                    instructionRow(
                        number: "2.",
                        text: String(
                            localized: "Fill the syringe with insulin",
                            comment: "Label for prime step 2.2"
                        )
                    )
                    instructionRow(
                        number: "3.",
                        text: String(
                            localized: "Place the syringe in the patch and pull out 1 to 2 dashes of air.",
                            comment: "Label for prime step 2.3"
                        )
                    )
                    instructionRow(
                        number: "4.",
                        text: String(
                            localized: "Fill the patch with insulin. NOTE: A minimum of 70U is required for activation.",
                            comment: "Label for prime step 2.4"
                        )
                    )
                    instructionRow(
                        number: "5.",
                        text: String(
                            localized: "Press the needle button and start the priming process.",
                            comment: "Label for pressing needle button step 2.5"
                        )
                    )
                }
            }
            Spacer()
            if !viewModel.primingError.isEmpty {
                Text(viewModel.primingError)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
            } else if !viewModel.isPriming {
                Text("Do not attach the patch to the body yet", comment: "Label for warning priming")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
            } else {
                ProgressView(progress: viewModel.primeProgress)
                    .padding(.horizontal)
            }

            Button(action: { viewModel.previousStep() }) {
                Text("Go back to pump base", comment: "label for go to pump base patch")
            }
            .buttonStyle(ActionButtonStyle(.secondary))
            .disabled(viewModel.isPriming)
            .padding(.horizontal)

            Button(action: { viewModel.startPrime() }) {
                if viewModel.isPriming {
                    ActivityIndicator()
                } else {
                    Text("Start priming", comment: "label for prime start action")
                }
            }
            .disabled(viewModel.isPriming)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])

            // STOP/CANCEL: visible only during priming. Stops fill-loop and frees
            // command queue so Delete Pump / deactivate proceeds IMMEDIATELY (stuck priming
            // included). connect-per-command queue drained by `cancelPriming()`.
            if viewModel.isPriming {
                Button(action: { viewModel.cancelPriming() }) {
                    Text("Stop priming", comment: "label for prime stop/cancel action")
                }
                .buttonStyle(ActionButtonStyle(.destructive))
                .padding([.bottom, .horizontal])
            }
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .navigationBarBackButtonHidden(viewModel.isPriming)
        .navigationTitle(String(localized: "Patch Priming", comment: "Priming header"))
        .onAppear { viewModel.handleAppear() }
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top) {
            Text(number)
                .foregroundStyle(.primary)
            Text(text)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
