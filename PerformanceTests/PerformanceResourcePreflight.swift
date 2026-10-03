import CryptoKit
import Darwin
import Foundation
import XCTest

/// File diagnostics run before any timed region. The bundled contract is also read by CI.
@MainActor
enum PerformanceResourcePreflight {
    private static var validation: Result<Void, Error>?

    static func validateOnce(bundle: Bundle) throws {
        if let validation {
            switch validation {
            case .success:
                return
            case .failure:
                throw XCTSkip("PerformanceTests resource preflight already failed; see its first diagnostic.")
            }
        }
        do {
            try validate(bundle: bundle)
            validation = .success(())
        } catch {
            validation = .failure(error)
            throw error
        }
    }

    static func resourceURL(bundle: Bundle, path: String) throws -> URL {
        guard let root = bundle.resourceURL else {
            throw diagnostic(bundle: bundle, path: path, code: ENOENT)
        }
        return root.appendingPathComponent(path)
    }

    private static func validate(bundle: Bundle) throws {
        let contractURL = try resourceURL(bundle: bundle, path: "performance-required-resources.txt")
        let contract: String
        do {
            contract = try String(contentsOf: contractURL, encoding: .utf8)
        } catch {
            let code = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw diagnostic(bundle: bundle, path: contractURL.path, code: Int32(code?.code ?? Int(EILSEQ)))
        }
        let paths = contract.split(separator: "\n").map(String.init)
        guard !paths.isEmpty else {
            throw diagnostic(bundle: bundle, path: contractURL.path, code: EINVAL)
        }
        var entries: [[String: String]] = []
        print("PerformanceTests preflight bundle=\(bundle.bundlePath)")
        print("Resources: \(paths.joined(separator: ", "))")
        for path in ["performance-required-resources.txt"] + paths {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw diagnostic(bundle: bundle, path: path, code: EINVAL)
            }
            let url = try resourceURL(bundle: bundle, path: path)
            try entries.append(inspect(url: url, bundle: bundle))
        }
        for entry in entries {
            print(
                "PerformanceTests resource \(entry["path"]!) bytes=\(entry["bytes"]!) permissions=\(entry["permissions"]!) sha256=\(entry["sha256"]!)"
            )
        }
    }

    private static func inspect(url: URL, bundle: Bundle) throws -> [String: String] {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw diagnostic(bundle: bundle, path: url.path, code: errno)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw diagnostic(bundle: bundle, path: url.path, code: errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size > 0 else {
            throw diagnostic(bundle: bundle, path: url.path, code: EINVAL)
        }
        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 65536)
        var byteCount = 0
        while true {
            let count = read(descriptor, &bytes, bytes.count)
            guard count >= 0 else {
                throw diagnostic(bundle: bundle, path: url.path, code: errno)
            }
            if count == 0 {
                break
            }
            byteCount += count
            hasher.update(data: Data(bytes.prefix(count)))
        }
        guard byteCount == metadata.st_size else {
            throw diagnostic(bundle: bundle, path: url.path, code: EIO)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return [
            "path": url.path,
            "bytes": String(metadata.st_size),
            "permissions": String(metadata.st_mode & 0o7777, radix: 8),
            "sha256": hash,
        ]
    }

    private static func diagnostic(bundle: Bundle, path: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey:
                "PerformanceTests resource preflight failed: path=\(path) errno=\(code) bundle=\(bundle.bundlePath)"]
        )
    }
}
