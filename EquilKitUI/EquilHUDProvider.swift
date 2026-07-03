import LoopKit
import LoopKitUI
import UIKit

public final class EquilHUDProvider: NSObject, HUDProvider {
    private let pumpManager: EquilPumpManager
    private let processQueue = DispatchQueue(label: "com.equil.hud")
    private var labelView: UILabel?

    public var visible: Bool = true {
        didSet {
            if oldValue != visible, visible {
                updateView()
            }
        }
    }

    public init(
        pumpManager: EquilPumpManager,
        bluetoothProvider _: BluetoothProvider,
        colorPalette _: LoopUIColorPalette,
        allowedInsulinTypes _: [InsulinType]
    ) {
        self.pumpManager = pumpManager
        super.init()
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    public func createHUDView() -> BaseHUDView? {
        let hud = BaseHUDView(frame: .zero)
        let label = UILabel(frame: .zero)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: hud.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -2)
        ])
        labelView = label
        updateView()
        return hud
    }

    public func didTapOnHUDView(_: BaseHUDView, allowDebugFeatures _: Bool) -> HUDTapAction? { nil }

    public var hudViewRawState: HUDViewRawState {
        [
            "reservoir": pumpManager.state.reservoir,
            "lastSync": pumpManager.state.lastSync
        ]
    }

    public var managerIdentifier: String { pumpManager.managerIdentifier }

    public static func createHUDView(rawValue: HUDViewRawState) -> BaseHUDView? {
        guard let reservoir = rawValue["reservoir"] as? Double else { return nil }
        let hud = BaseHUDView(frame: .zero)
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textAlignment = .center
        label.text = String(format: "%.0fU", reservoir)
        label.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: hud.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -2)
        ])
        return hud
    }

    private func updateView() {
        DispatchQueue.main.async {
            self.labelView?.text = String(format: "%.0fU", self.pumpManager.state.reservoir)
        }
    }
}

extension EquilHUDProvider: PumpManagerStatusObserver {
    public func pumpManager(_: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        updateView()
    }
}
