import AppKit
import Darwin
@testable import EditorKit
import MarkdownCore

/// What a trial does besides waiting, outside the measure. The touch arms read one part
/// of the keystroke's memory after the idle and before the first keystroke: the faults
/// each one takes, and the faults the keystroke no longer takes, show which of its memory
/// the compressor took. `keepWarm` and `regionWalk` act during the idle instead.
enum IdleKeystrokeArm: String, CaseIterable {
    case none
    /// Every UTF-16 unit of the text storage's string.
    case storage
    /// Every attribute run of the text storage.
    case attributes
    /// Every UTF-8 byte of the session's published source.
    case native
    /// Allocations the size of the native copy's scratch and result, written and freed.
    case malloc
    /// One native copy of the text storage, discarded.
    case copy
    /// During the idle, every 500 ms, reads one byte of each resident page of the heap
    /// regions, so the compressor sees them in use (`IdleProbeHeapWarmer`).
    case keepWarm
    /// The same region walk and `mincore` queries as `keepWarm` without reading the
    /// pages: the control for the walk's own CPU and cache effects.
    case regionWalk

    /// Whether the idle itself runs the periodic heap walk.
    var walksDuringIdle: Bool {
        self == .keepWarm || self == .regionWalk
    }

    @MainActor
    func touch(_ app: AppBackedEditorPerformanceTests.AppFixture) {
        guard let storage = MarkdownTextView.textStorage(of: app.editor.textView) else { return }
        var sum = 0
        switch self {
        case .none, .keepWarm, .regionWalk:
            return
        case .storage:
            let string = storage.mutableString as CFString
            let length = CFStringGetLength(string)
            let chunk = 65536
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: chunk)
            defer { buffer.deallocate() }
            var location = 0
            while location < length {
                let count = min(chunk, length - location)
                CFStringGetCharacters(string, CFRange(location: location, length: count), buffer)
                sum &+= Int(buffer[0]) &+ Int(buffer[count - 1])
                location += count
            }
        case .attributes:
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
                sum &+= attributes.count
            }
        case .native:
            sum = app.session.text.utf8.withContiguousStorageIfAvailable { bytes in
                bytes.reduce(0) { $0 &+ Int($1) }
            } ?? 0
        case .malloc:
            let length = storage.length
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: length * 3)
            scratch.initialize(repeating: 0x61, count: length)
            let result = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
            result.update(from: scratch, count: length)
            sum = Int(result[length - 1])
            scratch.deallocate()
            result.deallocate()
        case .copy:
            sum = ExactSourceText.nativeCopy(of: storage.mutableString)?.utf8.count ?? 0
        }
        IdleProbeProcessor.blackHole &+= UInt64(truncatingIfNeeded: sum)
    }
}

/// Walks the heap regions the compressor took during the idle (malloc, untagged, unnested
/// shared-region data, Core Animation, CoreUI, stacks) and, when `read`, loads one byte from
/// each resident page. Compressed pages are skipped, so the walk decompresses nothing.
enum IdleProbeHeapWarmer {
    static let tags: Set<UInt32> = CompressedPageAttribution.mallocTags.union([
        0, UInt32(VM_MEMORY_MALLOC_LARGE), UInt32(VM_MEMORY_MALLOC_LARGE_REUSED), UInt32(VM_MEMORY_UNSHARED_PMAP),
        UInt32(VM_MEMORY_LAYERKIT), UInt32(VM_MEMORY_COREUI), UInt32(VM_MEMORY_STACK),
    ])

    /// Resident pages visited.
    @discardableResult
    static func walk(read: Bool) -> Int {
        let pageSize = CompressedPageAttribution.pageSize
        var visited = 0
        var sum: UInt64 = 0
        var address: mach_vm_address_t = 0
        var size: mach_vm_size_t = 0
        var depth: natural_t = 0
        var vector = [CChar](repeating: 0, count: 4096)
        while true {
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { break }
            if info.is_submap != 0 {
                depth += 1
                continue
            }
            if tags.contains(info.user_tag), info.protection & VM_PROT_READ != 0, info.pages_resident > 0 {
                var start = UInt(address)
                let end = UInt(address + size)
                while start < end {
                    let length = min(end - start, UInt(vector.count) * pageSize)
                    let pages = Int(length / pageSize)
                    if mincore(UnsafeRawPointer(bitPattern: start), Int(length), &vector) == 0 {
                        for index in 0 ..< pages where Int32(UInt8(bitPattern: vector[index])) & MINCORE_INCORE != 0 {
                            visited += 1
                            if read, let byte = UnsafePointer<UInt8>(bitPattern: start + UInt(index) * pageSize) {
                                sum &+= UInt64(byte.pointee)
                            }
                        }
                    }
                    start += length
                }
            }
            address += size
        }
        IdleProbeProcessor.blackHole &+= sum
        return visited
    }
}
