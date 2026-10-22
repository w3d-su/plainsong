import Foundation

extension NSRange {
    func clamped(toLength length: Int) -> NSRange {
        guard location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let clampedLocation = min(max(location, 0), length)
        let clampedEnd = min(max(location + self.length, clampedLocation), length)
        return NSRange(location: clampedLocation, length: clampedEnd - clampedLocation)
    }
}
