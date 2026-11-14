import Foundation
import Testing
@testable import CiteStudioCore

@Suite("WorkspaceTests", .timeLimit(.minutes(1)))
struct WorkspaceTests {

    @Test("C8 (Row 7): Default CiteStudioWorkspaceSession() starts completely empty (0 manuscript, 0 bibliography, 0 diagnostics, 0 lints), and Load Demo sets isDemoMode = true")
    @MainActor
    func c8DefaultSessionIsEmptyAndLoadDemoMarksDemoMode() throws {
        let session = CiteStudioWorkspaceSession()
        #expect(!session.isDemoMode)
        #expect(session.projectTitle.isEmpty)
        #expect(session.manuscriptFilename.isEmpty)
        #expect(session.manuscriptText.isEmpty)
        #expect(session.bibText.isEmpty)
        #expect(session.bibEntries.isEmpty)
        #expect(session.inlineCitations.isEmpty)
        #expect(session.diagnostics.isEmpty)
        #expect(session.lintFindings.isEmpty)
        #expect(session.outlineSections.isEmpty)
        #expect(session.selectedCiteKey == nil)
        #expect(session.activeEvidence == nil)
        #expect(session.compiledPDFDocument == nil)

        // Explicit Load Demo populates sample data with [DEMO] tags and unverified initial diagnostics
        session.loadDemo()
        #expect(session.isDemoMode)
        #expect(session.projectTitle.contains("[DEMO]"))
        #expect(!session.manuscriptText.isEmpty)
        #expect(session.bibEntries.count == 4)
        #expect(session.diagnostics.allSatisfy { $0.kind == .unverified })

        // Clearing returns cleanly to empty state
        session.clearWorkspace()
        #expect(!session.isDemoMode)
        #expect(session.manuscriptText.isEmpty)
        #expect(session.bibEntries.isEmpty)
        #expect(session.diagnostics.isEmpty)
        #expect(session.lintFindings.isEmpty)
    }
}
