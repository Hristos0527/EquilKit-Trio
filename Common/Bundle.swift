import Foundation
import UIKit

enum EquilKitResourceBundle {
    static let main: Bundle = {
        let candidates: [Bundle] = [
            Bundle(for: EquilHUDProvider.self),
            Bundle.main
        ].compactMap { $0 }

        for bundle in candidates {
            if UIImage(named: "nano200", in: bundle, compatibleWith: nil) != nil {
                return bundle
            }
        }
        if let resourceURL = Bundle.main.resourceURL,
           let nested = Bundle(url: resourceURL.appendingPathComponent("EquilKit_EquilKit.bundle")),
           UIImage(named: "nano200", in: nested, compatibleWith: nil) != nil
        {
            return nested
        }
        return Bundle(for: EquilHUDProvider.self)
    }()
}

extension UIImage {
    static func equilKitImage(named name: String) -> UIImage? {
        UIImage(named: name, in: EquilKitResourceBundle.main, compatibleWith: nil)
    }
}

extension Bundle {
    var bundleDisplayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "App"
    }
}
