import Darwin
import Foundation

/// The calling thread's retired instructions and cycles, from the kernel's per-thread
/// counters (`thread_selfcounts`, looked up at run time; probe code only).
///
/// Kind 1 (`THSC_CPI`) returns `{instructions, cycles}`. Kind 4
/// (`THSC_TIME_CPI_PER_PERF_LEVEL`) returns `{instructions, cycles, user time, system
/// time}` in mach ticks for each performance level, level 0 being the performance cores.
/// The field order was checked on macOS 27 with a compute loop and a syscall loop.
/// Instructions and cycles include kernel mode.
struct ThreadCounters {
    struct Level: Codable {
        var instructions: UInt64
        var cycles: UInt64
        var userMilliseconds: Double
        var systemMilliseconds: Double
    }

    private typealias SelfCounts = @convention(c) (Int32, UnsafeMutableRawPointer, Int) -> Int32
    private let selfCounts: SelfCounts
    let levelCount: Int
    private let millisecondsPerTick: Double

    init?() {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "thread_selfcounts") else { return nil }
        selfCounts = unsafeBitCast(symbol, to: SelfCounts.self)
        var levels: Int32 = 0
        var size = MemoryLayout<Int32>.size
        levelCount = sysctlbyname("hw.nperflevels", &levels, &size, nil, 0) == 0 ? max(Int(levels), 1) : 1
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        millisecondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000
        guard read().instructions > 0 else { return nil }
    }

    func read() -> (instructions: UInt64, cycles: UInt64) {
        var buffer: (UInt64, UInt64) = (0, 0)
        let result = withUnsafeMutableBytes(of: &buffer) { selfCounts(1, $0.baseAddress!, 16) }
        return result == 0 ? buffer : (0, 0)
    }

    /// Counts per performance level, or an empty array when the kernel refuses kind 4.
    func readLevels() -> [Level] {
        var words = [UInt64](repeating: 0, count: 4 * levelCount)
        let result = words.withUnsafeMutableBytes { selfCounts(4, $0.baseAddress!, $0.count) }
        guard result == 0 else { return [] }
        return (0 ..< levelCount).map { level in
            Level(
                instructions: words[4 * level],
                cycles: words[4 * level + 1],
                userMilliseconds: Double(words[4 * level + 2]) * millisecondsPerTick,
                systemMilliseconds: Double(words[4 * level + 3]) * millisecondsPerTick
            )
        }
    }

    static func difference(_ after: [Level], _ before: [Level]) -> [Level] {
        guard after.count == before.count else { return [] }
        return zip(after, before).map { later, earlier in
            Level(
                instructions: later.instructions &- earlier.instructions,
                cycles: later.cycles &- earlier.cycles,
                userMilliseconds: later.userMilliseconds - earlier.userMilliseconds,
                systemMilliseconds: later.systemMilliseconds - earlier.systemMilliseconds
            )
        }
    }
}

/// Process-wide page faults, page-ins and copy-on-write faults (`TASK_EVENTS_INFO`).
enum TaskFaultCounters {
    static func read() -> (faults: Int, pageins: Int, copyOnWrite: Int) {
        var info = task_events_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        return (Int(info.faults), Int(info.pageins), Int(info.cow_faults))
    }
}

/// The process's memory as the kernel and the default malloc zone count it, in MiB.
struct TaskMemorySnapshot: Codable {
    var resident: Double
    /// `task_vm_info.internal`: anonymous memory.
    var anonymous: Double
    var compressed: Double
    var reusable: Double
    var footprint: Double
    var mallocInUse: Double
    var mallocAllocated: Double

