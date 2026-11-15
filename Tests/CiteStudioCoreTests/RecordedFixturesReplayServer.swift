// Strict recorded-fixture loopback HTTP server reading verbatim responses from Tests/Fixtures/recorded/.
// Serves zero handwritten JSON bodies; returns HTTP 501 for any unrecorded URL.

import Darwin
import Foundation

final class RecordedFixturesReplayServer: @unchecked Sendable {
    private struct RecordedEntry: Sendable {
        let statusCode: Int
        let contentType: String
        let rawBytes: [UInt8]
    }

    private let entries: [String: RecordedEntry]
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    let port: UInt16

    var crossrefBaseURL: URL { URL(string: "http://127.0.0.1:\(port)/crossref")! }
    var openAlexBaseURL: URL { URL(string: "http://127.0.0.1:\(port)/openalex")! }

    static var defaultRecordedDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/recorded", isDirectory: true)
    }

    init(recordedDirectory: URL = RecordedFixturesReplayServer.defaultRecordedDirectory) throws {
        var loaded: [String: RecordedEntry] = [:]
        let items = try FileManager.default.contentsOfDirectory(at: recordedDirectory, includingPropertiesForKeys: nil)
        for itemURL in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where itemURL.lastPathComponent.hasSuffix(".meta.json") {
            let metaData = try Data(contentsOf: itemURL)
            guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                  let service = meta["service"] as? String,
                  let rawURL = meta["url"] as? String,
                  let status = meta["status"] as? Int,
                  let rawFile = meta["raw_file"] as? String else {
                continue
            }
            let rawPath = recordedDirectory.appendingPathComponent(rawFile)
            guard FileManager.default.fileExists(atPath: rawPath.path) else { continue }
            let rawData = try Data(contentsOf: rawPath)
            let contentType = (meta["content_type"] as? String) ?? "application/json"
            let key = Self.canonicalKey(service: service, rawURLOrPath: rawURL)
            loaded[key] = RecordedEntry(statusCode: status, contentType: contentType, rawBytes: Array(rawData))
        }
        self.entries = loaded

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "RecordedFixturesReplayServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "RecordedFixturesReplayServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind/listen failed"])
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
        DispatchQueue.global().async { [weak self] in self?.acceptLoop() }
    }

    deinit { stop() }

    func stop() {
        let fd: Int32 = lock.withLock {
            if stopped { return -1 }
            stopped = true
            let cur = listenFD
            listenFD = -1
            return cur
        }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func acceptLoop() {
        while true {
            let lfd = lock.withLock { stopped ? -1 : listenFD }
            if lfd < 0 { break }
            var caddr = sockaddr_in()
            var clen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &caddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(lfd, $0, &clen)
                }
            }
            if cfd < 0 { break }
            let table = entries
            DispatchQueue.global().async { Self.handleClient(cfd, entries: table) }
        }
    }

    private static func handleClient(_ cfd: Int32, entries: [String: RecordedEntry]) {
        defer { Darwin.close(cfd) }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(cfd, &buf, buf.count)
        guard n > 0 else { return }
        let req = String(decoding: buf[0..<n], as: UTF8.self)
        let target = String((req.components(separatedBy: "\r\n").first ?? "").split(separator: " ").dropFirst().first ?? "")

        let entry: RecordedEntry?
        if target.hasPrefix("/crossref/") {
            let sub = String(target.dropFirst("/crossref".count))
            entry = entries[canonicalKey(service: "crossref", rawURLOrPath: sub)]
        } else if target.hasPrefix("/openalex/") {
            let sub = String(target.dropFirst("/openalex".count))
            entry = entries[canonicalKey(service: "openalex", rawURLOrPath: sub)]
        } else {
            entry = nil
        }

        let status: Int
        let contentType: String
        let body: [UInt8]
        if let entry {
            status = entry.statusCode
            contentType = entry.contentType
            body = entry.rawBytes
        } else {
            status = 501
            contentType = "application/json"
            body = Array(#"{"error":"unrecorded_fixture_url"}"#.utf8)
        }

        let header = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let packet = Array(header.utf8) + body
        packet.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                _ = Darwin.write(cfd, base, packet.count)
            }
        }
    }

    static func canonicalKey(service: String, rawURLOrPath: String) -> String {
        let normalizedURLString: String
        if rawURLOrPath.hasPrefix("http://") || rawURLOrPath.hasPrefix("https://") {
            normalizedURLString = rawURLOrPath
        } else {
            normalizedURLString = "http://127.0.0.1" + (rawURLOrPath.hasPrefix("/") ? rawURLOrPath : "/" + rawURLOrPath)
        }
        let comps = URLComponents(string: normalizedURLString)
        var unquotedPath = comps?.percentEncodedPath.removingPercentEncoding ?? comps?.path ?? rawURLOrPath
        while unquotedPath.count > 1 && unquotedPath.hasSuffix("/") {
            unquotedPath.removeLast()
        }
        if unquotedPath.isEmpty { unquotedPath = "/" }

        let items = (comps?.queryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")
        return "\(service.lowercased())|\(unquotedPath.lowercased())|\(items)"
    }
}
