import Foundation
import SwiftUI

/// Main Oxford Archival Vellum 3-pane workspace:
/// Left: Outline & Bibliography Folio | Center: LaTeX/Typst Editor | Right: PDF Preview & Citation Firewall.
public struct StudioThreePaneView: View {
    @ObservedObject var session: CiteStudioWorkspaceSession
    @ObservedObject var localizer: AppLocalizer

    @MainActor
    public init(session: CiteStudioWorkspaceSession, localizer: AppLocalizer? = nil) {
        self.session = session
        self.localizer = localizer ?? .shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            topArchivalHeader
            Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

            if session.isDemoMode {
                demoModeBanner
                Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)
            }

            statusTelemetryStrip
            Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

            HStack(spacing: 0) {
                leftFolioRail
                    .frame(width: 248)
                    .frame(maxHeight: .infinity)

                Rectangle().fill(CiteStudioTheme.spineRule).frame(width: 1)

                ManuscriptEditorView(session: session, localizer: localizer)
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
        .onAppear {
            Self.emitUIStateSnapshotIfRequested(session: session, language: localizer.language)
        }
    }

    private static func emitUIStateSnapshotIfRequested(session: CiteStudioWorkspaceSession, language: AppLanguage) {
        guard let outPath = ProcessInfo.processInfo.environment["CITESTUDIO_UI_STATE_FILE"],
              !outPath.isEmpty else { return }
        let payload: [String: Any] = [
            "language": language.rawValue,
            "isDemoMode": session.isDemoMode,
            "manuscriptChars": session.manuscriptText.count,
            "bibEntries": session.bibEntries.count,
            "diagnostics": session.diagnostics.count,
            "lintFindings": session.lintFindings.count
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        }
    }

    // MARK: - Header & Status Strip

