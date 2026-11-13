import AppKit
import PDFKit
import SwiftUI

/// Displays the live `PDFKit` manuscript preview plus the BM25-bound Local PDF Provenance Highlight Card.
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
            // Typeset Manuscript Sheet Preview
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(localizer.L("Typeset PDF Preview (SyncTeX bidirectional)", "排版 PDF 实时预览（SyncTeX 双向定位）"))
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(0)
                        .foregroundStyle(CiteStudioTheme.carbonInk)
                    Spacer()
                    Text(localizer.L("Page 1 · 100%", "第 1 页 · 100%"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .tracking(0)
                        .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(CiteStudioTheme.folioRail)

                Rectangle().fill(CiteStudioTheme.spineRule).frame(height: 1)

                if !session.isSnapshotMode, let doc = session.compiledPDFDocument {
                    PDFKitViewRepresentable(document: doc)
                } else {
                    typesetAcademicSheetPreview
                }
            }
            .background(CiteStudioTheme.manuscriptSheet)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CiteStudioTheme.spineRule, lineWidth: 1))

            // Local Reference PDF Provenance Card (BM25 + CGRect)
            if let ev = session.activeEvidence {
                provenanceEvidenceCard(ev)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CiteStudioTheme.vellumPage)
    }

    private var typesetAcademicSheetPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                Text("Sub-Linear KV-Cache Compression via IO-Aware Block Paging")
                    .font(.system(size: 14.5, weight: .bold, design: .serif))
                    .foregroundStyle(CiteStudioTheme.carbonInk)
                    .multilineTextAlignment(.center)
                Text(localizer.L("Systems & Verification Lab · Compiled with Tectonic", "Systems & Verification Lab · Tectonic 实时排版"))
                    .font(.system(size: 11, design: .serif))
                    .tracking(0)
                    .foregroundStyle(CiteStudioTheme.marginaliaGrey)
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Tiling attention blocks inside SRAM avoids materializing intermediate matrices in HBM [2]. Non-contiguous virtual block tables eliminate external KV fragmentation [3].")
                    .font(.system(size: 11.5, design: .serif))
                    .foregroundStyle(CiteStudioTheme.carbonInk)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CiteStudioTheme.forestGreen.opacity(0.09))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(CiteStudioTheme.forestGreen.opacity(0.45), lineWidth: 1)
            )

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

    private func provenanceEvidenceCard(_ ev: PDFPassageEvidence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(CiteStudioTheme.forestGreen)
                Text(
                    localizer.isChinese
                        ? "本地 PDF 原文证据已绑定 (\(ev.citeKey))"
                        : "Local PDF Provenance Bound (\(ev.citeKey))"
                )
                .font(.system(size: 12, weight: .bold))
                .tracking(0)
                .foregroundStyle(CiteStudioTheme.forestGreen)
                Spacer()
                Text(
                    localizer.isChinese
                        ? String(format: "BM25 匹配 %.0f%%", ev.confidenceScore * 100)
                        : String(format: "BM25 %.0f%%", ev.confidenceScore * 100)
                )
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .tracking(0)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(CiteStudioTheme.forestGreen.opacity(0.14))
                .foregroundStyle(CiteStudioTheme.forestGreen)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text("\"\(ev.verbatimSnippet)\"")
                .font(.system(size: 11.5, design: .serif))
                .foregroundStyle(CiteStudioTheme.carbonInk)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(
                    localizer.isChinese
                        ? "\(ev.pdfFilename) · 第 \(ev.pageNumber) 页"
                        : "\(ev.pdfFilename) · Page \(ev.pageNumber)"
                )
                .font(.system(size: 10.5, design: .monospaced))
                .tracking(0)
                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                Spacer()
                Text(
                    localizer.isChinese
                        ? String(format: "坐标框 [%.0f, %.0f, %.0f, %.0f]", ev.rectX, ev.rectY, ev.rectWidth, ev.rectHeight)
                        : String(format: "Rect [%.0f, %.0f, %.0f, %.0f]", ev.rectX, ev.rectY, ev.rectWidth, ev.rectHeight)
                )
                .font(.system(size: 10.5, design: .monospaced))
                .tracking(0)
                .foregroundStyle(CiteStudioTheme.marginaliaGrey)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(12)
        .background(CiteStudioTheme.manuscriptSheet)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(CiteStudioTheme.forestGreen.opacity(0.45), lineWidth: 1)
        )
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
