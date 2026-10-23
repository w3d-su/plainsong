import Foundation

/// The code units of one source string: contiguous UTF-8 bytes of a native string, or
/// UTF-16 units of a bridged one. Only ASCII values are compared, and every non-ASCII
/// code unit is at least 0x80 in both encodings, so the line rules read either the same.
///
/// The loops walk raw pointers and search with `memchr` because the hosted test gates
/// run unoptimized builds, where `Range` and generic iteration are far slower.
struct MarkdownFenceScanUnits {
    private let utf8: UnsafePointer<UInt8>?
    private let utf16: UnsafePointer<UInt16>?
    /// Native source for UTF-8 ↔ UTF-16 offset conversion; `nil` for UTF-16 units.
    private let source: String?
    let count: Int

    init(utf8 bytes: UnsafeBufferPointer<UInt8>, source: String) {
        utf8 = bytes.baseAddress
        utf16 = nil
        self.source = source
        count = bytes.count
    }

    init(utf16 units: UnsafePointer<UInt16>, count: Int) {
        utf8 = nil
        utf16 = units
        source = nil
        self.count = count
    }

    subscript(index: Int) -> UInt16 {
        if let utf8 {
            return UInt16(utf8[index])
        }
        return utf16![index]
    }

    /// Index of the first unit equal to the ASCII `value` at or after `start`, or `count`.
    func firstIndex(of value: UInt8, from start: Int) -> Int {
        guard start < count else {
            return count
        }

        if let utf8 {
            guard let found = memchr(utf8 + start, Int32(value), count - start) else {
                return count
            }
            return UnsafeRawPointer(utf8).distance(to: UnsafeRawPointer(found))
        }

        // Search the UTF-16 bytes for the low byte, then confirm the whole unit: a match
        // can be either byte of an unrelated unit such as U+4E0A.
        let bytes = UnsafeRawPointer(utf16!)
        let byteCount = count * 2
        var byteOffset = start * 2
        while byteOffset < byteCount {
            guard let found = memchr(bytes + byteOffset, Int32(value), byteCount - byteOffset) else {
                return count
            }
            let unitIndex = bytes.distance(to: UnsafeRawPointer(found)) / 2
            if utf16![unitIndex] == UInt16(value) {
                return unitIndex
            }
            byteOffset = (unitIndex + 1) * 2
        }
        return count
    }

    /// The unit bound such that lines starting before it are exactly the lines starting
    /// before UTF-16 `offset`. The line containing `offset - 1` is the last such line,
    /// so rounding a surrogate-pair offset down to its scalar cannot cross a line.
    func unitLimit(beforeUTF16Offset offset: Int) -> Int {
        guard offset > 0 else {
            return 0
        }
        guard let source else {
            return min(offset, count)
        }

        let utf16 = source.utf16
        guard offset <= utf16.count else {
            return count
        }
        let index = utf16.index(utf16.startIndex, offsetBy: offset - 1)
        return source.utf8.distance(from: source.utf8.startIndex, to: index) + 1
    }

    /// UTF-16 offset of the scalar-aligned unit `unit`.
    func utf16Offset(ofUnit unit: Int) -> Int {
        guard let source else {
            return unit
        }

        let index = source.utf8.index(source.utf8.startIndex, offsetBy: unit)
        return source.utf16.distance(from: source.utf16.startIndex, to: index)
    }

    func publicFence(_ fence: MarkdownFenceLineScan.OpenFence) -> MarkdownFence {
        MarkdownFence(
            marker: fence.marker == 0x60 ? .backtick : .tilde,
            length: fence.length,
            openingLineStart: utf16Offset(ofUnit: fence.lineStart)
        )
    }
}

/// Consumes source lines one at a time and tracks the open fence.
///
/// ASCII values are literals: `0x0A` LF, `0x0D` CR, `0x20` space, `0x09` tab, `0x60`
/// backtick, `0x7E` tilde, `0x2D` `-`, `0x2B` `+`. Static constants would cost a lazy
/// global accessor call per comparison in unoptimized builds.
struct MarkdownFenceLineScan {
    struct OpenFence {
        let marker: UInt16
        let length: Int
        /// Unit index of the opening line's first unit.
        let lineStart: Int
    }

    let units: MarkdownFenceScanUnits
    /// `.commonMark` indentation: at most three spaces and no tab.
    private let isCommonMark: Bool
    /// Unit index of the next line to consume.
    private(set) var position = 0
    private(set) var openFence: OpenFence?
    /// Unit index just past the leading frontmatter block, or 0 when there is none.
    private(set) var frontmatterEnd = 0
    /// Cached next `\r`; documents without one search for it once.
    private var nextCarriageReturn = -1

