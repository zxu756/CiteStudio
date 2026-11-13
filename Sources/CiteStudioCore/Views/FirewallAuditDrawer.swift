import SwiftUI

/// Displays Citation Firewall verdicts, 1-click arXiv -> peer-reviewed BibTeX upgrade, and deterministic anti-AI / polish lints.
public struct FirewallAuditDrawer: View {
    @ObservedObject var session: CiteStudioWorkspaceSession

    public init(session: CiteStudioWorkspaceSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Citation Firewall Section
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Citation Firewall (Crossref + OpenAlex + SQLite)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(CiteStudioTheme.carbonInk)
                    Spacer()
                    Text("MCP Gate: ERR_UNVERIFIED_CITATION active")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CiteStudioTheme.oxfordNavy)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(CiteStudioTheme.folioRail)

                Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

                VStack(spacing: 0) {
                    ForEach(session.diagnostics) { diag in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(badgeLabel(diag.kind))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(badgeColor(diag.kind).opacity(0.14))
                                    .foregroundStyle(badgeColor(diag.kind))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                Text(diag.headline)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(CiteStudioTheme.carbonInk)

                                Spacer()

                                if diag.kind == .preprintUpgrade {
                                    Button("Upgrade .bib") {
                                        session.applyPreprintUpgrade(for: diag)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(CiteStudioTheme.amberGold.opacity(0.16))
                                    .foregroundStyle(CiteStudioTheme.amberGold)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }

                            Text(diag.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        Rectangle().fill(CiteStudioTheme.spineRule.opacity(0.65)).frame(height: 1)
                    }
                }
            }
            .background(CiteStudioTheme.manuscriptSheet)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CiteStudioTheme.spineRule, lineWidth: 1))

            // Writing Quality & Anti-AI Linter Section
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Manuscript Prose & Float Polish")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(CiteStudioTheme.carbonInk)
                    Spacer()
                    Text("\(session.lintFindings.count) deterministic checks")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(CiteStudioTheme.folioRail)

                Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

                VStack(spacing: 0) {
                    ForEach(session.lintFindings.prefix(4)) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("L\(item.lineNumber) · \(item.category)")
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(CiteStudioTheme.exLibrisBurgundy)
                                Text(item.matchedText)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(CiteStudioTheme.carbonInk)
                                Spacer()
                            }
                            Text(item.suggestion)
                                .font(.system(size: 11))
                                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)

                        Rectangle().fill(CiteStudioTheme.spineRule.opacity(0.65)).frame(height: 1)
                    }
                }
            }
            .background(CiteStudioTheme.manuscriptSheet)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CiteStudioTheme.spineRule, lineWidth: 1))

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CiteStudioTheme.vellumPage)
    }

    private func badgeLabel(_ kind: FirewallVerdictKind) -> String {
        switch kind {
        case .verified: return "VERIFIED"
        case .preprintUpgrade: return "UPGRADE"
        case .metadataMismatch: return "MISMATCH"
        case .retracted: return "RETRACTED"
        case .ghostPaper: return "GHOST BLOCK"
        case .orphanCite: return "ORPHAN"
        }
    }

    private func badgeColor(_ kind: FirewallVerdictKind) -> Color {
        switch kind {
        case .verified: return CiteStudioTheme.forestGreen
        case .preprintUpgrade, .metadataMismatch, .orphanCite: return CiteStudioTheme.amberGold
        case .retracted, .ghostPaper: return CiteStudioTheme.exLibrisBurgundy
        }
    }
}
