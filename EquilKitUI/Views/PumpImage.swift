import SwiftUI

struct PumpImage: View {
    var is300u: Bool = false
    var height: CGFloat = 150

    init(is300u: Bool = false, height: CGFloat = 150) {
        self.is300u = is300u
        self.height = height
    }

    var body: some View {
        if let uiImage = UIImage.equilKitImage(named: is300u ? "nano300" : "nano200") {
            HStack {
                Spacer()
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal)
                    .frame(height: height)
                Spacer()
            }
        }
    }
}
