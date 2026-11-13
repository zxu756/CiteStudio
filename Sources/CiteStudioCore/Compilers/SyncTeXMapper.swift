import CoreGraphics
import Foundation

/// Bidirectional mapper for `.synctex` / `.synctex.gz` linking manuscript line numbers and PDF page coordinates.
public struct SyncTeXMapper: Sendable {
    public let anchors: [SyncTeXAnchor]

    public init(anchors: [SyncTeXAnchor]) {
        self.anchors = anchors
    }

    public static func load(from synctexURL: URL) throws -> SyncTeXMapper {
        let content: String
        if synctexURL.pathExtension == "gz" {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            proc.arguments = ["-c", synctexURL.path]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            content = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } else {
            content = try String(contentsOf: synctexURL, encoding: .utf8)
        }
        return parse(synctexText: content)
    }

    /// Parses SyncTeX `Input:tag:path`, `{page`, and `h`/`v`/`x` box records (scaled points -> 72 DPI points).
    public static func parse(synctexText: String) -> SyncTeXMapper {
        var inputFiles: [Int: String] = [:]
        var currentPage = 1
        var anchors: [SyncTeXAnchor] = []
        let spToPt = 1.0 / 65536.0

        let boxRegex = try! NSRegularExpression(
            pattern: #"^[hvx](\d+),(\d+):(-?\d+),(-?\d+)(?::(-?\d+),(-?\d+),(-?\d+))?"#
        )

        for rawLine in synctexText.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("Input:") {
                let rest = rawLine.dropFirst("Input:".count)
                let parts = rest.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let tag = Int(parts[0]) {
                    let fullPath = String(parts[1])
                    inputFiles[tag] = URL(fileURLWithPath: fullPath).lastPathComponent
                }
                continue
            }
            if rawLine.hasPrefix("{") {
                if let p = Int(rawLine.dropFirst()) {
                    currentPage = p
                }
                continue
            }

            let ns = rawLine as NSString
            guard ns.length > 4,
                  let m = boxRegex.firstMatch(in: rawLine, range: NSRange(location: 0, length: ns.length)) else {
                continue
            }
            let tag = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let line = Int(ns.substring(with: m.range(at: 2))) ?? 0
            guard line > 0, let fileName = inputFiles[tag] else { continue }

            let xSp = Double(ns.substring(with: m.range(at: 3))) ?? 0
            let ySp = Double(ns.substring(with: m.range(at: 4))) ?? 0
            let wSp = m.range(at: 5).location != NSNotFound ? (Double(ns.substring(with: m.range(at: 5))) ?? 0) : 72 * 65536
            let hSp = m.range(at: 6).location != NSNotFound ? (Double(ns.substring(with: m.range(at: 6))) ?? 0) : 12 * 65536

            anchors.append(
                SyncTeXAnchor(
                    sourceFile: fileName,
                    line: line,
                    page: currentPage,
                    x: xSp * spToPt,
                    y: ySp * spToPt,
                    width: max(8.0, wSp * spToPt),
                    height: max(8.0, hSp * spToPt)
                )
            )
        }
        return SyncTeXMapper(anchors: anchors)
    }

    public func forwardLookup(sourceFile: String? = nil, line: Int) -> SyncTeXAnchor? {
        let candidates = anchors.filter {
            guard let sf = sourceFile else { return true }
            return $0.sourceFile == sf
        }
        return candidates.min { abs($0.line - line) < abs($1.line - line) }
    }

    public func inverseLookup(page: Int, point: CGPoint) -> SyncTeXAnchor? {
        let onPage = anchors.filter { $0.page == page }
        return onPage.min { a, b in
            let da = hypot(a.x - Double(point.x), a.y - Double(point.y))
            let db = hypot(b.x - Double(point.x), b.y - Double(point.y))
            return da < db
        }
    }
}
