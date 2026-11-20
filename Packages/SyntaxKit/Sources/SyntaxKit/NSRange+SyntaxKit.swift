import Foundation

extension NSRange {
    func clamped(toLength length: Int) -> NSRange {
        guard location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let clampedLocation = min(max(location, 0), length)
        // An unvalidated caller range can have `location + length` past `Int.max`.
        let (sum, overflow) = location.addingReportingOverflow(self.length)
        let end = overflow ? (self.length > 0 ? Int.max : Int.min) : sum
        let clampedEnd = min(max(end, clampedLocation), length)
        return NSRange(location: clampedLocation, length: clampedEnd - clampedLocation)
    }
}
