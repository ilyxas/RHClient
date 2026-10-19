import Testing
@testable import RHCrypto

/// Local cases for behaviour the shared vectors may not cover: rejected input.
struct JCSTests {
    private func canonical(_ text: String) throws -> String {
        String(decoding: try JCS.canonicalize(jsonText: text), as: UTF8.self)
    }

    @Test func sortsKeysByUTF16CodeUnits() throws {
        // U+1F600 is 0xD83D 0xDE00 in UTF-16, so it sorts before U+FF61, unlike by code point.
        #expect(try canonical(#"{"｡":2,"😀":1,"a":3}"#) == #"{"a":3,"😀":1,"｡":2}"#)
    }

    @Test func escapesLikeJSONStringify() throws {
        #expect(try canonical(#"["A\/\u001f\n "]"#) == "[\"A/\\u001f\\n\u{2028}\"]")
    }

    @Test func dropsWhitespaceAndNormalizesMinusZero() throws {
        #expect(try canonical(" { \"b\" : [ true , null , -0 ] , \"a\" : \"x\" } ") == #"{"a":"x","b":[true,null,0]}"#)
    }

    @Test func rejectsFractionsAndExponents() {
        #expect(throws: JCSError.unsupportedNumber(offset: 1)) { try JCS.parse("[1.0]") }
        #expect(throws: JCSError.unsupportedNumber(offset: 1)) { try JCS.parse("[1e3]") }
    }

    @Test func rejectsUnsafeIntegers() {
        #expect(throws: JCSError.integerOutOfRange(offset: 0)) { try JCS.parse("9007199254740992") }
    }

    @Test func rejectsDuplicateKeysAndLoneSurrogates() {
        #expect(throws: JCSError.duplicateKey("a")) { try JCS.parse(#"{"a":1,"a":2}"#) }
        #expect(throws: JCSError.loneSurrogate(offset: 1)) { try JCS.parse(#""\ud800""#) }
    }

    @Test func rejectsTrailingData() {
        #expect(throws: JCSError.trailingData(offset: 3)) { try JCS.parse("{} x") }
    }
}
