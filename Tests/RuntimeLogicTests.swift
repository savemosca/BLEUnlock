import XCTest
@testable import BLEUnlockLogic

private final class TestTask: ScheduledTask {
    let deadline: TimeInterval
    let action: () -> Void
    var cancelled = false
    var executed = false
    init(deadline: TimeInterval, action: @escaping () -> Void) {
        self.deadline = deadline
        self.action = action
    }
    func cancel() { cancelled = true }
}

private final class TestScheduler: Scheduler {
    var now: TimeInterval = 0
    private var tasks: [TestTask] = []
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledTask {
        let task = TestTask(deadline: now + delay, action: action)
        tasks.append(task)
        return task
    }
    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = tasks.filter({ !$0.cancelled && !$0.executed && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline }) {
            now = next.deadline
            next.executed = true
            next.action()
        }
        now = target
    }
}

final class ProximityMonitorTests: XCTestCase {
    func testUnknownDeviceCannotAuthorizeUnlockAndEventuallyReportsLoss() {
        let scheduler = TestScheduler()
        let monitor = ProximityMonitor(scheduler: scheduler)
        var reasons: [String] = []
        monitor.onPresenceChanged = { _, reason in reasons.append(reason) }
        monitor.signalTimeout = 120
        monitor.start()
        XCTAssertFalse(monitor.presence)
        XCTAssertFalse(monitor.hasKnownPresence)
        scheduler.advance(by: 60)
        XCTAssertTrue(reasons.isEmpty)
        scheduler.advance(by: 60)
        XCTAssertEqual(reasons, ["lost"])
        XCTAssertTrue(monitor.hasKnownPresence)
    }

    func testInvalidAndFailedReadingsDoNotAuthorizeUnlockOrExtendTimeout() {
        let scheduler = TestScheduler()
        let monitor = ProximityMonitor(scheduler: scheduler)
        var reasons: [String] = []
        monitor.onPresenceChanged = { _, reason in reasons.append(reason) }
        monitor.start()
        scheduler.advance(by: 50)
        for rssi in [127, 21, -128, Int.max] {
            XCTAssertFalse(monitor.receiveRSSI(rssi))
        }
        XCTAssertFalse(monitor.receiveRSSI(-30, failed: true))
        XCTAssertFalse(monitor.presence)
        scheduler.advance(by: 10)
        XCTAssertEqual(reasons, ["lost"])
    }

    func testBluetoothLossReportsAbsenceOnceAndRequiresFreshSignal() {
        let scheduler = TestScheduler()
        let monitor = ProximityMonitor(scheduler: scheduler)
        var reasons: [String] = []
        monitor.onPresenceChanged = { _, reason in reasons.append(reason) }
        monitor.start()
        monitor.receiveRSSI(-40)
        monitor.bluetoothUnavailable()
        monitor.bluetoothUnavailable()
        XCTAssertFalse(monitor.presence)
        XCTAssertEqual(reasons, ["close", "lost"])
        monitor.bluetoothAvailable()
        XCTAssertFalse(monitor.presence)
        monitor.receiveRSSI(-40)
        XCTAssertTrue(monitor.presence)
        XCTAssertEqual(reasons, ["close", "lost", "close"])
    }

    func testSwitchingDeviceClearsPendingDelayAndPreviousSamples() {
        let scheduler = TestScheduler()
        let monitor = ProximityMonitor(scheduler: scheduler)
        var reasons: [String] = []
        monitor.onPresenceChanged = { _, reason in reasons.append(reason) }
        monitor.start()
        monitor.receiveRSSI(-40)
        for _ in 0..<5 { monitor.receiveRSSI(-95) }
        scheduler.advance(by: 2)
        monitor.start()
        monitor.receiveRSSI(-90)
        scheduler.advance(by: 3)
        XCTAssertEqual(reasons, ["close"])
        scheduler.advance(by: 2)
        XCTAssertEqual(reasons, ["close", "away"])
    }

    func testReturnWithinLockDelayCancelsDistanceLock() {
        let scheduler = TestScheduler()
        let monitor = ProximityMonitor(scheduler: scheduler)
        var reasons: [String] = []
        monitor.onPresenceChanged = { _, reason in reasons.append(reason) }
        monitor.start()
        monitor.receiveRSSI(-40)
        for _ in 0..<5 { monitor.receiveRSSI(-95) }
        scheduler.advance(by: 2)
        for _ in 0..<5 { monitor.receiveRSSI(-40) }
        scheduler.advance(by: 5)
        XCTAssertTrue(monitor.presence)
        XCTAssertEqual(reasons, ["close"])
    }

