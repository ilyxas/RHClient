import Foundation
import RHCrypto
import Testing
@testable import RHAPI

/// contracts/vectors/ws_frames.json: signed WebSocket frames.
private struct WSFramesFile: Decodable {
    let version: Int
    let core_pub_x963_b64: String
    let ws_open_nonce: String
    let vectors: [WSFrameVector]
}

private struct WSFrameVector: Decodable {
    struct Frame: Codable {
        let seq: Int
        let payload: String
        let sig: String
    }

    let name: String
    let frame: Frame
    let valid: Bool
}

struct EventFrameVectorTests {
    private func load() throws -> (WSFramesFile, String, [String]) {
        let file = try JSONDecoder().decode(WSFramesFile.self, from: ContractsLocation.data("vectors/ws_frames.json"))
        #expect(file.version == 1)
        #expect(!file.vectors.isEmpty)
        // The core sends frames as JSON text; any key order is fine, so re-encode each one.
        let texts = try file.vectors.map { String(decoding: try JSONEncoder().encode($0.frame), as: UTF8.self) }
        return (file, file.core_pub_x963_b64, texts)
    }

    @Test func vectors() throws {
        let (file, key, texts) = try load()
        let coreKey = try #require(ECDSA.publicKey(x963Base64: key))
        for (vector, text) in zip(file.vectors, texts) {
            let event = try? EventFrameReader.open(text, wsOpenNonce: file.ws_open_nonce, coreKey: coreKey)
            #expect((event != nil) == vector.valid, "\(vector.name)")
            if let event {
                #expect(event.seq == vector.frame.seq)
                #expect(event.payload == Data(vector.frame.payload.utf8), "\(vector.name): payload kept as sent")
            }
        }
    }

    @Test func helloAndOrder() throws {
        let (file, key, texts) = try load()
        let coreKey = try #require(ECDSA.publicKey(x963Base64: key))
        let index = try #require(file.vectors.firstIndex { $0.valid && $0.frame.seq == 1 })
        var reader = EventFrameReader(wsOpenNonce: file.ws_open_nonce, coreKey: coreKey)
        let hello = try reader.read(texts[index])
        #expect(hello.type == "hello")
        let data = try hello.data(as: HelloEvent.self)
        #expect(data.device.count == 32)
        #expect(ProtocolTime.parse(data.serverTime) != nil)
        #expect(reader.nextSeq == 2)
        #expect(throws: EventFrameError.outOfOrder(expected: 2, got: 1)) { try reader.read(texts[index]) }
    }

    @Test func otherNonceIsRejected() throws {
        let (file, key, texts) = try load()
        let coreKey = try #require(ECDSA.publicKey(x963Base64: key))
        let index = try #require(file.vectors.firstIndex { $0.valid })
        #expect(throws: EventFrameError.badSignature) {
            try EventFrameReader.open(texts[index], wsOpenNonce: "AAAA", coreKey: coreKey)
        }
    }

    @Test func revokedCloseCodeMatchesContract() {
        #expect(revokedCloseCode == 4403)
    }
}
