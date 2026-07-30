import ArgumentParser
import Foundation
import WordhandCore

struct DictionaryCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictionary",
        abstract: "Manage local, editable recognition corrections.",
        subcommands: [Add.self]
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add or update one pronunciation or recognition alias."
        )

        @Option(
            name: .customLong("heard-as"),
            help: "What local Whisper commonly hears."
        )
        var heardAs: String

        @Option(
            name: .customLong("replace-with"),
            help: "The canonical spelling to insert."
        )
        var replaceWith: String

        @Flag(
            name: .long,
            help: "Match only a complete word instead of a phrase."
        )
        var wholeWord: Bool = false

        func run() throws {
            let spoken = heardAs.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = replaceWith.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty, !canonical.isEmpty else {
                throw ValidationError("--heard-as and --replace-with cannot be empty.")
            }

            let store = DictionaryStore(fileURL: DictionaryStore.defaultFileURL())
            var document = try store.installBundledDefaults()
            let mode: DictionaryEntry.MatchMode = wholeWord ? .word : .phrase
            let spokenKey = Self.normalized(spoken)
            let now = Date()

            if let index = document.entries.firstIndex(where: {
                !$0.isCaseSensitive
                    && $0.matchMode == mode
                    && Self.normalized($0.spokenForm) == spokenKey
            }) {
                document.entries[index].spokenForm = spoken
                document.entries[index].replacement = canonical
                document.entries[index].isEnabled = true
                document.entries[index].origin = nil
                document.entries[index].starterVocabularyOrder = nil
                document.entries[index].updatedAt = now
            } else {
                document.entries.append(DictionaryEntry(
                    spokenForm: spoken,
                    replacement: canonical,
                    matchMode: mode,
                    updatedAt: now
                ))
            }

            try store.save(document)
            print("Saved local dictionary alias. Restart Wordhand to load it.")
        }

        private static func normalized(_ value: String) -> String {
            value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }
}
