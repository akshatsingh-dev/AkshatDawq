import Testing
@testable import DAWQ

@Test func modelCatalogHasRecommended() {
    let recommended = OnDeviceModel.available.filter(\.isRecommended)
    #expect(recommended.count == 1)
}

@Test func modelCatalogAllHaveSlugs() {
    for model in OnDeviceModel.available {
        #expect(!model.modelSlug.isEmpty)
    }
}
