import CoreGraphics
import Testing
@testable import CasRec

@Suite("Capture source identity")
struct CaptureSourceTests {
    @Test("Unresolved sources without an explicit ID receive unique picker IDs")
    func unresolvedSourcesReceiveUniqueIDs() {
        let first = unresolvedWindowSource()
        let second = unresolvedWindowSource()

        #expect(first.identity == nil)
        #expect(second.identity == nil)
        #expect(first.id != second.id)
    }

    @Test("An explicit unresolved ID is retained")
    func explicitUnresolvedIDIsRetained() {
        let source = unresolvedWindowSource(unresolvedID: "provider-window-42")

        #expect(source.unresolvedID == "provider-window-42")
        #expect(source.id == "provider-window-42")
    }
}

private func unresolvedWindowSource(unresolvedID: String? = nil) -> CaptureSource {
    CaptureSource(
        identity: nil,
        kind: .window,
        title: "Untitled",
        appName: nil,
        frame: .zero,
        scWindow: nil,
        scDisplay: nil,
        thumbnail: nil,
        unresolvedID: unresolvedID
    )
}
