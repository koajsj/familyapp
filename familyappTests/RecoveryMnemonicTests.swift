import XCTest
@testable import familyapp

final class RecoveryMnemonicTests: XCTestCase {
    func testKnownBIP39PhraseValidatesAndDerivesSecret() throws {
        let mnemonic = try BIP39Mnemonic.parse(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        )
        XCTAssertEqual(mnemonic.words.count, 12)
        XCTAssertFalse(mnemonic.recoverySecret.isEmpty)
    }

    func testIncorrectBIP39ChecksumIsRejected() {
        XCTAssertThrowsError(
            try BIP39Mnemonic.parse(
                "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ability"
            )
        )
    }

    func testGeneratedMnemonicRoundTripsThroughValidation() throws {
        let generated = try BIP39Mnemonic.generate()
        XCTAssertEqual(try BIP39Mnemonic.parse(generated.phrase), generated)
    }
}