    static func read() -> TaskMemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        let mebibyte = 1_048_576.0
        guard result == KERN_SUCCESS else {
            return TaskMemorySnapshot(
                resident: 0, anonymous: 0, compressed: 0, reusable: 0, footprint: 0,
                mallocInUse: Double(statistics.size_in_use) / mebibyte,
                mallocAllocated: Double(statistics.size_allocated) / mebibyte
            )
        }
        return TaskMemorySnapshot(
            resident: Double(info.resident_size) / mebibyte,
            anonymous: Double(info.internal) / mebibyte,
            compressed: Double(info.compressed) / mebibyte,
            reusable: Double(info.reusable) / mebibyte,
            footprint: Double(info.phys_footprint) / mebibyte,
            mallocInUse: Double(statistics.size_in_use) / mebibyte,
            mallocAllocated: Double(statistics.size_allocated) / mebibyte
        )
    }
}

/// Compressed (swapped-out) and resident pages per VM region tag (`mach_vm_region_recurse`,
/// which reads region metadata and touches no page), keyed by the tag's name.
enum VMRegionCensus {
    struct Pages: Codable {
        var compressed: Int
        var resident: Int
    }

    static func read() -> [String: Pages] {
        var totals: [String: Pages] = [:]
        var address: mach_vm_address_t = 0
        var size: mach_vm_size_t = 0
        var depth: natural_t = 0
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
            let name = tagName(info.user_tag)
            var pages = totals[name] ?? Pages(compressed: 0, resident: 0)
            pages.compressed += Int(info.pages_swapped_out)
            pages.resident += Int(info.pages_resident)
            totals[name] = pages
            address += size
        }
        return totals
    }

    static func tagName(_ tag: UInt32) -> String {
        names[Int32(tag)] ?? (tag == 0 ? "untagged" : "tag-\(tag)")
    }

    private static let names: [Int32: String] = [
        VM_MEMORY_MALLOC: "malloc", VM_MEMORY_MALLOC_SMALL: "malloc-small",
        VM_MEMORY_MALLOC_LARGE: "malloc-large", VM_MEMORY_MALLOC_HUGE: "malloc-huge",
        VM_MEMORY_MALLOC_TINY: "malloc-tiny", VM_MEMORY_MALLOC_LARGE_REUSABLE: "malloc-large-reusable",
        VM_MEMORY_MALLOC_LARGE_REUSED: "malloc-large-reused", VM_MEMORY_MALLOC_NANO: "malloc-nano",
        VM_MEMORY_MALLOC_MEDIUM: "malloc-medium", VM_MEMORY_VM_RECLAIM: "vm-reclaim",
        VM_MEMORY_STACK: "stack", VM_MEMORY_APPKIT: "appkit", VM_MEMORY_FOUNDATION: "foundation",
        VM_MEMORY_COREGRAPHICS: "coregraphics", VM_MEMORY_CORESERVICES: "coreservices",
        VM_MEMORY_LAYERKIT: "coreanimation", VM_MEMORY_IOKIT: "iokit", VM_MEMORY_IOSURFACE: "iosurface",
        VM_MEMORY_LIBDISPATCH: "dispatch", VM_MEMORY_DYLD: "dyld", VM_MEMORY_DYLD_MALLOC: "dyld-malloc",
        VM_MEMORY_JAVASCRIPT_CORE: "javascript", VM_MEMORY_OS_ALLOC_ONCE: "os-alloc-once",
        VM_MEMORY_SWIFT_RUNTIME: "swift-runtime", VM_MEMORY_SWIFT_METADATA: "swift-metadata",
        VM_MEMORY_OBJC_DISPATCHERS: "objc-dispatchers", VM_MEMORY_COREUI: "coreui",
        VM_MEMORY_DYLIB: "dylib", VM_MEMORY_SANITIZER: "sanitizer",
    ]
}

enum IdleProbeProcessor {
    /// The CPU the calling thread runs on now (`pthread_cpu_number_np`), or -1.
    static func currentCPU() -> Int {
        var number = 0
        return pthread_cpu_number_np(&number) == 0 ? number : -1
    }

    /// Keeps probe reads from being optimized away.
    nonisolated(unsafe) static var blackHole: UInt64 = 0
}
