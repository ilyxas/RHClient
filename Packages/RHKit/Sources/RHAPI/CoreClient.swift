import Foundation
import RHCrypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. URLSessionTransport in the app, a fake in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum CoreClientError: Error, Equatable, Sendable {
    /// The core refused the request; its answer was signed.
    case rejected(CoreError)
    /// X-RH-Server-Sig is missing or does not verify with the stored core key: Pairing lost.
    case badServerSignature
    /// No answer: network down, Mac asleep, Tailscale off.
    case unreachable(String)
    /// A signed answer this client cannot read.
    case unexpectedResponse(status: Int)
}

/// The paired core: where it is and the key that signs its answers.
public struct CoreEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let coreKeyX963: Data
    public let deviceID: String

    public init(baseURL: URL, coreKeyX963: Data, deviceID: String) {
        self.baseURL = baseURL
        self.coreKeyX963 = coreKeyX963
        self.deviceID = deviceID
    }
}

/// Signed calls to rh-core (SPEC §4.3, contracts/api/openapi.yaml). Every answer,
/// rejections included, is accepted only with a valid X-RH-Server-Sig.
public struct CoreClient: Sendable {
    /// /v1/pair waits for y/n in the terminal for up to 5 minutes.
    public static let pairTimeout: TimeInterval = 330
    public static let requestTimeout: TimeInterval = 30

