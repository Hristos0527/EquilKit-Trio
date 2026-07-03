import HealthKit
import LoopKit
import LoopKitUI
import SwiftUI

struct EquilKitSettings: View {
    @State private var showingTimeSyncConfirmation: Bool = false
    @State private var isSharePresented: Bool = false
    @ObservedObject var viewModel: EquilKitSettingsViewModel

    @Environment(\.dismissAction) private var dismiss
    @Environment(\.insulinTintColor) var insulinTintColor
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.appName) private var appName

    var syncPumpTime: ActionSheet {
        ActionSheet(
            title: Text("Time Change Detected", comment: "Title for pod sync time action sheet."),
            message: Text(
                "The time on your pump is different from the current time. Do you want to update the time on your pump to the current time?",
                comment: "Message for pod sync time action sheet"
            ),
            buttons: [
                .default(Text("Yes, Sync to Current Time", comment: "Button text to confirm pump time sync")) {
                    self.viewModel.syncPumpTime()
                },
                .cancel(Text("No, Keep Pump As Is", comment: "Button text to cancel pump time sync"))
            ]
        )
    }

    var suspendSheet: ActionSheet {
        ActionSheet(
            title: Text("Suspend Insulin Delivery", comment: "Title for suspend action"),
            message: Text(
                "How long you wish to suspend your patch maximum? It will resume automaticly after this time.",
                comment: "Message for suspend action"
            ),
            buttons: [
                .default(Text("30 minutes", comment: "suspend for 30 min")) {
                    self.viewModel.suspendDelivery(duration: .minutes(30))
                },
                .default(Text("1 hour", comment: "suspend for 1h")) {
                    self.viewModel.suspendDelivery(duration: .minutes(60))
                },
                .default(Text("1.5 hours", comment: "suspend for 1.5h")) {
                    self.viewModel.suspendDelivery(duration: .minutes(90))
                },
                .default(Text("2 hours", comment: "suspend for 2h")) {
                    self.viewModel.suspendDelivery(duration: .minutes(120))
                },
                .cancel(Text("Cancel", comment: "button cancel"))
            ]
        )
    }

    var body: some View {
        List {
            Section {
                VStack {
                    PumpImage(is300u: viewModel.is300u)
                    patchLifecycle
                }

                if viewModel.patchLifecycleState != .noPatch && viewModel.patchLifecycleState != .expired {
                    HStack(alignment: .top) {
                        deliveryStatus
                        Spacer()
                        reservoirStatus
                    }
                    .padding(.bottom, 5)
                }

                if viewModel.showPumpTimeSyncWarning {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time Change Detected", comment: "title for time change detected notice")
                            .font(Font.subheadline.weight(.bold))
                        Text(
                            "The time on your pump is different from the current time. Your pump’s time controls your scheduled therapy settings. Scroll down to Pump Time row to review the time difference and configure your pump.",
                            comment: "description for time change detected notice"
                        )
                        .font(Font.footnote.weight(.semibold))
                    }.padding(.vertical, 8)
                }

                if viewModel.patchLifecycleState == .gracePeriod {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: String(
                            localized: "Change your Patch now. Insulin delivery will stop in %@ or when no more insulin remains.",
                            comment: "description for grace period notice"
                        ), viewModel.patchGraceTimeout))
                            .font(Font.footnote.weight(.semibold))
                    }.padding(.vertical, 8)
                }

                if viewModel.patchState == .hourlyMaxSuspended {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Alert: Hourly max insulin", comment: "title hourlyMaxSuspended")
                            .font(Font.footnote.weight(.semibold))
                        Text(
                            String(
                                format: String(
                                    localized:
                                    "Patch is suspended. Limit of %lld U exceeded. If you increase the limit, you can clear the alert now. If you wait, patch will resume when enough time passes.",
                                    comment: "description dailyMaxSuspended"
                                ),
                                viewModel.hourlyLimit
                            )
                        )
                        .font(.footnote)
                        .padding(.bottom, 4)

                        Button {
                            viewModel.clearAlert(AlertType.hourly)
                        } label: {
                            Text("Clear alert", comment: "")
                                .font(.title3)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isClearingAlert)

                    }.padding(.vertical, 8)
                }

                if viewModel.patchState == .dailyMaxSuspended {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Alert: Daily max insulin", comment: "title dailyMaxSuspended")
                            .font(Font.footnote.weight(.semibold))
                        Text(
                            String(
                                format: String(
                                    localized:
                                    "Patch is suspended. Limit of %lld U exceeded. If you increase the limit, you can clear the alert now. If you wait, patch will resume when enough time passes.",
                                    comment: "description dailyMaxSuspended"
                                ),
                                viewModel.dailyLimit
                            )
                        )
                        .font(.footnote)
                        .padding(.bottom, 4)

                        Button {
                            viewModel.clearAlert(AlertType.daily)
                        } label: {
                            Text("Clear alert", comment: "")
                                .font(.title3)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isClearingAlert)
                    }.padding(.vertical, 8)
                }
            }

            Section {
                if viewModel.patchLifecycleState != .noPatch {
                    Button(action: { viewModel.toFullPriming() }) {
                        HStack {
                            Text("Prime Patch", comment: "Navigate to full patch priming flow")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                .opacity(0.35)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(action: { viewModel.primeOneStep() }) {
                        HStack {
                            Text("Prime One Step", comment: "Single manual prime step")
                            Spacer()
                            if viewModel.isPrimingOneStep {
                                ActivityIndicator()
                            }
                        }
                    }
                    .disabled(viewModel.isPrimingOneStep || viewModel.isRetractingPlunger)

                    if !viewModel.oneStepPrimeMessage.isEmpty {
                        Text(viewModel.oneStepPrimeMessage)
                            .font(.footnote)
                            .foregroundStyle(viewModel.oneStepPrimeSucceeded ? Color.secondary : Color.red)
                    }

                    Button(action: { viewModel.showingRetractPlungerConfirmation = true }) {
                        HStack {
                            Text("Retract Plunger", comment: "Retract plunger for reservoir change")
                            Spacer()
                            if viewModel.isRetractingPlunger {
                                ActivityIndicator()
                            }
                        }
                    }
                    .disabled(viewModel.isPrimingOneStep || viewModel.isRetractingPlunger)
                    .actionSheet(isPresented: $viewModel.showingRetractPlungerConfirmation) {
                        ActionSheet(
                            title: Text("Retract Plunger", comment: "Title for retract plunger confirmation"),
                            message: Text(
                                "This retracts the plunger for a reservoir change. Delivery will be suspended until you fill, prime, and resume.",
                                comment: "Message for retract plunger confirmation"
                            ),
                            buttons: [
                                .destructive(Text("Retract Plunger", comment: "Confirm retract plunger")) {
                                    viewModel.retractPlungerForReservoirChange()
                                },
                                .cancel()
                            ]
                        )
                    }

                    if !viewModel.retractPlungerError.isEmpty {
                        Text(viewModel.retractPlungerError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Patch Maintenance", comment: "Section for priming and reservoir change actions")
            }

            Section {
                if viewModel.patchLifecycleState != .noPatch {
                    Picker(
                        selection: Binding(
                            get: { viewModel.alarmMode },
                            set: { viewModel.setAlarmMode($0) }
                        ),
                        label: Text("Alert mode", comment: "Label for Equil sound/vibration/silent picker")
                    ) {
                        ForEach(AlarmMode.dashboardOptions) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .disabled(viewModel.isUpdatingAlarmMode)

                    if viewModel.isUpdatingAlarmMode {
                        HStack {
                            Text("Updating alert mode…", comment: "Status while CmdAlarmSet is in flight")
                                .foregroundStyle(.secondary)
                            Spacer()
                            ActivityIndicator()
                        }
                    }
                }
            } header: {
                Text("Sound / Vibration", comment: "Section for Equil pump alert mode")
            } footer: {
                Text(
                    "In sound mode the pump beeps on important deliveries so you can hear Loop working.",
                    comment: "Footer explaining Equil alert mode behavior"
                )
            }

            Section {
                if viewModel.patchLifecycleState != .noPatch {
                    Button(action: {
                        viewModel.suspendResumeButtonPressed()
                    }) {
                        HStack {
                            if viewModel.basalType == .suspend {
                                Text("Resume Insulin Delivery", comment: "Resume patch")
                            } else {
                                Text("Suspend Insulin Delivery", comment: "Suspend patch")
                            }
                            Spacer()
                            if viewModel.isUpdatingSuspend {
                                ActivityIndicator()
                            }
                        }
                    }
                    .disabled(
                        viewModel.isUpdatingPumpState || viewModel.isUpdatingTempBasal || viewModel
                            .isUpdatingSuspend || viewModel.isClearingAlert
                    )
                    .actionSheet(isPresented: $viewModel.showingSuspendPicker) {
                        suspendSheet
                    }

                    if viewModel.basalType == .tempBasal {
                        Button(action: {
                            viewModel.stopTempBasal()
                        }) {
                            HStack {
                                Text("Stop temp basal", comment: "Stop temp basal")
                                Spacer()
                                if viewModel.isUpdatingTempBasal {
                                    ActivityIndicator()
                                }
                            }
                        }
                        .disabled(
                            viewModel.isUpdatingPumpState || viewModel.isUpdatingTempBasal || viewModel
                                .isUpdatingSuspend || viewModel.isClearingAlert
                        )
                    }

                    if viewModel.basalType != .suspend {
                        Button(action: { viewModel.showManualTempBasal = true }) {
                            HStack {
                                Text("Set Temporary Basal Rate", comment: "Button title to set temporary basal rate")
                                Spacer()
                                if viewModel.isUpdatingTempBasal {
                                    ActivityIndicator()
                                }
                            }
                        }
                        .disabled(
                            viewModel.isUpdatingPumpState || viewModel.isUpdatingTempBasal || viewModel
                                .isUpdatingSuspend || viewModel.isClearingAlert
                        )
                        .sheet(isPresented: $viewModel.showManualTempBasal) {
                            EquilManualTempBasalEntryView(
                                enactBasal: { rate, duration, completion in
                                    viewModel.enactTempBasal(unitsPerHour: rate, duration: duration) { error in
                                        completion(error)
                                        if error == nil {
                                            viewModel.showManualTempBasal = false
                                        }
                                    }
                                },
                                didCancel: { viewModel.showManualTempBasal = false },
                                allowedRates: viewModel.allowedTempBasalRates
                            )
                        }
                    }

                    Button(action: { viewModel.syncData() }) {
                        HStack {
                            Text("Sync patch data", comment: "sync pump")
                            Spacer()
                            if viewModel.isUpdatingPumpState {
                                ActivityIndicator()
                            }
                        }
                    }
                    .disabled(
                        viewModel.isUpdatingPumpState || viewModel.isUpdatingTempBasal || viewModel
                            .isUpdatingSuspend || viewModel.isClearingAlert
                    )

                    if viewModel.patchState.rawValue < PatchState.active.rawValue && viewModel.patchState != .none {
                        Button(action: { viewModel.toPumpActivation() }) {
                            HStack {
                                Text("Activate Patch", comment: "label for activate patch")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                    .opacity(0.35)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(action: { viewModel.checkConnection() }) {
                        HStack {
                            if viewModel.isConnected {
                                Text("Disconnect", comment: "disconnect from patch")
                            } else {
                                Text("Reconnect", comment: "reconnect to patch")
                            }
                            Spacer()
                            if viewModel.isReconnecting {
                                ActivityIndicator()
                            }
                        }
                    }

                    Button(action: { viewModel.deactivatePatchAction() }) {
                        HStack {
                            Text("Deactivate Patch", comment: "deactivate patch")
                                .foregroundStyle(.red)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                .opacity(0.5)
                                .foregroundColor(.red)
                        }
                    }

                    HStack {
                        Text("Patch State", comment: "Text for patch state")
                            .foregroundColor(Color.primary)
                        Spacer()
                        Text(viewModel.patchStateString)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Last Sync", comment: "Text for last sync")
                            .foregroundColor(Color.primary)
                        Spacer()
                        if viewModel.patchLifecycleState != .noPatch {
                            Text(viewModel.dateFormatter.string(from: viewModel.lastSync))
                                .foregroundColor(.secondary)
                        } else {
                            Text("-")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Status", comment: "Text for status")
                            .foregroundColor(Color.primary)
                        Spacer()
                        HStack(spacing: 10) {
                            connectionStatusText
                            connectionStatusIcon
                        }
                    }
                } else {
                    Button(action: { viewModel.activatePatchAction() }) {
                        HStack {
                            Text("Activate Patch", comment: "activate patch")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                .opacity(0.5)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Insulin Type", comment: "Text for selecting insulin type")
                        .foregroundColor(Color.primary)
                    Spacer()
                    Text(viewModel.insulinType.brandName)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIFont.systemFontSize, weight: .medium))
                        .opacity(0.3)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.toInsulinType()
                }

                HStack {
                    Text("Patch Settings", comment: "Text for patch settings view")
                        .foregroundColor(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIFont.systemFontSize, weight: .medium))
                        .opacity(0.3)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.toSettings()
                }
            } header: {
                Text("Configuration", comment: "Configuration section")
            }

            Section {
                HStack {
                    Text("Cannula Age", comment: "Text for cannula age (CAGE)")
                        .foregroundColor(Color.primary)
                    Spacer()
                    if viewModel.patchLifecycleState != .noPatch {
                        Text(viewModel.patchLifetime)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("-")
                            .foregroundColor(.secondary)
                    }
                }
                if let activatedAt = viewModel.patchActivatedAt {
                    HStack {
                        Text("Activation", comment: "Text for activatedAt")
                            .foregroundColor(Color.primary)
                        Spacer()
                        if viewModel.patchLifecycleState != .noPatch {
                            Text(viewModel.dateTimeFormatter.string(from: activatedAt))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("-")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let gracePeriodFrom = viewModel.patchGracePeriodFrom {
                    HStack {
                        Text("Expiration", comment: "Text for expiresAt")
                            .foregroundColor(Color.primary)
                        Spacer()
                        if viewModel.patchLifecycleState != .noPatch {
                            Text(viewModel.dateTimeFormatter.string(from: gracePeriodFrom))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("-")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let expiresAt = viewModel.patchExpiresAt {
                    HStack {
                        Text("No Delivery", comment: "Text for expiresAt")
                            .foregroundColor(Color.primary)
                        Spacer()
                        if viewModel.patchLifecycleState != .noPatch {
                            Text(viewModel.dateTimeFormatter.string(from: expiresAt))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("-")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if viewModel.patchLifecycleState != .noPatch && viewModel.patchLifecycleState != .expired {
                    HStack {
                        Text("Battery", comment: "Text for patch battery voltage")
                            .foregroundColor(Color.primary)
                        Spacer()
                        Text(viewModel.batteryText(for: viewModel.battery))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                HStack {
                    Text("Patch Details", comment: "header patch details")
                        .foregroundColor(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIFont.systemFontSize, weight: .medium))
                        .opacity(0.3)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.toPatchDetails()
                }
                HStack {
                    Text("Previous Patch Details", comment: "header patch details")
                        .foregroundColor(Color.primary)
                    Spacer()
                    if viewModel.hasPreviousPatch {
                        Image(systemName: "chevron.right")
                            .font(.system(size: UIFont.systemFontSize, weight: .medium))
                            .opacity(0.3)
                    } else {
                        Text("-")
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if viewModel.hasPreviousPatch {
                        viewModel.toPreviousPatchDetails()
                    }
                }

            } header: {
                Text("Information", comment: "The title for patch/pump information")
            }

            Section {
                HStack {
                    Text("Patch Time", comment: "Text for pump time")
                        .foregroundColor(Color.primary)
                    Spacer()
                    if viewModel.showPumpTimeSyncWarning {
                        Image(systemName: "clock.fill")
                            .foregroundColor(guidanceColors.warning)
                    }
                    Text(String(viewModel.dateFormatter.string(from: viewModel.pumpTime)))
                        .foregroundColor(viewModel.showPumpTimeSyncWarning ? guidanceColors.warning : .secondary)
                }
                HStack {
                    Text("Checked at", comment: "Text for pump time synced at")
                        .foregroundColor(Color.primary)
                    Spacer()
                    Text(String(viewModel.dateFormatter.string(from: viewModel.pumpTimeSyncedAt)))
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    showingTimeSyncConfirmation = true
                }) {
                    HStack {
                        Text("Manually sync Pump time", comment: "Label for syncing the time on the pump")
                        Spacer()
                        if viewModel.isUpdatingPumpState {
                            ActivityIndicator()
                        }
                    }
                }
                .disabled(viewModel.isUpdatingPumpState || viewModel.patchLifecycleState == .noPatch)
                .foregroundColor(.accentColor)
                .actionSheet(isPresented: $showingTimeSyncConfirmation) {
                    syncPumpTime
                }
            }
            header: {
                Text("Patch Time", comment: "The title for patch time")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.equilLogPreview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    Button(action: {
                        viewModel.copyEquilLogToClipboard()
                    }) {
                        Text("Copy to clipboard", comment: "Copy Equil debug log to clipboard")
                    }

                    if viewModel.equilLogCopied {
                        Text("Log copied to clipboard.", comment: "Confirmation after copying Equil log")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive, action: {
                        viewModel.clearEquilLog()
                    }) {
                        Text("Clear", comment: "Clear Equil in-memory debug log")
                    }
                }
                .onAppear {
                    viewModel.refreshEquilLogPreview()
                }
            } header: {
                Text("Equil log", comment: "Section title for copyable Equil debug log")
            } footer: {
                Text(
                    "Equil events only (priming, BLE, resistance, connection). Last ~800 lines in memory.",
                    comment: "Footer explaining Equil in-memory log buffer"
                )
            }

            Section {
                Button(action: { self.isSharePresented = true }) {
                    Text("Share Equil patch logs", comment: "Share logs")
                }
                .sheet(isPresented: $isSharePresented, onDismiss: {}, content: {
                    ActivityViewController(activityItems: viewModel.getLogs())
                })

                Button(action: {
                    viewModel.showingDeleteConfirmation = true
                }) {
                    Text("Delete Pump", comment: "Label for PumpManager deletion button")
                        .foregroundColor(guidanceColors.critical)
                }
                .actionSheet(isPresented: $viewModel.showingDeleteConfirmation) {
                    removePumpManagerActionSheet(deleteAction: viewModel.deletePumpWithSafeSequence)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarItems(trailing: doneButton)
        .navigationBarTitle(viewModel.pumpName)
    }

    var reservoirStatus: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("Insulin Remaining", comment: "Header for insulin remaining on pod settings screen")
                .foregroundColor(Color(UIColor.secondaryLabel))
            HStack(alignment: .center, spacing: 10) {
                ReservoirView(
                    reservoirLevel: viewModel.reservoirLevel,
                    fillColor: reservoirColor,
                    maxReservoirLevel: viewModel.maxReservoirLevel
                )
                .frame(width: 23, height: 32)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(viewModel.reservoirText(for: viewModel.reservoirLevel))
                        .font(.system(size: 28))
                        .fontWeight(.heavy)
                        .fixedSize()

                    Text("U", comment: "Insulin unit")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var deliveryStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(deliverySectionTitle)
                .foregroundColor(Color(UIColor.secondaryLabel))

            switch viewModel.basalType {
            case .basal,
                 .bolus,
                 .resume,
                 .tempBasal:
                HStack(alignment: .center) {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(viewModel.basalRateFormatter.string(from: viewModel.basalRate as NSNumber) ?? "")
                            .font(.system(size: 28))
                            .fontWeight(.heavy)
                            .fixedSize()
                        Text("U/hr", comment: "Units for showing temp basal rate")
                            .foregroundColor(.secondary)
                    }
                }
            case .suspend:
                HStack(alignment: .center) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 34))
                        .fixedSize()
                        .foregroundColor(guidanceColors.warning)
                    Text(
                        "Insulin\nSuspended",
                        comment: "Text shown in insulin delivery space when insulin suspended"
                    )
                    .fontWeight(.bold)
                    .fixedSize()
                }
            }
        }
    }

    var patchLifecycle: some View {
        VStack {
            switch viewModel.patchLifecycleState {
            case .noPatch:
                HStack {
                    Text("No active patch", comment: "Text shown when no patch active")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .active,
                 .activeLast24h:
                HStack {
                    Text("Expires in:", comment: "Text shown while patch is active")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let days = viewModel.patchLifecycleDays, days > 0 {
                        timeComponent(
                            value: days,
                            units: days == 1 ?
                                String(localized: "day", comment: "Unit for singular day") :
                                String(localized: "days", comment: "Unit for plural days")
                        )
                    }

                    if let hours = viewModel.patchLifecycleHours {
                        timeComponent(
                            value: hours,
                            units: hours == 1 ?
                                String(localized: "hour", comment: "Unit for singular hour") :
                                String(localized: "hours", comment: "Unit for plural hours")
                        )
                    }

                    if let minutes = viewModel.patchLifecycleMinutes, (viewModel.patchLifecycleDays ?? -1) == 0 {
                        timeComponent(
                            value: minutes,
                            units: minutes == 1 ?
                                String(localized: "minute", comment: "Unit for singular minute") :
                                String(localized: "minutes", comment: "Unit for plural minutes")
                        )
                    }
                }
            case .expired,
                 .gracePeriod:
                HStack {
                    Text("Patch expired", comment: "Text shown when patch expired")
                        .foregroundStyle(.red)
                    Spacer()
                }
            case .expiredBasalOnly:
                HStack {
                    Text(
                        "Extended Patch expired. Basal only.",
                        comment: "Text shown when extended patch expired surpasses 120 hours"
                    )
                    .foregroundStyle(.red)
                    Spacer()
                }
            }

            ProgressView(value: viewModel.patchLifecycleProgress)
                .tint(progressColor)
                .padding(.top, -5)
        }
    }

    func timeComponent(value: Int, units: String) -> some View {
        Group {
            Text(String(value))
                .font(.system(size: 24))
                .fontWeight(.heavy)
                .foregroundColor(.primary)
            Text(units)
                .foregroundColor(.secondary)
        }
    }

    private var doneButton: some View {
        Button(String(localized: "Done", comment: "Button for closing settings"), action: {
            dismiss()
            viewModel.didFinish?()
        })
    }

    public var reservoirColor: Color {
        // TODO: Configurable??
        if viewModel.reservoirLevel > (viewModel.maxReservoirLevel * 0.1) {
            return insulinTintColor
        }

        if viewModel.reservoirLevel > 0 {
            return guidanceColors.warning
        }

        return guidanceColors.critical
    }

    public var progressColor: Color {
        switch viewModel.patchLifecycleState {
        case .active:
            return .accentColor
        case .activeLast24h:
            return guidanceColors.warning
        case .expired,
             .expiredBasalOnly,
             .gracePeriod,
             .noPatch:
            return guidanceColors.critical
        }
    }

    var connectionStatusText: some View {
        if viewModel.isReconnecting || viewModel.isUpdatingPumpState {
            return Text("Connecting…", comment: "label while BLE command in progress")
        }

        if viewModel.isConnected {
            return Text("In range", comment: "label for pump in communication range")
        }

        return Text("No connection", comment: "label for pump out of range")
    }

    var connectionStatusIcon: some View {
        let color = (viewModel.isReconnecting || viewModel.isUpdatingPumpState) ? Color.orange : viewModel.isConnected ? Color
            .green : Color.red

        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    var deliverySectionTitle: String {
        switch viewModel.basalType {
        case .basal,
             .bolus,
             .resume:
            return String(localized: "Scheduled Basal", comment: "Title of insulin delivery section")
        case .tempBasal:
            return String(localized: "Temp Basal", comment: "Pump Event title for UnfinalizedDose with doseType of .tempBasal")
        case .suspend:
            return String(localized: "Insulin Delivery", comment: "Title of insulin delivery section")
        }
    }
}

private struct EquilManualTempBasalEntryView: View {
    var enactBasal: ((Double, TimeInterval, @escaping (PumpManagerError?) -> Void) -> Void)?
    var didCancel: (() -> Void)?
    var allowedRates: [Double]

    @State private var rateEntered: Double = 0
    @State private var durationEntered: TimeInterval = .minutes(30)
    @State private var enacting = false
    @State private var error: PumpManagerError?
    @State private var showingErrorAlert = false

    private static let rateFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: DoseEntry.unitsPerHour)
        formatter.numberFormatter.minimumFractionDigits = 2
        return formatter
    }()

    private static let durationFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .hour())
        formatter.numberFormatter.minimumFractionDigits = 1
        formatter.numberFormatter.maximumFractionDigits = 1
        formatter.unitStyle = .long
        return formatter
    }()

    init(
        enactBasal: ((Double, TimeInterval, @escaping (PumpManagerError?) -> Void) -> Void)? = nil,
        didCancel: (() -> Void)? = nil,
        allowedRates: [Double]
    ) {
        self.enactBasal = enactBasal
        self.didCancel = didCancel
        self.allowedRates = allowedRates
        _rateEntered = State(initialValue: allowedRates.first(where: { $0 > 0 }) ?? 0)
    }

    private func formatRate(_ rate: Double) -> String {
        Self.rateFormatter.string(from: HKQuantity(unit: DoseEntry.unitsPerHour, doubleValue: rate)) ?? ""
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        Self.durationFormatter.string(from: HKQuantity(unit: .hour(), doubleValue: duration.hours)) ?? ""
    }

    var body: some View {
        NavigationView {
            VStack {
                List {
                    HStack {
                        Text("Rate", comment: "Label text for basal rate summary")
                        Spacer()
                        Text(
                            String(
                                format: String(
                                    localized: "%1$@ for %2$@",
                                    comment: "Summary string for temporary basal rate configuration page"
                                ),
                                formatRate(rateEntered),
                                formatDuration(durationEntered)
                            )
                        )
                    }
                    HStack {
                        ResizeablePicker(
                            selection: $rateEntered,
                            data: allowedRates,
                            formatter: { formatRate($0) }
                        )
                        ResizeablePicker(
                            selection: $durationEntered,
                            data: EquilKitSettingsViewModel.supportedTempBasalDurations,
                            formatter: { formatDuration($0) }
                        )
                    }
                    .frame(maxHeight: 162)

                    Section {
                        Text(
                            "Your insulin delivery will not be automatically adjusted until the temporary basal rate finishes or is canceled.",
                            comment: "Description text on manual temp basal action sheet"
                        )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    enacting = true
                    enactBasal?(rateEntered, durationEntered) { enactError in
                        if let enactError {
                            error = enactError
                            showingErrorAlert = true
                        }
                        enacting = false
                    }
                } label: {
                    HStack {
                        if enacting {
                            ProgressView()
                        } else {
                            Text("Set Temporary Basal", comment: "Button text for setting manual temporary basal rate")
                        }
                    }
                }
                .buttonStyle(ActionButtonStyle(.primary))
                .padding()
            }
            .navigationTitle(String(localized: "Temporary Basal", comment: "Navigation Title for manual temp basal"))
            .navigationBarItems(trailing: Button(String(localized: "Cancel", comment: "Cancel manual temp basal")) {
                didCancel?()
            })
            .alert(isPresented: $showingErrorAlert) {
                Alert(
                    title: Text("Temporary Basal Failed", comment: "Alert title for temp basal failure"),
                    message: Text(error?.localizedDescription ?? "")
                )
            }
            .disabled(enacting || allowedRates.isEmpty)
        }
    }
}
