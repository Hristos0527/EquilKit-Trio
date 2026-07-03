import Foundation
import UIKit

// MARK: - Background keepalive (Build #53)

extension EquilPumpManager {
    /// 60–90 s jittered interval — pump alarms "no connection" after ~2–3 minutes.
    static let backgroundKeepaliveMinInterval: TimeInterval = 60
    static let backgroundKeepaliveMaxInterval: TimeInterval = 90

    func setupBackgroundKeepaliveObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(equilAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(equilAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        if UIApplication.shared.applicationState == .background {
            equilAppDidEnterBackground()
        }
    }

    @objc private func equilAppDidEnterBackground() {
        appIsInBackground = true
        EquilLogBuffer.shared.append(
            "Equil BG keepalive: background — timer started",
            category: "EquilPumpManager",
            level: .info
        )
        scheduleBackgroundKeepaliveTimer(firstFireDelay: 5)
    }

    @objc private func equilAppWillEnterForeground() {
        appIsInBackground = false
        stopBackgroundKeepaliveTimer()
        EquilLogBuffer.shared.append(
            "Equil BG keepalive: foreground — timer stopped",
            category: "EquilPumpManager",
            level: .info
        )
    }

    /// Conditions: paired, priming complete, not intentional suspend, no active bolus/priming fill.
    var backgroundKeepaliveShouldRun: Bool {
        guard state.isOnboarded, !state.deviceToken.isEmpty else { return false }
        guard isPrimingComplete else { return false }
        guard !state.isSuspended else { return false }
        guard state.bolusDose == nil else { return false }
        guard !commandQueue.isPrimingFillActive else { return false }
        return true
    }

    /// Lightweight BLE ping (CmdRunningModeGet) — connect-per-command, nincs dosing opcode.
    func performBackgroundKeepalivePing(completion: ((Bool) -> Void)? = nil) {
        guard backgroundKeepaliveShouldRun else {
            completion?(false)
            return
        }
        pingPumpReachability { success in
            let message = success
                ? "Equil BG keepalive ping OK"
                : "Equil BG keepalive ping failed"
            EquilLogBuffer.shared.append(message, category: "EquilPumpManager", level: success ? .info : .warning)
            completion?(success)
        }
    }

    func scheduleBackgroundKeepaliveTimer(firstFireDelay: TimeInterval? = nil) {
        stopBackgroundKeepaliveTimer()
        guard appIsInBackground, backgroundKeepaliveShouldRun else { return }

        let delay = firstFireDelay ?? Self.nextBackgroundKeepaliveInterval()
        let timer = DispatchSource.makeTimerSource(queue: backgroundKeepaliveQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.fireBackgroundKeepalive()
        }
        backgroundKeepaliveTimer = timer
        timer.resume()
    }

    func stopBackgroundKeepaliveTimer() {
        backgroundKeepaliveTimer?.cancel()
        backgroundKeepaliveTimer = nil
    }

    private static func nextBackgroundKeepaliveInterval() -> TimeInterval {
        let span = backgroundKeepaliveMaxInterval - backgroundKeepaliveMinInterval
        return backgroundKeepaliveMinInterval + TimeInterval.random(in: 0 ... span)
    }

    private func fireBackgroundKeepalive() {
        guard appIsInBackground else { return }

        let sinceLast = Date.now.timeIntervalSince(lastBackgroundKeepaliveAt)
        if sinceLast < Self.backgroundKeepaliveMinInterval {
            scheduleBackgroundKeepaliveTimer(
                firstFireDelay: Self.backgroundKeepaliveMinInterval - sinceLast
            )
            return
        }

        var bgTaskID = UIBackgroundTaskIdentifier.invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "Equil BG Keepalive") {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }

        performBackgroundKeepalivePing { [weak self] success in
            guard let self else { return }
            if success {
                self.lastBackgroundKeepaliveAt = Date.now
            }
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
            }
            guard self.appIsInBackground else { return }
            self.scheduleBackgroundKeepaliveTimer()
        }
    }
}
