import Foundation

/// Parser & canonical formatter for `.bib` bibliographies and LaTeX / Typst inline citations.
public enum BibTeXParser {

    public static func parseBibTeX(_ text: String) -> [BibEntry] {
        var entries: [BibEntry] = []
        let chars = Array(text)
        let count = chars.count
        var i = 0

        while i < count {
            guard let atIdx = chars[i...].firstIndex(of: "@") else { break }
            i = atIdx + 1
            let typeStart = i
            while i < count && (chars[i].isLetter || chars[i].isNumber) {
                i += 1
            }
            let entryType = String(chars[typeStart..<i]).lowercased()
            while i < count && chars[i].isWhitespace { i += 1 }
            guard i < count && (chars[i] == "{" || chars[i] == "(") else { continue }
            let openDelim = chars[i]
            let closeDelim: Character = (openDelim == "{") ? "}" : ")"
            let rawStart = atIdx
            i += 1

            if entryType == "comment" || entryType == "preamble" || entryType == "string" {
                var depth = 1
                while i < count && depth > 0 {
                    if chars[i] == openDelim { depth += 1 }
                    else if chars[i] == closeDelim { depth -= 1 }
                    i += 1
                }
                continue
            }

            // Parse citeKey up to comma
            let keyStart = i
            while i < count && chars[i] != "," && chars[i] != closeDelim {
                i += 1
            }
            let citeKey = String(chars[keyStart..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
            if i < count && chars[i] == "," { i += 1 }

            var fields: [String: String] = [:]
            var depth = 1
            while i < count && depth > 0 {
                while i < count && (chars[i].isWhitespace || chars[i] == ",") { i += 1 }
                if i < count && chars[i] == closeDelim {
                    depth -= 1
                    i += 1
                    break
                }
                let fNameStart = i
                while i < count && chars[i] != "=" && chars[i] != closeDelim && !chars[i].isWhitespace {
                    i += 1
                }
                let fieldName = String(chars[fNameStart..<i]).lowercased()
                while i < count && chars[i].isWhitespace { i += 1 }
                guard i < count && chars[i] == "=" else {
                    while i < count && chars[i] != "," && chars[i] != closeDelim { i += 1 }
                    continue
                }
                i += 1
                while i < count && chars[i].isWhitespace { i += 1 }
                guard i < count else { break }

                let val: String
                if chars[i] == "{" {
                    i += 1
                    let vStart = i
                    var braceDepth = 1
                    while i < count && braceDepth > 0 {
                        if chars[i] == "{" { braceDepth += 1 }
                        else if chars[i] == "}" { braceDepth -= 1 }
                        if braceDepth > 0 { i += 1 }
                    }
                    val = String(chars[vStart..<i])
                    if i < count && chars[i] == "}" { i += 1 }
                } else if chars[i] == "\"" {
                    i += 1
                    let vStart = i
                    while i < count && chars[i] != "\"" {
                        if chars[i] == "\\" { i += 1 }
                        i += 1
                    }
                    val = String(chars[vStart..<min(i, count)])
                    if i < count && chars[i] == "\"" { i += 1 }
                } else {
                    let vStart = i
                    while i < count && chars[i] != "," && chars[i] != closeDelim && !chars[i].isNewline {
                        i += 1
                    }
                    val = String(chars[vStart..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if !fieldName.isEmpty {
                    fields[fieldName] = cleanLaTeXString(val)
                }
            }

            let rawBib = String(chars[rawStart..<min(i, count)])
            let title = fields["title"] ?? ""
            let authorRaw = fields["author"] ?? ""
            let authors = authorRaw
                .components(separatedBy: " and ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let year = fields["year"].flatMap { Int($0.filter(\.isNumber)) }
            let venue = fields["booktitle"] ?? fields["journal"] ?? fields["publisher"]
            let doi = normalizeDOI(fields["doi"])
            let arxivId = extractArxivId(fields: fields)

            if !citeKey.isEmpty {
                entries.append(
                    BibEntry(
                        citeKey: citeKey,
                        entryType: entryType,
                        title: title,
                        authors: authors,
                        year: year,
                        venue: venue,
                        doi: doi,
                        arxivId: arxivId,
                        fields: fields,
                        rawBibTeX: rawBib
                    )
                )
            }
        }
        return entries
    }

    /// Extract both LaTeX `\cite*{k1,k2}` and Typst `@citekey` inline citations with line numbers and sentences.
    public static func extractInlineCitations(from manuscript: String) -> [InlineCitationRef] {
        var refs: [InlineCitationRef] = []
        let lines = manuscript.components(separatedBy: .newlines)
        let latexPattern = try! NSRegularExpression(
            pattern: #"\\(?:cite|citep|citet|citealp|autocite|parencite|textcite)\*?(?:\[[^\]]*\])*\{([^}]+)\}"#
        )
        let typstPattern = try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_\\])@([A-Za-z][A-Za-z0-9_:-]{2,})"#
        )

        for (idx, line) in lines.enumerated() {
            let lineNo = idx + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%") || trimmed.hasPrefix("//") { continue }

            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            for match in latexPattern.matches(in: line, range: range) {
                let inner = nsLine.substring(with: match.range(at: 1))
                for rawKey in inner.split(separator: ",") {
                    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !key.isEmpty {
                        refs.append(InlineCitationRef(citeKey: key, lineNumber: lineNo, claimSentence: trimmed))
                    }
                }
            }

            for match in typstPattern.matches(in: line, range: range) {
                let key = nsLine.substring(with: match.range(at: 1))
                if !["import", "include", "let", "set", "show"].contains(key.lowercased()) {
                    refs.append(InlineCitationRef(citeKey: key, lineNumber: lineNo, claimSentence: trimmed))
                }
            }
        }
        return refs
    }

    /// Formats a canonical BibTeX stanza populated from the authoritative `ScholarRecord` rather than caller's raw fields.
    public static func formatCanonicalBibTeX(
        entry: BibEntry,
        record: ScholarRecord,
        preferUpgrade: Bool = false
    ) -> String {
        let venue = (preferUpgrade ? record.publishedUpgradeVenue : nil) ?? record.venue
        let year = (preferUpgrade ? record.publishedUpgradeYear : nil) ?? (record.year > 0 ? record.year : (entry.year ?? 0))
        let doi = (preferUpgrade ? record.publishedUpgradeDOI : nil) ?? record.doi ?? entry.doi
        let authorsJoined = record.authors.isEmpty
            ? entry.authors.joined(separator: " and ")
            : record.authors.joined(separator: " and ")

        let resolvedType: String
        let venueField: String
        if preferUpgrade, record.publishedUpgradeVenue != nil {
            resolvedType = "inproceedings"
            venueField = "booktitle"
        } else {
            let normalizedType = entry.entryType.isEmpty ? "article" : entry.entryType.lowercased()
            resolvedType = normalizedType
            switch normalizedType {
            case "inproceedings", "conference", "incollection":
                venueField = "booktitle"
            case "book":
                venueField = "publisher"
            default:
                venueField = "journal"
            }
        }

        var lines: [String] = [
            "@\(resolvedType){\(entry.citeKey),",
            "  title = {\(record.title)},"
        ]
        if !authorsJoined.isEmpty {
            lines.append("  author = {\(authorsJoined)},")
        }
        if !venue.isEmpty {
            lines.append("  \(venueField) = {\(venue)},")
        }
        if year > 0 {
            lines.append("  year = {\(year)}")
        }
        if let doi, !doi.isEmpty {
            if lines.count > 1 && !lines[lines.count - 1].hasSuffix(",") {
                lines[lines.count - 1] += ","
            }
            lines.append("  doi = {\(doi)}")
        } else if lines.count > 1 && lines[lines.count - 1].hasSuffix(",") {
            lines[lines.count - 1] = String(lines[lines.count - 1].dropLast())
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    public static func formatUpgradedBibTeX(entry: BibEntry, record: ScholarRecord) -> String {
        formatCanonicalBibTeX(entry: entry, record: record, preferUpgrade: true)
    }

    private static func cleanLaTeXString(_ raw: String) -> String {
        var s = raw
        // Decode common LaTeX diacritics (e.g. {\"u}, {\'e}, \"u, \'e) into Unicode characters
        let accentTable: [(String, Character, String)] = [
            ("\"", "a", "ä"), ("\"", "o", "ö"), ("\"", "u", "ü"), ("\"", "e", "ë"), ("\"", "i", "ï"),
            ("\"", "A", "Ä"), ("\"", "O", "Ö"), ("\"", "U", "Ü"), ("\"", "E", "Ë"), ("\"", "I", "Ï"),
            ("'", "a", "á"), ("'", "e", "é"), ("'", "i", "í"), ("'", "o", "ó"), ("'", "u", "ú"), ("'", "y", "ý"), ("'", "c", "ć"),
            ("'", "A", "Á"), ("'", "E", "É"), ("'", "I", "Í"), ("'", "O", "Ó"), ("'", "U", "Ú"), ("'", "Y", "Ý"), ("'", "C", "Ć"),
            ("`", "a", "à"), ("`", "e", "è"), ("`", "i", "ì"), ("`", "o", "ò"), ("`", "u", "ù"),
            ("^", "a", "â"), ("^", "e", "ê"), ("^", "i", "î"), ("^", "o", "ô"), ("^", "u", "û"),
            ("~", "a", "ã"), ("~", "n", "ñ"), ("~", "o", "õ"), ("~", "N", "Ñ")
        ]
        for (accent, base, replacement) in accentTable {
            s = s.replacingOccurrences(of: "{\\\(accent){\(base)}}", with: replacement)
            s = s.replacingOccurrences(of: "{\\\(accent)\(base)}", with: replacement)
            s = s.replacingOccurrences(of: "\\\(accent){\(base)}", with: replacement)
            s = s.replacingOccurrences(of: "\\\(accent)\(base)", with: replacement)
        }
        s = s.replacingOccurrences(of: "{\\c{c}}", with: "ç")
            .replacingOccurrences(of: "\\c{c}", with: "ç")
            .replacingOccurrences(of: "{\\c{C}}", with: "Ç")
            .replacingOccurrences(of: "\\c{C}", with: "Ç")
            .replacingOccurrences(of: "{\\ss}", with: "ß")
            .replacingOccurrences(of: "\\ss", with: "ß")

        return s.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizeDOI(_ raw: String?) -> String? {
        guard var d = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "doi:"] {
            if d.lowercased().hasPrefix(prefix) {
                d = String(d.dropFirst(prefix.count))
            }
        }
        return d.lowercased()
    }

    private static func extractArxivId(fields: [String: String]) -> String? {
        if let eprint = fields["eprint"], !eprint.isEmpty {
            return eprint
        }
        for candidate in [fields["journal"], fields["note"], fields["url"]].compactMap({ $0 }) {
            if let range = candidate.range(of: #"(\d{4}\.\d{4,5})"#, options: .regularExpression) {
                return String(candidate[range])
            }
        }
        return nil
    }
}
