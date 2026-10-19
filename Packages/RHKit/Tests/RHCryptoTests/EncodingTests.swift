import Foundation
import Testing
@testable import RHCrypto

struct EncodingTests {
    @Test func base64IsStrict() {
        #expect(Base64.decode("AQID") == Data([1, 2, 3]))
        #expect(Base64.decode("AQI=") == Data([1, 2]))
        #expect(Base64.decode("AQI") == nil, "missing padding")
        #expect(Base64.decode("AQ I=") == nil, "whitespace")
        #expect(Base64.decode("AQJ=") == nil, "non-zero trailing bits")
        #expect(Base64.decode("AQ-_") == nil, "url alphabet")
    }

    @Test func base64URLWithoutPadding() {
        let bytes = Data([0xfb, 0xff, 0xbf, 0x01])
        let text = Base64.encodeURLNoPadding(bytes)
        #expect(text == "-_-_AQ")
        #expect(Base64.decodeURLNoPadding(text) == bytes)
        #expect(Base64.decodeURLNoPadding("-_-_AQ==") == nil, "padding")
        #expect(Base64.decodeURLNoPadding("+/+/AQ") == nil, "standard alphabet")
        #expect(Base64.decodeURLNoPadding("A") == nil, "impossible length")
    }

    @Test func hexIsLowercase() {
        #expect(Hex.encode([0x00, 0xab, 0xff]) == "00abff")
        #expect(Digest.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
