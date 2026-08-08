import Foundation
import Testing
@testable import DAWQ

@Test func modelCatalogHasRecommended() {
    let recommended = OnDeviceModel.available.filter(\.isRecommended)
    #expect(recommended.count == 1)
}

@Test func modelCatalogEntriesAreWellFormed() {
    for model in OnDeviceModel.available {
        #expect(!model.ggufFilename.isEmpty)
        #expect(URL(string: model.downloadURL)?.scheme == "https")
    }
}

@Test func modelCatalogIDsAreUnique() {
    let ids = OnDeviceModel.available.map(\.id)
    #expect(Set(ids).count == ids.count)
}
