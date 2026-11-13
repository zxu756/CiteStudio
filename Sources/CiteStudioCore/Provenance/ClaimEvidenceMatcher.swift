import Foundation

/// Matches manuscript claim sentences to verbatim supporting passages in indexed local reference PDFs.
public enum ClaimEvidenceMatcher {
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "been", "were",
        "their", "which", "while", "where", "into", "over", "under", "such", "also",
        "show", "shown", "demonstrate", "paper", "study", "et", "al", "cite", "citep", "citet"
    ]

    public static func matchClaim(
        sentence: String,
        citeKey: String,
        indexer: LocalPDFIndexer
    ) -> PDFPassageEvidence? {
        // Strip LaTeX commands before tokenizing content words
        let stripped = sentence.replacingOccurrences(
            of: #"\\[a-zA-Z]+\*?(?:\[[^\]]*\])?(?:\{[^}]*\})?"#,
            with: " ",
            options: .regularExpression
        )
        let tokens = stripped
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopwords.contains($0) }

        let uniqueTerms = Array(NSOrderedSet(array: tokens)) as? [String] ?? tokens
        let hits = indexer.searchBM25(queryTerms: Array(uniqueTerms.prefix(10)), citeKey: citeKey, limit: 1)
        return hits.first
    }
}
