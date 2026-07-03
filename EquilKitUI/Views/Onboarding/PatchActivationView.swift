import LoopKitUI
import SwiftUI

struct PatchActivationView: View {
    @Environment(\.dismissAction) private var dismiss
    @ObservedObject var viewModel: PatchActivationViewModel

    var body: some View {
        VStack {
            List {
                Section {
                    PumpImage(is300u: viewModel.is300u, height: 120)
                    instructionRow(
                        number: "6.",
                        text: String(
                            localized: "Remove the safety cover from the patch.",
                            comment: "Label for inserting needle step 1"
                        )
                    )
                    instructionRow(
                        number: "7.",
                        text: String(
                            localized: "Attach the pump to the body.",
                            comment: "Label for inserting needle step 2"
                        )
                    )
                    instructionRow(
                        number: "8.",
                        text: String(
                            localized: "Press the needle button to insert the needle. Click on \"Activate\" to complete the activation process.",
                            comment: "Label for inserting needle step 3"
                        )
                    )
                }
            }
            Spacer()
            if !viewModel.activationError.isEmpty {
                Text(viewModel.activationError)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
            }

            Button(action: { viewModel.previousStep() }) {
                Text("Go back to priming", comment: "label for go to prime patch")
            }
            .buttonStyle(ActionButtonStyle(.secondary))
            .disabled(viewModel.isActivating)
            .padding(.horizontal)

            Button(action: { viewModel.activate() }) {
                if viewModel.isActivating {
                    ActivityIndicator()
                } else {
                    Text("Activate Patch", comment: "label for activate patch")
                }
            }
            .disabled(viewModel.isActivating)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .navigationTitle(String(localized: "Patch Activation", comment: "Patch activation header"))
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(String(localized: "Cancel", comment: "Cancel button title"), action: {
                    self.dismiss()
                })
            }
        }
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
