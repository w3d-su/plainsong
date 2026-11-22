import QuartzCore
import UIKit

/// Two main-thread observations the probe times a keystroke against: the end of the run
/// loop turn that committed it, and the next display refresh. Both read the same clock as
/// `CACurrentMediaTime()`.
@MainActor
final class IOSPerformanceFrameClock: NSObject {
    private var link: CADisplayLink?
    private var refreshWaiters: [(after: CFTimeInterval, continuation: CheckedContinuation<CFTimeInterval, Never>)] = []
    private(set) var lastFrameInterval: CFTimeInterval?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Ask for the panel's full rate. An iPhone grants more than 60 Hz only when the
        // app's Info.plist opts in; `lastFrameInterval` records what was granted.
        let maximum = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        let waiters = refreshWaiters
        refreshWaiters = []
        let now = CACurrentMediaTime()
        for waiter in waiters {
            waiter.continuation.resume(returning: now)
        }
    }

    /// Returns when the main run loop is about to sleep, after Core Animation's own
    /// before-waiting observer committed the pending transaction. Layout and drawing for
    /// an edit made in this turn are done by then.
    func afterCommit() async -> CFTimeInterval {
        await withCheckedContinuation { continuation in
            let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault,
                CFRunLoopActivity.beforeWaiting.rawValue,
                false,
                CFIndex.max
            ) { _, _ in
                continuation.resume(returning: CACurrentMediaTime())
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    /// The timestamp of the first display refresh at or after `time`.
    func refresh(atOrAfter time: CFTimeInterval) async -> CFTimeInterval {
        guard link != nil else { return CACurrentMediaTime() }
        return await withCheckedContinuation { continuation in
            refreshWaiters.append((time, continuation))
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        lastFrameInterval = link.targetTimestamp - link.timestamp
        guard !refreshWaiters.isEmpty else { return }
        var waiting: [(after: CFTimeInterval, continuation: CheckedContinuation<CFTimeInterval, Never>)] = []
        for waiter in refreshWaiters {
            if link.timestamp >= waiter.after {
                waiter.continuation.resume(returning: link.timestamp)
            } else {
                waiting.append(waiter)
            }
        }
        refreshWaiters = waiting
    }
}