    init(units: MarkdownFenceScanUnits, indentation: MarkdownFenceScanner.Indentation) {
        self.units = units
        isCommonMark = indentation == .commonMark
        frontmatterEnd = scanFrontmatter()
        position = frontmatterEnd
        // An unclosed frontmatter search may have cached a `\r` past an earlier one.
        nextCarriageReturn = -1
    }

    /// Consumes the line at `position`. Returns `true` when it closed the open fence.
    @discardableResult
    mutating func consumeLine() -> Bool {
        let lineStart = position
        guard let line = readFenceLine() else {
            return false
        }

        if let open = openFence {
            guard line.marker == open.marker, line.length >= open.length, line.restIsBlank else {
                return false
            }
            openFence = nil
            return true
        }

        if line.marker == 0x7E || !line.restHasBacktick {
            openFence = OpenFence(marker: line.marker, length: line.length, lineStart: lineStart)
        }
        return false
    }

    private struct FenceLine {
        let marker: UInt16
        let length: Int
        /// Only spaces and tabs follow the marker run.
        let restIsBlank: Bool
        let restHasBacktick: Bool
    }

    /// Moves `position` past the current line and returns its marker run when the line
    /// is a fence line.
    private mutating func readFenceLine() -> FenceLine? {
        let count = units.count
        guard let runStart = fenceRunStart(at: position) else {
            position = fullLineEnd(terminatorAt: nextTerminator(from: position))
            return nil
        }

        let marker = units[runStart]
        var index = runStart
        while index < count, units[index] == marker {
            index += 1
        }
        let length = index - runStart
        guard length >= 3 else {
            position = fullLineEnd(terminatorAt: nextTerminator(from: index))
            return nil
        }

        var restIsBlank = true
        var restHasBacktick = false
        while index < count {
            let rest = units[index]
            if rest == 0x0A || rest == 0x0D {
                break
            }
            if rest == 0x60 {
                restHasBacktick = true
                restIsBlank = false
            } else if rest != 0x20, rest != 0x09 {
                restIsBlank = false
            }
            index += 1
        }
        position = fullLineEnd(terminatorAt: index)
        return FenceLine(marker: marker, length: length, restIsBlank: restIsBlank, restHasBacktick: restHasBacktick)
    }

    /// Index of the first `` ` `` or `~` after the line's indentation, or `nil` when the
    /// line starts with anything else or the indentation rule rejects it.
    private func fenceRunStart(at lineStart: Int) -> Int? {
        let count = units.count
        var index = lineStart
        var spaces = 0
        while index < count {
            let unit = units[index]
            if unit == 0x60 || unit == 0x7E {
                return !isCommonMark || spaces <= 3 ? index : nil
            }
            if unit == 0x20 {
                spaces += 1
            } else if unit != 0x09 || isCommonMark {
                return nil
            }
            index += 1
        }
        return nil
    }

    private mutating func nextTerminator(from start: Int) -> Int {
        let lineFeed = units.firstIndex(of: 0x0A, from: start)
        if nextCarriageReturn < start {
            nextCarriageReturn = units.firstIndex(of: 0x0D, from: start)
        }
        return min(lineFeed, nextCarriageReturn)
    }

    private func fullLineEnd(terminatorAt terminator: Int) -> Int {
        let count = units.count
        guard terminator < count else {
            return count
        }
        if terminator + 1 < count, units[terminator] == 0x0D, units[terminator + 1] == 0x0A {
            return terminator + 2
        }
        return terminator + 1
    }

    /// Unit index past the closing line of a leading `---`/`+++` block, or 0.
    private mutating func scanFrontmatter() -> Int {
        let firstTerminator = nextTerminator(from: 0)
        guard let marker = frontmatterMarker(from: 0, to: firstTerminator) else {
            return 0
        }

        var lineStart = fullLineEnd(terminatorAt: firstTerminator)
        while lineStart < units.count {
            let terminator = nextTerminator(from: lineStart)
            if frontmatterMarker(from: lineStart, to: terminator) == marker {
                return fullLineEnd(terminatorAt: terminator)
            }
            lineStart = fullLineEnd(terminatorAt: terminator)
        }
        return 0
    }

    /// `-` or `+` when the line `[start, end)` is exactly three of them, ignoring
    /// surrounding spaces and tabs.
    private func frontmatterMarker(from start: Int, to end: Int) -> UInt16? {
        var index = start
        while index < end, units[index] == 0x20 || units[index] == 0x09 {
            index += 1
        }
        guard index + 3 <= end else {
            return nil
        }

        let marker = units[index]
        guard marker == 0x2D || marker == 0x2B,
              units[index + 1] == marker,
              units[index + 2] == marker
        else {
            return nil
        }

        index += 3
        while index < end {
            guard units[index] == 0x20 || units[index] == 0x09 else {
                return nil
            }
            index += 1
        }
        return marker
    }
}
