import Darwin
import Foundation
import ObjectiveC

/// Which heap objects lie on the malloc pages a keystroke decompressed (probe code only,
/// `docs/perf/2026-11-28-idle-first-keystroke.md`). `pagedOut` lists the compressed pages
/// of the malloc regions before the keystroke (`mincore`, which touches no page);
/// `stillPagedOut` filters them again afterwards; `attribute` walks the malloc zones'
/// in-use blocks with the zones locked, keeps the blocks that overlap the decompressed
/// pages, and names each by its Objective-C or Swift class where its first word is one.
enum CompressedPageAttribution {
    static let pageSize = UInt(getpagesize())
    static let mallocTags: Set<UInt32> = [
        UInt32(VM_MEMORY_MALLOC), UInt32(VM_MEMORY_MALLOC_SMALL), UInt32(VM_MEMORY_MALLOC_TINY),
        UInt32(VM_MEMORY_MALLOC_MEDIUM), UInt32(VM_MEMORY_MALLOC_NANO),
    ]

    static func pagedOut(tags: Set<UInt32> = mallocTags) -> [UInt] {
        var pages: [UInt] = []
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
            if tags.contains(info.user_tag), info.pages_swapped_out > 0 {
                pages +=
                    query(start: UInt(address), length: UInt(size)) {
                        $0 & MINCORE_PAGED_OUT != 0 && $0 & MINCORE_INCORE == 0
                    }
            }
            address += size
        }
        return pages
    }

    static func stillPagedOut(_ pages: [UInt]) -> Set<UInt> {
        Set(pages.filter { page in
            query(start: page, length: pageSize) { $0 & MINCORE_PAGED_OUT != 0 && $0 & MINCORE_INCORE == 0 }.count == 1
        })
    }

    private static func query(start: UInt, length: UInt, keep: (Int32) -> Bool) -> [UInt] {
        let count = Int(length / pageSize)
        guard count > 0 else { return [] }
        var vector = [CChar](repeating: 0, count: count)
        guard mincore(UnsafeRawPointer(bitPattern: start), Int(length), &vector) == 0 else { return [] }
        return (0 ..< count)
            .compactMap { keep(Int32(UInt8(bitPattern: vector[$0]))) ? start + UInt($0) * pageSize : nil }
    }

    private struct ScanContext {
        var pages: UnsafePointer<UInt>
        var pageCount: Int
        var pageMask: UInt
        var output: UnsafeMutablePointer<vm_range_t>
        var capacity: Int
        var count: Int
    }

    /// Bytes of decompressed pages by owner, largest first.
    static func attribute(pages: [UInt]) -> [(owner: String, blocks: Int, bytes: Int)] {
        let sorted = pages.sorted()
        guard !sorted.isEmpty else { return [] }
        let capacity = 1 << 20
        let output = UnsafeMutablePointer<vm_range_t>.allocate(capacity: capacity)
        defer { output.deallocate() }
        let found = sorted.withUnsafeBufferPointer { buffer -> Int in
            var context = ScanContext(
                pages: buffer.baseAddress!, pageCount: buffer.count, pageMask: ~(pageSize - 1),
                output: output, capacity: capacity, count: 0
            )
            var zones: UnsafeMutablePointer<vm_address_t>?
            var zoneCount: UInt32 = 0
            guard malloc_get_all_zones(mach_task_self_, nil, &zones, &zoneCount) == KERN_SUCCESS,
                  let zones else { return 0 }
            for index in 0 ..< Int(zoneCount) {
                guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: zones[index]),
                      let introspect = zone.pointee.introspect,
                      let enumerator = introspect.pointee.enumerator
                else { continue }
                introspect.pointee.force_lock?(zone)
                _ = withUnsafeMutablePointer(to: &context) { contextPointer in
                    enumerator(
                        mach_task_self_, contextPointer, UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE), zones[index],
                        { _, address, _, local in
                            local?.pointee = UnsafeMutableRawPointer(bitPattern: address)
                            return KERN_SUCCESS
                        },
                        { _, contextPointer, _, ranges, count in
                            guard let contextPointer, let ranges else { return }
                            let scan = contextPointer.assumingMemoryBound(to: ScanContext.self)
                            for rangeIndex in 0 ..< Int(count) {
                                let range = ranges[rangeIndex]
                                let first = UInt(range.address) & scan.pointee.pageMask
                                let last = (UInt(range.address) + UInt(range.size) - 1) & scan.pointee.pageMask
                                // Binary search for the first listed page at or after `first`.
                                var low = 0
                                var high = scan.pointee.pageCount
                                while low < high {
                                    let middle = (low + high) / 2
                                    if scan.pointee.pages[middle] < first { low = middle + 1 } else { high = middle }
                                }
                                if low < scan.pointee.pageCount, scan.pointee.pages[low] <= last,
                                   scan.pointee.count < scan.pointee.capacity
                                {
                                    scan.pointee.output[scan.pointee.count] = range
                                    scan.pointee.count += 1
                                }
                            }
                        }
                    )
                }
                introspect.pointee.force_unlock?(zone)
            }
            return context.count
        }

        var classes = Set<UInt>()
        let classCount = Int(objc_getClassList(nil, 0))
        let list = UnsafeMutablePointer<AnyClass>.allocate(capacity: classCount)
        defer { list.deallocate() }
        let listed = Int(objc_getClassList(AutoreleasingUnsafeMutablePointer(list), Int32(classCount)))
        for index in 0 ..< min(listed, classCount) {
            classes.insert(UInt(bitPattern: unsafeBitCast(list[index], to: UnsafeRawPointer.self)))
        }
        let pageSet = Set(sorted)
        var owners: [String: (blocks: Int, bytes: Int)] = [:]
        for index in 0 ..< found {
            let range = output[index]
            var overlap = 0
            var page = UInt(range.address) & ~(pageSize - 1)
            let end = UInt(range.address) + UInt(range.size)
            while page < end {
                if pageSet.contains(page) {
                    overlap += Int(min(end, page + pageSize) - max(UInt(range.address), page))
                }
                page += pageSize
            }
            let owner = ownerName(address: UInt(range.address), size: Int(range.size), classes: classes)
            owners[owner, default: (blocks: 0, bytes: 0)].blocks += 1
            owners[owner, default: (blocks: 0, bytes: 0)].bytes += overlap
        }
        return owners.map { ($0.key, $0.value.blocks, $0.value.bytes) }.sorted { $0.bytes > $1.bytes }
    }

    private static func ownerName(address: UInt, size: Int, classes: Set<UInt>) -> String {
        guard size >= 8, let pointer = UnsafePointer<UInt>(bitPattern: address) else { return "bytes" }
        let word = pointer.pointee
        for candidate in [word, word & 0x0000_000F_FFFF_FFF8, word & 0x0000_7FFF_FFFF_FFF8]
            where classes.contains(candidate)
        {
            if let cls = unsafeBitCast(candidate, to: AnyClass?.self) {
                return String(cString: class_getName(cls))
            }
        }
        let bucket = size <= 1024 ? "≤1K" : size <= 16384 ? "≤16K" : size <= 131_072 ? "≤128K" : ">128K"
        return "non-object \(bucket)"
    }
}
