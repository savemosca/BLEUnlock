import Foundation

protocol ScheduledTask {
    func cancel()
}

protocol Scheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledTask
}

struct MainRunLoopScheduler: Scheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledTask {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return TimerTask(timer: timer)
    }
}

private final class TimerTask: ScheduledTask {
    let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
    deinit { cancel() }
}
