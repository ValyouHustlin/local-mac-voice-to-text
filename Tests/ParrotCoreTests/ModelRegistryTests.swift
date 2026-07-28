import Testing
@testable import ParrotCore

@Suite
struct ModelRegistryTests {
    @Test
    func registryHasExactlyOneRecommendedModel() {
        #expect(ModelRegistry.shared.filter(\.recommended).count == 1)
        #expect(ModelRegistry.recommended()?.id == "whisper-base.en")
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
}
