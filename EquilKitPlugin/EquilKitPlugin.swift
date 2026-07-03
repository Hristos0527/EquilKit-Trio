import EquilKit
import LoopKitUI

public final class EquilKitPlugin: NSObject, PumpManagerUIPlugin {
    public var pumpManagerType: PumpManagerUI.Type? {
        EquilPumpManager.self
    }

    public var cgmManagerType: CGMManagerUI.Type? {
        nil
    }

    override public init() {
        super.init()
    }
}
