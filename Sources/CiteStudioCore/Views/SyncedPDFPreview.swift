import AppKit
import PDFKit
import SwiftUI

/// Displays the compiled `PDFKit` manuscript preview (or an honest empty state when no PDF has been compiled).
public struct SyncedPDFPreview: View {
    @ObservedObject var session: CiteStudioWorkspaceSession
    @ObservedObject var localizer: AppLocalizer

    @MainActor
    public init(session: CiteStudioWorkspaceSession, localizer: AppLocalizer? = nil) {
        self.session = session
        self.localizer = localizer ?? .shared
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(localizer.L("Typeset PDF Preview", "排版 PDF 预览"))
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(0)
                        .foregroundStyle(CiteStudioTheme.carbonInk)
                    Spacer()
                    if let doc = session.compiledPDFDocument {
                        Text(
                            localizer.isChinese
                                ? "共 \(doc.pageCount) 页"
                                : "\(doc.pageCount) page(s)"
                        )
                        .font(.system(size: 10.5, design: .monospaced))
                        .tracking(0)
                        .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                        .fixedSize(horizontal: true, vertical: false)
                    } else if session.isSnapshotMode {
                        Text(localizer.L("[DEMO MOCKUP]", "[DEMO · 演示示意]"))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .tracking(0)
                            .foregroundStyle(CiteStudioTheme.amberGold)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(CiteStudioTheme.folioRail)

                Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

                if !session.isSnapshotMode, let doc = session.compiledPDFDocument {
                    PDFKitViewRepresentable(document: doc)
                } else if session.isSnapshotMode {
                    demoTypesetAcademicSheetPreview
                } else {
                    emptyPDFPlaceholder
                }
            }
            .background(CiteStudioTheme.manuscriptSheet)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CiteStudioTheme.spineRule, lineWidth: 1))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CiteStudioTheme.vellumPage)
    }

    private var emptyPDFPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizer.L("No compiled PDF", "暂无已编译的 PDF"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CiteStudioTheme.carbonInk)
            Text(
                localizer.L(
                    "Click \"Compile PDF\" when a manuscript is loaded and Tectonic is installed, or run `CiteStudio --cli compile <file.tex>` in the terminal.",
                    "载入文稿并安装 Tectonic 后可点击“编译 PDF”生成预览，或在终端运行 `CiteStudio --cli compile <file.tex>`。"
                )
            )
            .font(.system(size: 11.5))
            .foregroundStyle(CiteStudioTheme.marginaliaGrey)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CiteStudioTheme.manuscriptSheet)
    }

    private var demoTypesetAcademicSheetPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                Text("[DEMO] Sub-Linear KV-Cache Compression via IO-Aware Block Paging")
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(CiteStudioTheme.carbonInk)
                    .multilineTextAlignment(.center)
                Text(localizer.L("Sample [DEMO] Preview Sheet (not a compiled user document)", "[DEMO · 演示数据] 示例排版预览页（非用户真实文稿）"))
                    .font(.system(size: 11, design: .serif))
                    .tracking(0)
                    .foregroundStyle(CiteStudioTheme.amberGold)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)

            Text("1  Introduction")
                .font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundStyle(CiteStudioTheme.carbonInk)

            Text("Autoregressive decoding in Transformer models [1] is bottlenecked by memory bandwidth rather than arithmetic throughput.")
                .font(.system(size: 11.5, design: .serif))
                .foregroundStyle(CiteStudioTheme.carbonInk)

            Text("2  IO-Aware Tiling and Block Paging")
                .font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundStyle(CiteStudioTheme.carbonInk)
                .padding(.top, 2)

            Text("Tiling attention blocks inside SRAM avoids materializing intermediate matrices in HBM [2]. Non-contiguous virtual block tables eliminate external KV fragmentation [3].")
                .font(.system(size: 11.5, design: .serif))
                .foregroundStyle(CiteStudioTheme.carbonInk)

            Text("3  Ablation and Unverified Claim Check")
                .font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundStyle(CiteStudioTheme.carbonInk)
                .padding(.top, 2)

            Text("It is worth noting that speculative zero-entropy tensor folding [?] plays a pivotal role in latency reduction.")
                .font(.system(size: 11.5, design: .serif))
                .foregroundStyle(CiteStudioTheme.exLibrisBurgundy)

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CiteStudioTheme.manuscriptSheet)
    }
}

private struct PDFKitViewRepresentable: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.95, alpha: 1.0)
        view.document = document
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }
    }
}
