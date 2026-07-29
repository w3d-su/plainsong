import Darwin
import Foundation
import PDFKit

struct E0PDFSnapshot {
    let data: Data
    let configurationRect: CGRect
    let document: PDFDocument
    let extractedText: String
    let pageClaims: [E0PDFPageClaim]

    init(data: Data, configurationRect: CGRect) throws {
        guard data.starts(with: Data("%PDF-".utf8)) else {
            throw E0ProbeError.invalidPDFHeader
        }
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw E0ProbeError.unparseablePDF
        }

        self.data = data
        self.configurationRect = configurationRect
        self.document = document

        var pageText: [String] = []
        var claims: [E0PDFPageClaim] = []
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                throw E0ProbeError.missingPDFPage(pageIndex)
            }
            pageText.append(page.string ?? "")
            claims.append(E0PDFPageClaim(page: page))
        }
        extractedText = pageText.joined(separator: "\n\u{0C}\n")
        pageClaims = claims
    }
}

struct E0PDFPageClaim {
    let mediaBox: CGRect
    let userUnit: CGFloat

    init(page: PDFPage) {
        guard let pageReference = page.pageRef else {
            mediaBox = page.bounds(for: .mediaBox)
            userUnit = 1
            return
        }

        mediaBox = pageReference.getBoxRect(.mediaBox)
        var parsedUserUnit: CGPDFReal = 1
        if let dictionary = pageReference.dictionary {
            _ = CGPDFDictionaryGetNumber(dictionary, "UserUnit", &parsedUserUnit)
        }
        userUnit = CGFloat(parsedUserUnit)
    }

    var claimedHeight: CGFloat {
        mediaBox.height * userUnit
    }

    var hasValidDefaultUserSpace: Bool {
        mediaBox.width.isFinite
            && mediaBox.height.isFinite
            && userUnit.isFinite
            && mediaBox.width > 0
            && mediaBox.height > 0
            && mediaBox.width <= 14400.5
            && mediaBox.height <= 14400.5
            && userUnit >= 1
            && userUnit <= 75000
    }
}

enum E0ProbeError: Error, CustomStringConvertible {
    case timeout(String)
    case missingRenderCompletion(Int)
    case currentRenderFailed
    case invalidJavaScriptResult(String)
    case invalidContentBounds(CGFloat, CGFloat)
    case captureRectOutsideWebView(CGRect, CGRect)
    case invalidPaginationHeight(CGFloat)
    case noSafeFixedPaginationHeight
    case paginationCaptureFailed(pageIndex: Int, rect: CGRect, underlying: String)
    case invalidPDFHeader
    case unparseablePDF
    case missingPDFPage(Int)
    case missingValue(String)

    var description: String {
        switch self {
        case let .timeout(label):
            "Timed out waiting for \(label)"
        case let .missingRenderCompletion(renderID):
            "Missing renderComplete for submitted renderID \(renderID)"
        case .currentRenderFailed:
            "Current render is the MDX stale/error DOM"
        case let .invalidJavaScriptResult(label):
            "Invalid JavaScript result for \(label)"
        case let .invalidContentBounds(width, height):
            "Invalid content bounds \(width) × \(height)"
        case let .captureRectOutsideWebView(rect, bounds):
            "Capture rect \(rect) is outside WebView bounds \(bounds)"
        case let .invalidPaginationHeight(height):
            "Invalid pagination height \(height)"
        case .noSafeFixedPaginationHeight:
            "No fixed pagination height placed every page boundary between laid-out blocks"
        case let .paginationCaptureFailed(pageIndex, rect, underlying):
            "Fixed-height page \(pageIndex) at \(rect) failed: \(underlying)"
        case .invalidPDFHeader:
            "PDF data does not begin with %PDF-"
        case .unparseablePDF:
            "PDFKit could not parse the produced PDF"
        case let .missingPDFPage(index):
            "PDFKit could not read page \(index)"
        case let .missingValue(label):
            "Missing \(label)"
        }
    }

    static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else {
            throw E0ProbeError.missingValue(label)
        }
        return value
    }
}

enum E0WebContentProcessProbe {
    static func processIDs() -> Set<pid_t> {
        Set(allProcessIDs().filter { processName(pid: $0).hasPrefix("com.apple.WebKit.WebContent") })
    }

    private static func allProcessIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }

        var processes = [kinfo_proc](
            repeating: kinfo_proc(),
            count: length / MemoryLayout<kinfo_proc>.stride
        )
        let result = processes.withUnsafeMutableBufferPointer { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &length, nil, 0)
        }
        guard result == 0 else {
            return []
        }
        return processes
            .prefix(length / MemoryLayout<kinfo_proc>.stride)
            .map(\.kp_proc.p_pid)
    }

    private static func processName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard result > 0 else {
            return ""
        }
        return String(cString: buffer)
    }
}
