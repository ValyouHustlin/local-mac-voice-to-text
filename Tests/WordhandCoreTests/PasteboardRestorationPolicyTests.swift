import Testing
@testable import WordhandCore

@Suite
struct PasteboardRestorationPolicyTests {
    @Test
    func restoresWhenWordhandStillOwnsTheClipboard() {
        #expect(
            PasteboardRestorationPolicy.shouldRestore(
                ownedChangeCount: 42,
                currentChangeCount: 42
            )
        )
    }

    @Test
    func preservesNewerClipboardChanges() {
        #expect(
            !PasteboardRestorationPolicy.shouldRestore(
                ownedChangeCount: 42,
                currentChangeCount: 43
            )
        )
    }
}
