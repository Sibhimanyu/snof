import Foundation

/// The same four-verb Firestore REST client as the Mac's (src/remote/firestore-rest.ts),
/// for documents shaped `{ box, sig?, device?, at? }`.
public struct ChannelDocument: Equatable, Sendable {
    public var box: String
    public var sig: String?
    public var device: String?
    public var at: Int64?

    public init(box: String, sig: String? = nil, device: String? = nil, at: Int64? = nil) {
        self.box = box; self.sig = sig; self.device = device; self.at = at
    }

    func encoded() -> [String: Any] {
        var fields: [String: Any] = ["box": ["stringValue": box]]
        if let sig { fields["sig"] = ["stringValue": sig] }
        if let device { fields["device"] = ["stringValue": device] }
        if let at { fields["at"] = ["integerValue": String(at)] }
        return ["fields": fields]
    }

    static func decoded(_ json: [String: Any]) -> ChannelDocument? {
        guard let fields = json["fields"] as? [String: Any],
              let box = (fields["box"] as? [String: Any])?["stringValue"] as? String
        else { return nil }
        let string = { (name: String) in (fields[name] as? [String: Any])?["stringValue"] as? String }
        let at = ((fields["at"] as? [String: Any])?["integerValue"] as? String).flatMap(Int64.init)
        return ChannelDocument(box: box, sig: string("sig"), device: string("device"), at: at)
    }
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public struct FirestoreClient: Sendable {
    public enum Failure: Error, Equatable { case http(Int) }

    let base: URL
    let transport: HTTPTransport

    public init(projectId: String, transport: HTTPTransport = URLSession.shared) {
        base = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents")!
        self.transport = transport
    }

    public func get(_ path: String) async throws -> ChannelDocument? {
        let (data, response) = try await transport.data(for: request(path, method: "GET"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(ChannelDocument.decoded)
    }

    public func set(_ path: String, _ document: ChannelDocument) async throws {
        var request = request(path, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: document.encoded())
        let (_, response) = try await transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.http(status) }
    }

    public func delete(_ path: String) async throws {
        let (_, response) = try await transport.data(for: request(path, method: "DELETE"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) || status == 404 else { throw Failure.http(status) }
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        return request
    }
}
