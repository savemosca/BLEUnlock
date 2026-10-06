import Foundation

// Hardware-independent proximity state. All calls and callbacks use the main run loop.
final class ProximityMonitor {
    static let unlockDisabled = 1
    static let lockDisabled = -100

    private enum Presence { case unknown, present, absent }
    private var state = Presence.unknown
    private var monitoring = false
    private var suspended = false
    private var samples: [Int] = []
    private var proximityTask: ScheduledTask?
    private var signalTask: ScheduledTask?
    private let scheduler: Scheduler

    var onPresenceChanged: ((Bool, String) -> Void)?
    var onRSSI: ((Int?) -> Void)?
    var presence: Bool { state == .present }
    var hasKnownPresence: Bool { state != .unknown }
    var acceptsReadings: Bool { monitoring && !suspended }
    var lockRSSI = -80 {
        didSet { if acceptsReadings { start() } }
    }
    var unlockRSSI = -60 {
        didSet { if acceptsReadings { start() } }
    }
    var proximityTimeout: TimeInterval = 5
    var signalTimeout: TimeInterval = 60 {
        didSet { if acceptsReadings { resetSignalTimer() } }
    }

    init(scheduler: Scheduler = MainRunLoopScheduler()) {
        self.scheduler = scheduler
    }

    static func isValidRSSI(_ rssi: Int) -> Bool {
        // Bluetooth LE RSSI range; 127 means unavailable, not a strong signal.
        (-127...20).contains(rssi)
    }

    func start() {
        cancelTimers()
        samples.removeAll()
        state = .unknown
        monitoring = true
        suspended = false
        onRSSI?(nil)
        resetSignalTimer()
    }

    func stop() {
        cancelTimers()
        monitoring = false
        state = .unknown
        samples.removeAll()
    }

    func suspend() {
        suspended = true
        cancelTimers()
        state = .unknown
        samples.removeAll()
        onRSSI?(nil)
    }

    func resume() {
        guard monitoring else { return }
        start()
    }

    func bluetoothAvailable() {
        guard acceptsReadings else { return }
        resetSignalTimer()
    }

    func bluetoothUnavailable() {
        guard acceptsReadings else { return }
        cancelTimers()
        samples.removeAll()
        reportAbsence(reason: "lost")
    }

    @discardableResult
    func receiveRSSI(_ rssi: Int, failed: Bool = false) -> Bool {
        guard acceptsReadings, !failed, Self.isValidRSSI(rssi) else { return false }
        let closeThreshold = unlockRSSI == Self.unlockDisabled ? lockRSSI : unlockRSSI
        let becamePresent = !presence && rssi >= closeThreshold
        if becamePresent { samples.removeAll() }
        samples.append(rssi)
        if samples.count > 5 { samples.removeFirst() }
        let estimatedRSSI = samples.reduce(0, +) / samples.count
        onRSSI?(estimatedRSSI)
        if becamePresent {
            state = .present
            onPresenceChanged?(true, "close")
        }

        let awayThreshold = lockRSSI == Self.lockDisabled ? unlockRSSI : lockRSSI
        if estimatedRSSI >= awayThreshold {
            proximityTask?.cancel()
            proximityTask = nil
        } else if state != .absent && proximityTask == nil {
            proximityTask = scheduler.schedule(after: proximityTimeout) { [weak self] in
                guard let self = self else { return }
                self.proximityTask = nil
                self.reportAbsence(reason: "away")
            }
        }
        resetSignalTimer()
        return true
    }

    private func resetSignalTimer() {
        signalTask?.cancel()
        signalTask = scheduler.schedule(after: signalTimeout) { [weak self] in
            guard let self = self else { return }
            self.signalTask = nil
            self.proximityTask?.cancel()
            self.proximityTask = nil
            self.reportAbsence(reason: "lost")
        }
    }

    private func reportAbsence(reason: String) {
        if reason == "lost" { onRSSI?(nil) }
        guard state != .absent else { return }
        state = .absent
        onPresenceChanged?(false, reason)
    }

    private func cancelTimers() {
        proximityTask?.cancel()
        proximityTask = nil
        signalTask?.cancel()
        signalTask = nil
    }

    deinit { cancelTimers() }
}
