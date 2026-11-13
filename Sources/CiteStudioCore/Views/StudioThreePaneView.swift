import SwiftUI

/// Main Oxford Archival Vellum 3-pane academic IDE workspace:
/// Left: Outline & Bibliography Folio | Center: LaTeX/Typst Editor | Right: SyncTeX PDF & Citation Firewall.
public struct StudioThreePaneView: View {
    @ObservedObject var session: CiteStudioWorkspaceSession

    public init(session: CiteStudioWorkspaceSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            topArchivalHeader
            Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

            statusTelemetryStrip
            Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

            HStack(spacing: 0) {
                leftFolioRail
                    .frame(width: 248)
                    .frame(maxHeight: .infinity)

                Rectangle().fill(CiteStudioTheme.spineRule).frame(width: 1)

                ManuscriptEditorView(session: session)
                    .frame(width: 506)
                    .frame(maxHeight: .infinity)

                Rectangle().fill(CiteStudioTheme.spineRule).frame(width: 1)

                rightPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CiteStudioTheme.vellumPage)
        .foregroundStyle(CiteStudioTheme.carbonInk)
        .preferredColorScheme(.light)
    }

    // MARK: - Header & Status Strip

    private var topArchivalHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(CiteStudioTheme.oxfordNavy)
                    .frame(width: 28, height: 28)
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("CiteStudio")
                    .font(.system(size: 17, weight: .bold, design: .serif))
                Text("Zero-hallucination LaTeX & Typst evidence IDE")
                    .font(.system(size: 12))
                    .foregroundStyle(CiteStudioTheme.marginaliaGrey)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(CiteStudioRightTab.allCases) { tab in
                    let active = session.rightTab == tab
                    Button {
                        session.rightTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: active ? .semibold : .medium))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(active ? CiteStudioTheme.oxfordNavy : CiteStudioTheme.folioRail)
                            .foregroundStyle(active ? Color.white : CiteStudioTheme.carbonInk)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                Task { await session.refreshAudit() }
            } label: {
                Text("Verify Citations")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CiteStudioTheme.manuscriptSheet)
                    .foregroundStyle(CiteStudioTheme.oxfordNavy)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CiteStudioTheme.oxfordNavy.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                session.compileLivePDF()
            } label: {
                Text("Compile PDF")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CiteStudioTheme.forestGreen)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(CiteStudioTheme.vellumPage)
    }

    private var statusTelemetryStrip: some View {
        HStack(spacing: 20) {
            metricItem(
                label: "Verified sources",
                value: "\(session.verifiedCount)/\(session.bibEntries.count) indexed",
                color: CiteStudioTheme.forestGreen
            )
            dividerDot
            metricItem(
                label: "Ghost / Retracted blocked",
                value: "\(session.blockedCount) blocked",
                color: session.blockedCount > 0 ? CiteStudioTheme.exLibrisBurgundy : CiteStudioTheme.forestGreen
            )
            dividerDot
            metricItem(
                label: "arXiv -> Venue upgrades",
                value: "\(session.upgradeAvailableKeys.count) ready",
                color: CiteStudioTheme.amberGold
            )
            dividerDot
            metricItem(
                label: "Prose & float lints",
                value: "\(session.lintFindings.count) items",
                color: CiteStudioTheme.oxfordNavy
            )
            Spacer()
            Text(session.compilerStatusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(CiteStudioTheme.folioRail)
    }

    private var dividerDot: some View {
        Circle()
            .fill(CiteStudioTheme.spineRule)
            .frame(width: 4, height: 4)
    }

    private func metricItem(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label + ":")
                .font(.system(size: 11.5))
                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    // MARK: - Left Folio Rail

    private var leftFolioRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bibliography Folio (references.bib)")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(CiteStudioTheme.carbonInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CiteStudioTheme.folioRail)

            Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

            ForEach(session.bibEntries) { entry in
                let isGhost = session.ghostOrRetractedKeys.contains(entry.citeKey)
                let isUpgrade = session.upgradeAvailableKeys.contains(entry.citeKey)
                let dotColor = isGhost
                    ? CiteStudioTheme.exLibrisBurgundy
                    : (isUpgrade ? CiteStudioTheme.amberGold : CiteStudioTheme.forestGreen)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(dotColor).frame(width: 7, height: 7)
                        Text(entry.citeKey)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CiteStudioTheme.carbonInk)
                        Spacer()
                        if let yr = entry.year {
                            Text(String(yr))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                        }
                    }
                    Text("\(entry.firstAuthorSurname) et al. · \(shortVenue(entry.venue))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(session.selectedCiteKey == entry.citeKey ? CiteStudioTheme.manuscriptSheet : Color.clear)

                Rectangle().fill(CiteStudioTheme.spineRule.opacity(0.65)).frame(height: 1)
            }

            Text("Manuscript Outline")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(CiteStudioTheme.oxfordNavy)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(session.outlineSections, id: \.line) { sec in
                HStack {
                    Text(sec.title.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 11))
                        .foregroundStyle(CiteStudioTheme.carbonInk)
                    Spacer()
                    Text("L\(sec.line)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Circle().fill(CiteStudioTheme.forestGreen).frame(width: 6, height: 6)
                Text("Offline SQLite FTS5 + Firewall")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CiteStudioTheme.marginaliaGrey)
            }
            .padding(14)
        }
        .background(CiteStudioTheme.folioRail.opacity(0.55))
    }

    @ViewBuilder
    private var rightPane: some View {
        switch session.rightTab {
        case .pdfPreview:
            SyncedPDFPreview(session: session)
        case .firewallDrawer:
            FirewallAuditDrawer(session: session)
        }
    }

    private func shortVenue(_ raw: String?) -> String {
        guard let v = raw, !v.isEmpty else { return "Unindexed" }
        if v.contains("Neural Information Processing") { return "NeurIPS" }
        if v.contains("arXiv") { return "arXiv Preprint" }
        if v.contains("Synthetic Preprints") { return "Unverified" }
        return v
    }
}