    private var demoModeBanner: some View {
        HStack(spacing: 10) {
            Text(localizer.L("[DEMO]", "[DEMO · 演示数据]"))
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .tracking(0)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(CiteStudioTheme.amberGold.opacity(0.18))
                .foregroundStyle(CiteStudioTheme.amberGold)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(
                localizer.L(
                    "Displaying built-in sample manuscript & bibliography. Use --cli verify / lint / compile or --mcp for user files.",
                    "当前展示内置示例文稿与参考文献。核查用户真实文件请使用命令行 --cli verify / lint / compile 或 --mcp 服务。"
                )
            )
            .font(.system(size: 11))
            .tracking(0)
            .foregroundStyle(CiteStudioTheme.carbonInk)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(CiteStudioTheme.amberGold.opacity(0.08))
    }

    private var topArchivalHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(CiteStudioTheme.oxfordNavy)
                    .frame(width: 28, height: 28)
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("CiteStudio")
                    .font(.system(size: 17, weight: .bold, design: .serif))
                if session.isDemoMode {
                    Text(localizer.L("[DEMO]", "[演示数据]"))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(CiteStudioTheme.amberGold)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(localizer.L("LaTeX & Typst Citation Firewall & Prose Linter", "LaTeX 与 Typst 引文核查与行文体检"))
                    .font(.system(size: 12))
                    .tracking(0)
                    .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(CiteStudioRightTab.allCases) { tab in
                    let active = session.rightTab == tab
                    Button {
                        session.rightTab = tab
                    } label: {
                        Text(tab.label(in: localizer.language))
                            .font(.system(size: 12, weight: active ? .semibold : .medium))
                            .tracking(0)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(active ? CiteStudioTheme.oxfordNavy : CiteStudioTheme.folioRail)
                            .foregroundStyle(active ? Color.white : CiteStudioTheme.carbonInk)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            CiteStudioLanguageTogglePill(localizer: localizer)

            Button {
                if session.isDemoMode {
                    session.clearWorkspace()
                } else {
                    session.loadDemo()
                }
            } label: {
                Text(
                    session.isDemoMode
                        ? localizer.L("Clear Demo", "清空演示")
                        : localizer.L("Load Demo", "载入演示")
                )
                .font(.system(size: 12, weight: .semibold))
                .tracking(0)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(CiteStudioTheme.amberGold.opacity(0.14))
                .foregroundStyle(CiteStudioTheme.amberGold)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                Task { await session.refreshAudit() }
            } label: {
                Text(localizer.L("Verify Citations", "核验引文"))
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(CiteStudioTheme.manuscriptSheet)
                    .foregroundStyle(CiteStudioTheme.oxfordNavy)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CiteStudioTheme.oxfordNavy.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                session.compileLivePDF()
            } label: {
                Text(localizer.L("Compile PDF", "编译 PDF"))
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 11)
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
        HStack(spacing: 18) {
            metricItem(
                label: localizer.L("Verified sources", "已验证文献"),
                value: localizer.isChinese
                    ? "\(session.verifiedCount)/\(session.bibEntries.count) 篇"
                    : "\(session.verifiedCount)/\(session.bibEntries.count)",
                color: CiteStudioTheme.forestGreen
            )
            dividerDot
            metricItem(
                label: localizer.L("Blocked", "已拦截"),
                value: localizer.isChinese
                    ? "\(session.blockedCount) 处"
                    : "\(session.blockedCount)",
                color: session.blockedCount > 0 ? CiteStudioTheme.exLibrisBurgundy : CiteStudioTheme.forestGreen
            )
            dividerDot
            metricItem(
                label: localizer.L("Unverified", "未验证"),
                value: localizer.isChinese
                    ? "\(session.unverifiedCount) 处"
                    : "\(session.unverifiedCount)",
                color: CiteStudioTheme.amberGold
            )
            dividerDot
            metricItem(
                label: localizer.L("Prose & float lints", "行文与图表体检"),
                value: localizer.isChinese
                    ? "\(session.lintFindings.count) 项"
                    : "\(session.lintFindings.count)",
                color: CiteStudioTheme.oxfordNavy
            )
            Spacer()
            Text(session.localizedCompilerStatus(in: localizer.language))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0)
                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                .fixedSize(horizontal: true, vertical: false)
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
                .tracking(0)
                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .tracking(0)
                .foregroundStyle(color)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Left Folio Rail

    private var leftFolioRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizer.L("Bibliography Folio", "参考文献列表"))
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0)
                .foregroundStyle(CiteStudioTheme.carbonInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CiteStudioTheme.folioRail)

            Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

            if session.bibEntries.isEmpty {
                Text(localizer.L("No bibliography entries loaded.", "尚未载入参考文献条目。"))
                    .font(.system(size: 11))
                    .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ForEach(session.bibEntries) { entry in
                    let isGhost = session.ghostOrRetractedKeys.contains(entry.citeKey)
                    let isUpgrade = session.upgradeAvailableKeys.contains(entry.citeKey)
                    let dotColor = isGhost
                        ? CiteStudioTheme.exLibrisBurgundy
                        : (isUpgrade ? CiteStudioTheme.amberGold : CiteStudioTheme.oxfordNavy)

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
                        Text(
                            localizer.isChinese
                                ? "\(entry.firstAuthorSurname) 等 · \(shortVenue(entry.venue))"
                                : "\(entry.firstAuthorSurname) et al. · \(shortVenue(entry.venue))"
                        )
                        .font(.system(size: 10.5))
                        .tracking(0)
                        .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(session.selectedCiteKey == entry.citeKey ? CiteStudioTheme.manuscriptSheet : Color.clear)

                    Rectangle().fill(CiteStudioTheme.spineRule.opacity(0.65)).frame(height: 1)
                }
            }

            Text(localizer.L("Manuscript Outline", "文稿章节大纲"))
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0)
                .foregroundStyle(CiteStudioTheme.oxfordNavy)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if session.outlineSections.isEmpty {
                Text(localizer.L("No sections.", "暂无章节。"))
                    .font(.system(size: 11))
                    .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            } else {
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
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Circle().fill(CiteStudioTheme.oxfordNavy).frame(width: 6, height: 6)
                Text(localizer.L("Crossref · OpenAlex · SQLite", "Crossref · OpenAlex · SQLite 缓存"))
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(0)
                    .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(CiteStudioTheme.folioRail.opacity(0.55))
    }

    @ViewBuilder
    private var rightPane: some View {
        switch session.rightTab {
        case .pdfPreview:
            SyncedPDFPreview(session: session, localizer: localizer)
        case .firewallDrawer:
            FirewallAuditDrawer(session: session, localizer: localizer)
        }
    }

    private func shortVenue(_ raw: String?) -> String {
        guard let v = raw, !v.isEmpty else {
            return localizer.L("Unspecified", "未填写来源")
        }
        if v.contains("Neural Information Processing") { return "NeurIPS" }
        if v.contains("arXiv") { return localizer.L("arXiv Preprint", "arXiv 预印本") }
        if v.contains("Synthetic Preprints") { return localizer.L("Demo Fake Venue", "演示虚构期刊") }
        return v
    }
}
