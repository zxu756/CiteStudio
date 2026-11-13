import SwiftUI

/// Displays Citation Firewall verdicts, 1-click arXiv -> peer-reviewed BibTeX upgrade, and deterministic anti-AI / polish lints.
public struct FirewallAuditDrawer: View {
    @ObservedObject var session: CiteStudioWorkspaceSession
    @ObservedObject var localizer: AppLocalizer

    @MainActor
    public init(session: CiteStudioWorkspaceSession, localizer: AppLocalizer? = nil) {
        self.session = session
        self.localizer = localizer ?? .shared
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Citation Firewall Section
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(localizer.L("Citation Firewall (Crossref + OpenAlex + SQLite)", "引文防火墙（Crossref + OpenAlex + SQLite）"))
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0)
                        .foregroundStyle(CiteStudioTheme.carbonInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(localizer.L("MCP Gate: ERR_UNVERIFIED_CITATION active", "MCP 门禁：ERR_UNVERIFIED_CITATION"))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0)
                        .foregroundStyle(CiteStudioTheme.oxfordNavy)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(CiteStudioTheme.folioRail)

                Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

                VStack(spacing: 0) {
                    ForEach(session.diagnostics) { diag in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(diag.kind.badgeLabel(in: localizer.language))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .tracking(0)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 6.5)
                                    .padding(.vertical, 2)
                                    .background(badgeColor(diag.kind).opacity(0.14))
                                    .foregroundStyle(badgeColor(diag.kind))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                Text(diag.localizedHeadline(in: localizer.language))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .tracking(0)
                                    .foregroundStyle(CiteStudioTheme.carbonInk)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer()

                                if diag.kind == .preprintUpgrade {
                                    Button(localizer.L("Upgrade .bib", "一键升级 .bib")) {
                                        session.applyPreprintUpgrade(for: diag)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .tracking(0)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 8.5)
                                    .padding(.vertical, 3)
                                    .background(CiteStudioTheme.amberGold.opacity(0.16))
                                    .foregroundStyle(CiteStudioTheme.amberGold)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }

                            Text(diag.localizedDetail(in: localizer.language))
                                .font(.system(size: 11))
                                .tracking(0)
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
                    Text(localizer.L("Manuscript Prose & Float Polish", "文稿去 AI 套话与图表规范体检"))
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0)
                        .foregroundStyle(CiteStudioTheme.carbonInk)
                    Spacer()
                    Text(
                        localizer.isChinese
                            ? "共 \(session.lintFindings.count) 项确定性检查"
                            : "\(session.lintFindings.count) deterministic checks"
                    )
                    .font(.system(size: 10.5, design: .monospaced))
                    .tracking(0)
                    .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(CiteStudioTheme.folioRail)

                Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

                VStack(spacing: 0) {
                    ForEach(session.lintFindings.prefix(4)) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(
                                    localizer.isChinese
                                        ? "第 \(item.lineNumber) 行 · \(item.categoryLabel(in: .zhHans))"
                                        : "L\(item.lineNumber) · \(item.category)"
                                )
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .tracking(0)
                                .foregroundStyle(CiteStudioTheme.exLibrisBurgundy)
                                .fixedSize(horizontal: true, vertical: false)

                                Text(item.localizedMatchedText(in: localizer.language))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .tracking(0)
                                    .foregroundStyle(CiteStudioTheme.carbonInk)
                                Spacer()
                            }
                            Text(item.localizedSuggestion(in: localizer.language))
                                .font(.system(size: 11))
                                .tracking(0)
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

    private func badgeColor(_ kind: FirewallVerdictKind) -> Color {
        switch kind {
        case .verified: return CiteStudioTheme.forestGreen
        case .preprintUpgrade, .metadataMismatch, .orphanCite: return CiteStudioTheme.amberGold
        case .retracted, .ghostPaper: return CiteStudioTheme.exLibrisBurgundy
        }
    }
}
