import AppKit
import SwiftUI

/// Wraps AppKit `NSTextView` for live LaTeX/Typst editing with GhostPaper burgundy squiggly underlines,
/// and provides a faithful SwiftUI line-numbered raster view when `isSnapshotMode` is enabled.
public struct ManuscriptEditorView: View {
    @ObservedObject var session: CiteStudioWorkspaceSession
    @ObservedObject var localizer: AppLocalizer

    @MainActor
    public init(session: CiteStudioWorkspaceSession, localizer: AppLocalizer? = nil) {
        self.session = session
        self.localizer = localizer ?? .shared
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorSubheader
            Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

            if session.isSnapshotMode {
                snapshotManuscriptCanvas
            } else {
                AppKitTextViewRepresentable(
                    text: $session.manuscriptText,
                    ghostKeys: session.ghostOrRetractedKeys,
                    upgradeKeys: session.upgradeAvailableKeys
                )
            }
        }
        .background(CiteStudioTheme.manuscriptSheet)
    }

    private var editorSubheader: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(CiteStudioTheme.oxfordNavy)
            Text(session.manuscriptFilename)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(CiteStudioTheme.carbonInk)
            Text(localizer.L("LaTeX / SyncTeX", "LaTeX / SyncTeX 双向同步"))
                .font(.system(size: 11))
                .tracking(0)
                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
            Spacer()
            Text(localizer.isChinese ? "第 \(session.activeSourceLine) 行" : "Line \(session.activeSourceLine)")
                .font(.system(size: 11, design: .monospaced))
                .tracking(0)
                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CiteStudioTheme.vellumPage)
    }

    private var snapshotManuscriptCanvas: some View {
        let lines = session.manuscriptText.components(separatedBy: .newlines)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                let lineNo = idx + 1
                let hasGhost = session.ghostOrRetractedKeys.contains { line.contains($0) }
                let hasUpgrade = session.upgradeAvailableKeys.contains { line.contains($0) }
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%2d", lineNo))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CiteStudioTheme.marginaliaGrey.opacity(0.75))
                        .frame(width: 22, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(styledLine(line))
                            .font(.system(size: 11.5, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)

                        if hasGhost {
                            HStack(spacing: 5) {
                                Circle().fill(CiteStudioTheme.exLibrisBurgundy).frame(width: 5, height: 5)
                                Text(
                                    localizer.L(
                                        "Ghost citation 'smith2025hallucinated' — blocked by Citation Firewall",
                                        "幽灵引用 'smith2025hallucinated'：已被引文防火墙拦截"
                                    )
                                )
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0)
                                .foregroundStyle(CiteStudioTheme.exLibrisBurgundy)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(CiteStudioTheme.exLibrisBurgundy.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else if hasUpgrade {
                            HStack(spacing: 5) {
                                Circle().fill(CiteStudioTheme.amberGold).frame(width: 5, height: 5)
                                Text(
                                    localizer.L(
                                        "arXiv preprint cited — NeurIPS 2022 version available (1-click upgrade)",
                                        "已引用 arXiv 预印本：检出 NeurIPS 2022 正式版（支持一键升级）"
                                    )
                                )
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0)
                                .foregroundStyle(CiteStudioTheme.amberGold)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(CiteStudioTheme.amberGold.opacity(0.11))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .padding(.vertical, 1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    lineNo == 12
                        ? CiteStudioTheme.forestGreen.opacity(0.08)
                        : (hasGhost ? CiteStudioTheme.exLibrisBurgundy.opacity(0.05) : Color.clear)
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CiteStudioTheme.manuscriptSheet)
    }

    private func styledLine(_ raw: String) -> AttributedString {
        var attr = AttributedString(raw)
        attr.foregroundColor = CiteStudioTheme.carbonInk

        if raw.hasPrefix("\\section") || raw.hasPrefix("\\documentclass") || raw.hasPrefix("\\title") {
            attr.foregroundColor = CiteStudioTheme.oxfordNavy
        }
        for key in session.ghostOrRetractedKeys {
            if let r = attr.range(of: key) {
                attr[r].foregroundColor = CiteStudioTheme.exLibrisBurgundy
                attr[r].underlineStyle = .single
            }
        }
        for entry in session.bibEntries where !session.ghostOrRetractedKeys.contains(entry.citeKey) {
            if let r = attr.range(of: entry.citeKey) {
                attr[r].foregroundColor = session.upgradeAvailableKeys.contains(entry.citeKey)
                    ? CiteStudioTheme.amberGold
                    : CiteStudioTheme.forestGreen
            }
        }
        return attr
    }
}

private struct AppKitTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    let ghostKeys: Set<String>
    let upgradeKeys: Set<String>

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.backgroundColor = .white
        tv.textColor = NSColor(calibratedRed: 0.098, green: 0.094, blue: 0.086, alpha: 1.0)
        tv.textContainerInset = NSSize(width: 14, height: 14)
        tv.delegate = context.coordinator
        tv.string = text
        applySyntaxHighlighting(to: tv)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
        applySyntaxHighlighting(to: tv)
    }

    private func applySyntaxHighlighting(to tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.098, green: 0.094, blue: 0.086, alpha: 1.0),
            .underlineStyle: 0
        ], range: fullRange)

        let cmdRegex = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+\*?"#)
        for m in cmdRegex.matches(in: storage.string, range: fullRange) {
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(calibratedRed: 0.106, green: 0.286, blue: 0.502, alpha: 1.0),
                range: m.range
            )
        }

        let ns = storage.string as NSString
        for key in ghostKeys {
            var search = fullRange
            while search.length > 0 {
                let r = ns.range(of: key, options: [], range: search)
                if r.location == NSNotFound { break }
                storage.addAttributes([
                    .foregroundColor: NSColor(calibratedRed: 0.651, green: 0.173, blue: 0.169, alpha: 1.0),
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: NSColor(calibratedRed: 0.651, green: 0.173, blue: 0.169, alpha: 1.0)
                ], range: r)
                let next = r.location + r.length
                search = NSRange(location: next, length: max(0, storage.length - next))
            }
        }
        storage.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AppKitTextViewRepresentable
        init(_ parent: AppKitTextViewRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            if let tv = notification.object as? NSTextView {
                parent.text = tv.string
            }
        }
    }
}
