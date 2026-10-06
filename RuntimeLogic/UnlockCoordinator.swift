import Foundation

struct UnlockConditions {
    var screenLocked = false
    var devicePresent = false
    var manualLock = false
    var unlockingEnabled = true
    var systemSleeping = false
    var displaySleeping = false
    var lockOnly = false
    var wakeWithoutUnlocking = false
    var accessibilityTrusted = true

    var canUnlock: Bool {
        screenLocked && devicePresent && !manualLock && unlockingEnabled &&
        !systemSleeping && !displaySleeping && !lockOnly && !wakeWithoutUnlocking && accessibilityTrusted
    }
}

final class UnlockCoordinator {
    private let scheduler: Scheduler
    private let now: () -> TimeInterval
    private let conditions: () -> UnlockConditions
    private let fetchPassword: () -> String?
    private let enterPassword: (String) -> Bool
    private var pendingTask: ScheduledTask?
    private var generation = 0
    private var enteringPassword = false
    private var attemptedAt: TimeInterval?

    init(scheduler: Scheduler = MainRunLoopScheduler(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         conditions: @escaping () -> UnlockConditions,
         fetchPassword: @escaping () -> String?,
         enterPassword: @escaping (String) -> Bool) {
        self.scheduler = scheduler
        self.now = now
        self.conditions = conditions
        self.fetchPassword = fetchPassword
        self.enterPassword = enterPassword
    }

    func requestUnlock() {
        guard conditions().canUnlock, pendingTask == nil, !enteringPassword else { return }
        // A second wake notification must not append the password again while macOS
        // is still processing the first submission. A failed attempt can expire.
        if let attemptedAt = attemptedAt, now() - attemptedAt < 10 { return }
        let requestedGeneration = generation
        pendingTask = scheduler.schedule(after: 0.5) { [weak self] in
            guard let self = self else { return }
            self.pendingTask = nil
            guard self.generation == requestedGeneration, self.conditions().canUnlock else { return }
            self.enteringPassword = true
            defer { self.enteringPassword = false }
            // Keychain may show a modal prompt. Recheck after it returns as well.
            guard let password = self.fetchPassword(),
                  self.generation == requestedGeneration,
                  self.conditions().canUnlock else { return }
            if self.enterPassword(password), self.generation == requestedGeneration {
                self.attemptedAt = self.now()
            }
        }
    }

    func cancel() {
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        attemptedAt = nil
    }

    // Called only on an actual macOS unlock notification, never after merely typing.
    func didUnlock() -> Bool {
        let automatic = attemptedAt.map { now() - $0 < 10 } ?? false
        cancel()
        return automatic
    }

    deinit { pendingTask?.cancel() }
}