    func testSleepSuppressesLossAndWakeRequiresNewReading() {
        let scheduler = TestScheduler()
        let monitor = ProximityMonitor(scheduler: scheduler)
        var reasons: [String] = []
        monitor.onPresenceChanged = { _, reason in reasons.append(reason) }
        monitor.start()
        monitor.receiveRSSI(-40)
        monitor.suspend()
        monitor.bluetoothUnavailable()
        XCTAssertFalse(monitor.receiveRSSI(-40))
        scheduler.advance(by: 3600)
        XCTAssertEqual(reasons, ["close"])
        monitor.resume()
        XCTAssertFalse(monitor.presence)
        XCTAssertFalse(monitor.hasKnownPresence)
        monitor.receiveRSSI(-40)
        XCTAssertTrue(monitor.presence)
    }

    func testDisabledUnlockUsesLockThresholdForProximity() {
        let monitor = ProximityMonitor(scheduler: TestScheduler())
        monitor.unlockRSSI = ProximityMonitor.unlockDisabled
        monitor.start()
        monitor.receiveRSSI(-75)
        XCTAssertTrue(monitor.presence)
    }

    func testLossAfterDistanceLockDoesNotEmitSecondLock() {
        let scheduler = TestScheduler()
        let monitor = ProximityMonitor(scheduler: scheduler)
        var reasons: [String] = []
        monitor.onPresenceChanged = { _, reason in reasons.append(reason) }
        monitor.start()
        monitor.receiveRSSI(-90)
        scheduler.advance(by: 60)
        XCTAssertEqual(reasons, ["away"])
    }

    func testChangingThresholdRequiresNewSignalBeforeUnlock() {
        let monitor = ProximityMonitor(scheduler: TestScheduler())
        monitor.start()
        monitor.receiveRSSI(-50)
        XCTAssertTrue(monitor.presence)
        monitor.unlockRSSI = -40
        XCTAssertFalse(monitor.presence)
        monitor.receiveRSSI(-50)
        XCTAssertFalse(monitor.presence)
        monitor.receiveRSSI(-30)
        XCTAssertTrue(monitor.presence)
    }
}

final class UnlockCoordinatorTests: XCTestCase {
    func testPendingUnlockRechecksEveryConditionBeforeReadingPassword() {
        let changes: [(inout UnlockConditions) -> Void] = [
            { $0.screenLocked = false }, { $0.devicePresent = false },
            { $0.manualLock = true }, { $0.unlockingEnabled = false },
            { $0.systemSleeping = true }, { $0.displaySleeping = true },
            { $0.lockOnly = true }, { $0.wakeWithoutUnlocking = true },
            { $0.accessibilityTrusted = false }
        ]
        for change in changes {
            let scheduler = TestScheduler()
            var conditions = UnlockConditions(screenLocked: true, devicePresent: true)
            var passwordReads = 0
            let coordinator = UnlockCoordinator(scheduler: scheduler, conditions: { conditions },
                fetchPassword: { passwordReads += 1; return "test" },
                enterPassword: { _ in XCTFail("Stale unlock must not type"); return true })
            coordinator.requestUnlock()
            change(&conditions)
            scheduler.advance(by: 1)
            XCTAssertEqual(passwordReads, 0)
            XCTAssertFalse(coordinator.didUnlock())
        }
    }

    func testRechecksConditionsAfterKeychainPromptReturns() {
        let scheduler = TestScheduler()
        var conditions = UnlockConditions(screenLocked: true, devicePresent: true)
        let coordinator = UnlockCoordinator(scheduler: scheduler, conditions: { conditions },
            fetchPassword: { conditions.devicePresent = false; return "test" },
            enterPassword: { _ in XCTFail("Device was lost during prompt"); return true })
        coordinator.requestUnlock()
        scheduler.advance(by: 1)
        XCTAssertFalse(coordinator.didUnlock())
    }

    func testCancellationDuringKeychainPromptPreventsEntryEvenIfStateRecovers() {
        let scheduler = TestScheduler()
        var coordinator: UnlockCoordinator!
        coordinator = UnlockCoordinator(scheduler: scheduler,
            conditions: { UnlockConditions(screenLocked: true, devicePresent: true) },
            fetchPassword: { coordinator.cancel(); return "test" },
            enterPassword: { _ in XCTFail("Cancelled request must not type"); return true })
        coordinator.requestUnlock()
        scheduler.advance(by: 1)
        XCTAssertFalse(coordinator.didUnlock())
        coordinator = nil
    }

