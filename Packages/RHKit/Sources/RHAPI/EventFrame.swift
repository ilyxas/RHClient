import CryptoKit
import Foundation
import RHCrypto

/// One verified message from /v1/ws (contracts/api/events.schema.json).
public struct CoreEvent: Equatable, Sendable {
    public let seq: Int
    public let type: String
    /// The whole payload JSON text ({seq, type, data}); decode `data` by `type`.
    /// It may hold fractional numbers, so it is not parsed with JCS.
    public let payload: Data
}

/// Close code the core uses when the device is revoked.
public let revokedCloseCode = 4403

public enum EventFrameError: Error, Equatable, Sendable {
    case malformed
    case badSignature
    case seqMismatch
    case outOfOrder(expected: Int, got: Int)
}

/// Verifies frames of one WebSocket connection: signature with the ws.open nonce,
/// payload.seq equal to the frame seq, and seq going 1, 2, 3, …
public struct EventFrameReader: Sendable {
    private let wsOpenNonce: String
    // Kept as bytes: CryptoKit keys are not Sendable everywhere.
    private let coreKeyX963: Data
    public private(set) var nextSeq = 1

    public init(wsOpenNonce: String, coreKey: P256.Signing.PublicKey) {
        self.wsOpenNonce = wsOpenNonce
        self.coreKeyX963 = coreKey.x963Representation
    }

    public mutating func read(_ frameText: String) throws(EventFrameError) -> CoreEvent {
        guard let coreKey = ECDSA.publicKey(x963: coreKeyX963) else { throw .badSignature }
        let event = try Self.open(frameText, wsOpenNonce: wsOpenNonce, coreKey: coreKey)
        guard event.seq == nextSeq else { throw .outOfOrder(expected: nextSeq, got: event.seq) }
        nextSeq += 1
        return event
    }

    /// One frame on its own, without the order check.
    public static func open(
        _ frameText: String, wsOpenNonce: String, coreKey: P256.Signing.PublicKey
    ) throws(EventFrameError) -> CoreEvent {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(frameText.utf8)), frame.seq >= 1 else {
            throw .malformed
        }
        let payload = Data(frame.payload.utf8)
        let message = JCS.canonicalize(.object([
            "v": .integer(1),
            "nonce": .string(wsOpenNonce),
            "seq": .integer(Int64(frame.seq)),
            "body": .string(Digest.sha256Hex(payload)),
        ]))
        guard ECDSA.isValid(signatureBase64: frame.sig, message: Data(message), publicKey: coreKey) else {
            throw .badSignature
        }
        guard let header = try? JSONDecoder().decode(PayloadHeader.self, from: payload) else { throw .malformed }
        guard header.seq == frame.seq else { throw .seqMismatch }
        return CoreEvent(seq: frame.seq, type: header.type, payload: payload)
    }

    private struct Frame: Decodable {
        let seq: Int
        let payload: String
        let sig: String
    }

    private struct PayloadHeader: Decodable {
        let seq: Int
        let type: String
    }
}

/// data of the first event on every connection.
public struct HelloEvent: Decodable, Equatable, Sendable {
    public let device: String
    public let serverTime: String

    enum CodingKeys: String, CodingKey {
        case device
        case serverTime = "server_time"
    }
}

extension CoreEvent {
    /// Decodes `data` of the payload as `T`.
    public func data<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(Envelope<T>.self, from: payload).data
    }

    private struct Envelope<T: Decodable>: Decodable {
        let data: T
    }
}
