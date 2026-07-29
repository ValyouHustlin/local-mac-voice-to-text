import Foundation

public enum PasteboardRestorationPolicy {
    /// Restore only while Wordhand still owns the clipboard. If another app or
    /// the user copied something after Wordhand staged its transcript, that
    /// newer clipboard content wins.
    public static func shouldRestore(
        ownedChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        ownedChangeCount == currentChangeCount
    }
}
