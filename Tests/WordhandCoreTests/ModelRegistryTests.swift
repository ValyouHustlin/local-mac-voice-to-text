import Testing
@testable import WordhandCore

@Suite
struct ModelRegistryTests {
    @Test
    func registryHasExactlyOneRecommendedModel() {
        #expect(ModelRegistry.shared.filter(\.recommended).count == 1)
        #expect(ModelRegistry.recommended()?.id == "whisper-large-v3")
        #expect(
            ModelRegistry.recommended()?.whisperKitID
                == "openai_whisper-large-v3-v20240930_626MB"
        )
    }

    @Test
    func registryIDsAreUniqueAndModelsAreValid() {
        #expect(Set(ModelRegistry.shared.map(\.id)).count == ModelRegistry.shared.count)
        for model in ModelRegistry.shared {
            #expect(!model.id.isEmpty)
            #expect(model.sizeMB > 0)
            #expect(!model.languages.isEmpty)
            if model.engine == .whisperKit {
                #expect(model.whisperKitID != nil)
            }
        }
    }

    @Test
    func parakeetUnifiedIsSelectableWithoutPretendingToBeWhisper() throws {
        let model = try #require(
            ModelRegistry.find("parakeet-unified-en-0.6b")
        )

        #expect(model.engine == .parakeet)
        #expect(model.whisperKitID == nil)
        #expect(model.languages == ["en"])
        #expect(!model.recommended)
    }
}
