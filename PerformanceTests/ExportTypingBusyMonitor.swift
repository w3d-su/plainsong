import Darwin
import Foundation

/// Every stretch between the main run loop waking and going back to sleep, with the main
/// thread's CPU time in it. Adapted from `MainRunLoopBusyMonitor` in the PlainsongTests
/// target, which this bundle cannot import. The wake callback runs before every other
/// observer and the sleep callback after every other one, so a slice also covers work
/// that observers do just before the thread sleeps, such as Core Animation's commit.
@MainActor
final class ExportTypingBusyMonitor {
    private var observers: [CFRunLoopObserver] = []
    private var wokeAt: UInt64?
    private var cpuAtWake: Double = 0
    private var startedAt: UInt64 = 0
    private var slices: [ExportBusyWindow.Slice] = []

    func start() {
        let wake = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.record(activity) }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.record(activity) }
        }
        observers = [wake, sleep].compactMap { $0 }
        for observer in observers {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        slices = []
        startedAt = DispatchTime.now().uptimeNanoseconds
        wokeAt = startedAt
        cpuAtWake = Self.threadCPUMilliseconds()
    }

    func stop() -> [ExportBusyWindow.Slice] {
        for observer in observers {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observers = []
        // The stretch the caller is still in when it stops counts too.
        if let wokeAt {
            append(from: wokeAt, to: DispatchTime.now().uptimeNanoseconds)
        }
        wokeAt = nil
        return slices
    }

    private func record(_ activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        if activity == .afterWaiting {
            wokeAt = now
            cpuAtWake = Self.threadCPUMilliseconds()
        } else if let wokeAt {
            append(from: wokeAt, to: now)
            self.wokeAt = nil
        }
    }

    private func append(from start: UInt64, to end: UInt64) {
        slices.append(ExportBusyWindow.Slice(
            startMilliseconds: Double(start - startedAt) / 1_000_000,
            wallMilliseconds: Double(end - start) / 1_000_000,
            cpuMilliseconds: Self.threadCPUMilliseconds() - cpuAtWake
        ))
    }

    /// The calling thread's CPU time; every caller is on the main actor.
    static func threadCPUMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
    }
}