    func testDuplicateWakeRequestsTypeOnceAndOnlyActualUnlockConsumesAttempt() {
        let scheduler = TestScheduler()
        var attempts = 0
        let coordinator = UnlockCoordinator(scheduler: scheduler, now: { scheduler.now },
            conditions: { UnlockConditions(screenLocked: true, devicePresent: true) },
            fetchPassword: { "test" }, enterPassword: { _ in attempts += 1; return true })
        coordinator.requestUnlock()
        coordinator.requestUnlock()
        scheduler.advance(by: 1)
        XCTAssertEqual(attempts, 1)
        coordinator.requestUnlock()
        scheduler.advance(by: 1)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(coordinator.didUnlock())
        XCTAssertFalse(coordinator.didUnlock())
    }

    func testInterruptedEntryAndMissingPasswordDoNotCountAsAutomaticUnlock() {
        for password in [nil, "test"] as [String?] {
            let scheduler = TestScheduler()
            let coordinator = UnlockCoordinator(scheduler: scheduler,
                conditions: { UnlockConditions(screenLocked: true, devicePresent: true) },
                fetchPassword: { password }, enterPassword: { _ in false })
            coordinator.requestUnlock()
            scheduler.advance(by: 1)
            XCTAssertFalse(coordinator.didUnlock())
        }
    }

    func testRejectedPasswordDoesNotClassifyLaterManualUnlockAsAutomatic() {
        let scheduler = TestScheduler()
        let coordinator = UnlockCoordinator(scheduler: scheduler, now: { scheduler.now },
            conditions: { UnlockConditions(screenLocked: true, devicePresent: true) },
            fetchPassword: { "incorrect" }, enterPassword: { _ in true })
        coordinator.requestUnlock()
        scheduler.advance(by: 11)
        XCTAssertFalse(coordinator.didUnlock())
    }

    func testCancellationDiscardsPendingAndCompletedAttempts() {
        let scheduler = TestScheduler()
        var attempts = 0
        let coordinator = UnlockCoordinator(scheduler: scheduler,
            conditions: { UnlockConditions(screenLocked: true, devicePresent: true) },
            fetchPassword: { "test" }, enterPassword: { _ in attempts += 1; return true })
        coordinator.requestUnlock()
        coordinator.cancel()
        scheduler.advance(by: 1)
        XCTAssertEqual(attempts, 0)
        coordinator.requestUnlock()
        scheduler.advance(by: 1)
        coordinator.cancel()
        XCTAssertFalse(coordinator.didUnlock())
    }

    func testCancellationDuringEntryDoesNotRestoreAutomaticAttempt() {
        let scheduler = TestScheduler()
        var coordinator: UnlockCoordinator!
        coordinator = UnlockCoordinator(scheduler: scheduler,
            conditions: { UnlockConditions(screenLocked: true, devicePresent: true) },
            fetchPassword: { "test" },
            enterPassword: { _ in coordinator.cancel(); return true })
        coordinator.requestUnlock()
        scheduler.advance(by: 1)
        XCTAssertFalse(coordinator.didUnlock())
        coordinator = nil
    }
}

final class LoginMigrationTests: XCTestCase {
    private enum Failure: Error { case failed }

    func testRegistrationFailureKeepsLegacyLoginItem() {
        XCTAssertThrowsError(try migrateLoginService(status: { .notRegistered },
            register: { throw Failure.failed },
            disableLegacy: { XCTFail("Legacy item must survive failed registration") }))
    }

    func testPendingApprovalKeepsLegacyLoginItemAndDoesNotFinishMigration() throws {
        var status = LoginServiceStatus.notRegistered
        let result = try migrateLoginService(status: { status },
            register: { status = .requiresApproval },
            disableLegacy: { XCTFail("Keep legacy item until replacement can run") })
        XCTAssertEqual(result, .requiresApproval)
    }

    func testLegacyIsRemovedOnlyAfterReplacementIsEnabled() throws {
        var status = LoginServiceStatus.notRegistered
        var disabledLegacy = false
        let result = try migrateLoginService(status: { status },
            register: { status = .enabled }, disableLegacy: { disabledLegacy = true })
        XCTAssertTrue(disabledLegacy)
        XCTAssertEqual(result, .complete)
    }

    func testLegacyRemovalFailureIsRetriable() {
        XCTAssertThrowsError(try migrateLoginService(status: { .enabled },
            register: { XCTFail("Already registered") },
            disableLegacy: { throw Failure.failed }))
    }

    func testUnavailableServiceKeepsLegacyItem() throws {
        let result = try migrateLoginService(status: { .unavailable },
            register: { XCTFail("Cannot register missing service") },
            disableLegacy: { XCTFail("Legacy item must survive") })
        XCTAssertEqual(result, .unavailable)
    }
}
