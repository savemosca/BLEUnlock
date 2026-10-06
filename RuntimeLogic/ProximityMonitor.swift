import Foundation

// Hardware-independent proximity state. All calls and callbacks use the main run loop.
final class ProximityMonitor {
    static let unlockDisabled = 1
    static let lockDisabled = -100

    private enum Presence { case unknown, present, absent }
    private var state = Presence.unknown
    private var monitoring = false
    private var suspended = false
    // The device was present when the system went to sleep, so a fresh reading within
    // lock range restores presence, as if monitoring had not been interrupted.
    private var restorePresence = false
    private var samples: [Int] = []
    private var proximityTask: ScheduledTask?
    private var signalTask: ScheduledTask?
    private var rangeWaiters: [(Bool) -> Void] = []
    private var rangeTask: ScheduledTask?
    private let scheduler: Scheduler

    var onPresenceChanged: ((Bool, String) -> Void)?
    var onRSSI: ((Int?) -> Void)?
    var presence: Bool { state == .present }
    var hasKnownPresence: Bool { state != .unknown }
    var acceptsReadings: Bool { monitoring && !suspended }
    var lockRSSI = -80 {
        didSet { if lockRSSI != oldValue && acceptsReadings { start() } }
    }
    var unlockRSSI = -60 {
        didSet { if unlockRSSI != oldValue && acceptsReadings { start() } }
    }
    var proximityTimeout: TimeInterval = 5
    var signalTimeout: TimeInterval = 60 {
        didSet { if acceptsReadings { resetSignalTimer() } }
    }

    private var closeThreshold: Int { unlockRSSI == Self.unlockDisabled ? lockRSSI : unlockRSSI }
    private var awayThreshold: Int { lockRSSI == Self.lockDisabled ? unlockRSSI : lockRSSI }
    private var estimatedRSSI: Int? { samples.isEmpty ? nil : samples.reduce(0, +) / samples.count }

    // Whether the device is within lock range, nil until a fresh reading arrives. Unlike
    // `presence`, a device between the lock and unlock thresholds counts as in range
    // even before it has come close enough to unlock.
    var isInRange: Bool? {
        switch state {
        case .present: return true
        case .absent: return false
        case .unknown: return estimatedRSSI.map { $0 >= awayThreshold }
        }
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
        restorePresence = false
        monitoring = true
        suspended = false
        onRSSI?(nil)
        resetSignalTimer()
    }

    func stop() {
        cancelTimers()
        monitoring = false
        state = .unknown
        restorePresence = false
        samples.removeAll()
    }

    func suspend() {
        if !suspended { restorePresence = state == .present }
        suspended = true
        cancelTimers()
        state = .unknown
        samples.removeAll()
        onRSSI?(nil)
    }

    func resume() {
        guard monitoring else { return }
        let restore = restorePresence
        start()
        restorePresence = restore
    }

    func bluetoothAvailable() {
        guard acceptsReadings else { return }
        resetSignalTimer()
    }

    func bluetoothUnavailable() {
        guard acceptsReadings else { return }
        cancelTimers()
        samples.removeAll()
        restorePresence = false
        reportAbsence(reason: "lost")
    }

    // Calls `completion` once `isInRange` is known, or with false if no reading arrives
    // within `timeout`. Nothing is reported while no device is monitored.
    func whenRangeKnown(timeout: TimeInterval, _ completion: @escaping (Bool) -> Void) {
        guard monitoring else { return }
        if !suspended, let inRange = isInRange {
            completion(inRange)
            return
        }
        rangeWaiters.append(completion)
        rangeTask?.cancel()
        rangeTask = scheduler.schedule(after: timeout) { [weak self] in
            self?.resolveRange(false)
        }
    }

    @discardableResult
    func receiveRSSI(_ rssi: Int, failed: Bool = false) -> Bool {
        guard acceptsReadings, !failed, Self.isValidRSSI(rssi) else { return false }
        let becamePresent = !presence && rssi >= (restorePresence ? awayThreshold : closeThreshold)
        restorePresence = false
        if becamePresent { samples.removeAll() }
        samples.append(rssi)
        if samples.count > 5 { samples.removeFirst() }
        let estimatedRSSI = samples.reduce(0, +) / samples.count
        onRSSI?(estimatedRSSI)
        if becamePresent {
            state = .present
            onPresenceChanged?(true, "close")
        }

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
        if let inRange = isInRange { resolveRange(inRange) }
        return true
    }

    private func resetSignalTimer() {
        signalTask?.cancel()
        signalTask = scheduler.schedule(after: signalTimeout) { [weak self] in
            guard let self = self else { return }
            self.signalTask = nil
            self.proximityTask?.cancel()
            self.proximityTask = nil
            self.restorePresence = false
            self.reportAbsence(reason: "lost")
        }
    }

    private func reportAbsence(reason: String) {
        if reason == "lost" { onRSSI?(nil) }
        defer { resolveRange(false) }
        guard state != .absent else { return }
        state = .absent
        onPresenceChanged?(false, reason)
    }

    private func resolveRange(_ inRange: Bool) {
        rangeTask?.cancel()
        rangeTask = nil
        let waiters = rangeWaiters
        rangeWaiters.removeAll()
        waiters.forEach { $0(inRange) }
    }

    private func cancelTimers() {
        proximityTask?.cancel()
        proximityTask = nil
        signalTask?.cancel()
        signalTask = nil
    }

    deinit {
        cancelTimers()
        rangeTask?.cancel()
    }
}
