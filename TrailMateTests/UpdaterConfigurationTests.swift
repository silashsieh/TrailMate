import Foundation
import Testing

struct UpdaterConfigurationTests {
    @Test func signedFeedIsVerifiedBeforeExtraction() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true)
    }
}
