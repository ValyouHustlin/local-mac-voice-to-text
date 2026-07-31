import Foundation
import WordhandCore

enum TranscriberFactory {
    static func make(
        model: TranscriptionModel,
        vocabulary: DictionaryVocabularySource = DictionaryVocabularySource()
    ) -> any Transcribing {
        switch model.engine {
        case .whisperKit:
            return WhisperKitTranscriber(
                model: model,
                vocabulary: vocabulary
            )
        case .parakeet:
            return ParakeetUnifiedTranscriber(model: model)
        }
    }
}