    public let endpoint: CoreEndpoint
    private let signer: any MessageSigner
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        endpoint: CoreEndpoint, signer: any MessageSigner, transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.signer = signer
        self.transport = transport
        self.now = now
    }

    // MARK: - Operations

    /// A fresh nonce for the next signed request. Also tells whether this device is still registered.
    public func challenge() async throws -> ChallengeResponse {
        let body = try JSONEncoder().encode(ChallengeRequest(device: endpoint.deviceID))
        var request = makeRequest(.challenge, body: body)
        request.timeoutInterval = Self.requestTimeout
        let (data, response) = try await send(request)
        // The core signs a challenge answer with the nonce it issues, or "" when it refuses.
        if response.statusCode == 200 {
            guard let decoded = try? JSONDecoder().decode(ChallengeResponse.self, from: data) else {
                throw CoreClientError.badServerSignature
            }
            try verify(data, response, nonce: decoded.nonce, coreKey: endpoint.coreKeyX963)
            return decoded
        }
        try verify(data, response, nonce: "", coreKey: endpoint.coreKeyX963)
        throw Self.rejection(data, response)
    }

    public func ping() async throws -> PingResponse {
        try await call(.ping, body: Data("{}".utf8))
    }

    public func status() async throws -> StatusResponse {
        try await call(.status)
    }

    public func devices() async throws -> DevicesResponse {
        try await call(.devicesList)
    }

    /// Needs the critical key: Face ID every time.
    public func revoke(deviceID: String) async throws -> RevokeResponse {
        try await call(.devicesRevoke, body: JSONEncoder().encode(RevokeRequest(deviceID: deviceID)))
    }

    /// Current values of data sources, e.g. ``BuiltinData/home``.
    public func data(ids: [String]) async throws -> DataResponse {
        try await call(.dataGet, body: JSONEncoder().encode(DataRequest(ids: ids)))
    }

    /// One page of the Log feed, newest first.
    public func log(_ request: LogRequest) async throws -> LogResponse {
        try await call(.logList, body: JSONEncoder().encode(request))
    }

    /// Quick Access items for Home.
    public func quick() async throws -> QuickResponse {
        try await call(.quickList)
    }

    /// Headers for the /v1/ws upgrade and the nonce its frames are signed with.
    public func eventStreamRequest() async throws -> (request: URLRequest, nonce: String) {
        let nonce = try await challenge().nonce
        var request = makeRequest(.wsOpen, body: nil)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        request.url = components.url
        try await sign(&request, operation: .wsOpen, nonce: nonce, body: Data())
        return (request, nonce)
    }

    /// Registers this phone (SPEC §4.2). No challenge: the nonce is the pairing code,
    /// and the request is signed by both the normal and the critical key.
    public static func pair(
        _ pairing: PairingString, name: String, keys: DeviceKeys, replaces: String?, signer: any MessageSigner,
        transport: any HTTPTransport = URLSessionTransport(), now: Date = Date()
    ) async throws -> PairResponse {
        let body = try JSONEncoder().encode(PairRequest(name: name, keys: keys, replaces: replaces))
        let object = SignedObject(device: keys.deviceID, key: .normal, nonce: pairing.code, op: CoreOperation.pair.op, body: body, now: now)
        let headers = try await SignedHeaders.sign(object, with: signer, criticalCosignature: true)
        var request = makeRequest(.pair, baseURL: pairing.url, body: body)
        request.timeoutInterval = pairTimeout
        for (name, value) in headers.fields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await send(request, transport: transport)
        try verify(data, response, nonce: pairing.code, coreKey: pairing.coreKeyX963)
        guard response.statusCode == 200 else { throw rejection(data, response) }
        guard let paired = try? JSONDecoder().decode(PairResponse.self, from: data), paired.deviceID == keys.deviceID else {
            throw CoreClientError.unexpectedResponse(status: response.statusCode)
        }
        return paired
    }

    // MARK: - Signed request

    private func call<T: Decodable>(_ operation: CoreOperation, body: Data? = nil) async throws -> T {
        let nonce = try await challenge().nonce
        var request = makeRequest(operation, body: body)
        request.timeoutInterval = Self.requestTimeout
        try await sign(&request, operation: operation, nonce: nonce, body: body ?? Data())
        let (data, response) = try await send(request)
        try verify(data, response, nonce: nonce, coreKey: endpoint.coreKeyX963)
        guard response.statusCode == 200 else { throw Self.rejection(data, response) }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw CoreClientError.unexpectedResponse(status: response.statusCode)
        }
        return decoded
    }

    private func sign(_ request: inout URLRequest, operation: CoreOperation, nonce: String, body: Data) async throws {
        guard case .signed(let level) = operation.auth else { preconditionFailure("\(operation.op) is not a signed operation") }
        let object = SignedObject(device: endpoint.deviceID, key: level, nonce: nonce, op: operation.op, body: body, now: now())
        let headers = try await SignedHeaders.sign(object, with: signer)
        for (name, value) in headers.fields {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func makeRequest(_ operation: CoreOperation, body: Data?) -> URLRequest {
        Self.makeRequest(operation, baseURL: endpoint.baseURL, body: body)
    }

    private static func makeRequest(_ operation: CoreOperation, baseURL: URL, body: Data?) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + operation.path)!)
        request.httpMethod = operation.method.rawValue
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Self.send(request, transport: transport)
    }

    private static func send(_ request: URLRequest, transport: any HTTPTransport) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw CoreClientError.unreachable(error.localizedDescription)
        }
    }

    private func verify(_ data: Data, _ response: HTTPURLResponse, nonce: String, coreKey: Data) throws {
        try Self.verify(data, response, nonce: nonce, coreKey: coreKey)
    }

    private static func verify(_ data: Data, _ response: HTTPURLResponse, nonce: String, coreKey: Data) throws {
        guard let key = ECDSA.publicKey(x963: coreKey),
              ServerSignature.isValid(
                  response.value(forHTTPHeaderField: ServerSignature.headerName), nonce: nonce,
                  status: response.statusCode, body: data, coreKey: key
              )
        else { throw CoreClientError.badServerSignature }
    }

    private static func rejection(_ data: Data, _ response: HTTPURLResponse) -> CoreClientError {
        guard let error = CoreError(status: response.statusCode, body: data) else {
            return .unexpectedResponse(status: response.statusCode)
        }
        return .rejected(error)
    }
}
