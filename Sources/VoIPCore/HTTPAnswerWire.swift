import Foundation

/// The native authority's version 1 HTTP messages. Only the body is serialized to JSON.
enum HTTPAnswerWire {
  enum Operation: String, Codable, Sendable {
    case claim, reconcile, release
  }

  struct Body: Encodable, Sendable {
    let version = 1
    let callID: String
    let accountID: String
    let lineID: String
    let actionID: String
    let permitID: String?

    var isValid: Bool {
      [callID, accountID, lineID, actionID].allSatisfy(WireValues.isID)
        && permitID.map(WireValues.isID) != false
    }

    var key: String {
      "v1."
        + Data(actionID.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
  }

  struct Endpoint: Sendable {
    private let base: URLComponents

    init?(_ url: URL) {
      guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
        parts.scheme?.lowercased() == "https", let host = parts.host, isHost(host),
        parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
        parts.port.map({ (1...65535).contains($0) }) != false
      else { return nil }
      let path = parts.percentEncodedPath
      let prefix = path.hasSuffix("/") ? String(path.dropLast()) : path
      if !prefix.isEmpty {
        guard prefix.hasPrefix("/"),
          prefix.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy({ segment in
              segment != "." && segment != ".."
                && segment.wholeMatch(of: #/[A-Za-z0-9._~-]+/#) != nil
            })
        else { return nil }
      }
      parts.scheme = "https"
      parts.percentEncodedPath = prefix
      base = parts
    }

    func url(_ operation: Operation) -> URL? {
      var parts = base
      parts.percentEncodedPath += "/v1/answer/\(operation.rawValue)"
      return parts.url
    }
  }

  private static func isHost(_ host: String) -> Bool {
    !host.isEmpty
      && !host.unicodeScalars.contains {
        WireValues.isWhitespace($0) || #"/\?#@"#.unicodeScalars.contains($0)
      }
  }

  enum Resolution: Sendable {
    case decision(AnswerDecision)
    case unknown, released
  }

  static func response(
    _ data: Data, _ response: URLResponse, operation: Operation, request: Body
  ) throws(AnswerAuthorityFailure) -> Resolution {
    guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
    switch http.statusCode {
    case 200: break
    case 401, 403: throw .credentialsUnavailable
    case 408, 429, 502, 503, 504: throw .network
    default: throw .invalidResponse
    }
    guard http.mimeType?.lowercased() == "application/json",
      http.textEncodingName.map({ $0.lowercased() == "utf-8" }) != false,
      http.value(forHTTPHeaderField: "Idempotency-Key") == request.key,
      !data.contains(0), String(data: data, encoding: .utf8) != nil,
      let decoded = try? JSONDecoder().decode(Reply.self, from: data),
      decoded.callID.utf8.elementsEqual(request.callID.utf8),
      decoded.actionID.utf8.elementsEqual(request.actionID.utf8)
    else { throw .invalidResponse }

    switch (operation, decoded.result) {
    case (.claim, .decision), (.reconcile, .decision), (.reconcile, .unknown),
      (.release, .released):
      return decoded.result
    default: throw .invalidResponse
    }
  }

  private struct Reply: Decodable {
    private enum Kind: String, Decodable { case allow, refuse, unknown, released }
    private struct Reason: Decodable {
      let kind: AnswerRefusal

      init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        try fields.requireOnly(["kind"])
        kind = try fields.decode(AnswerRefusal.self, forKey: "kind")
      }
    }

    let callID: String
    let actionID: String
    let result: Resolution

    init(from decoder: any Decoder) throws {
      let fields = try decoder.container(keyedBy: Key.self)
      guard try fields.decode(Int.self, forKey: "version") == 1 else {
        throw AnswerAuthorityFailure.invalidResponse
      }
      callID = try fields.decode(String.self, forKey: "callID")
      actionID = try fields.decode(String.self, forKey: "actionID")
      var keys: Set<Key> = ["version", "callID", "actionID", "kind"]
      switch try fields.decode(Kind.self, forKey: "kind") {
      case .allow:
        keys.formUnion(["permit", "media"])
        let grant = try fields.decode(Permit.self, forKey: "permit")
        let media = try fields.contains("media") ? fields.decode(Media.self, forKey: "media") : nil
        result = .decision(
          .allow(
            AnswerPermit(
              id: grant.id, expiresAt: grant.expiry, mediaCredentials: media?.credentials)))
      case .refuse:
        keys.insert("reason")
        result = .decision(.refuse(try fields.decode(Reason.self, forKey: "reason").kind))
      case .unknown: result = .unknown
      case .released: result = .released
      }
      try fields.requireOnly(keys)
    }
  }

  private struct Permit: Decodable {
    let id: String
    let expiry: Date

    init(from decoder: any Decoder) throws {
      let fields = try decoder.container(keyedBy: Key.self)
      try fields.requireOnly(["id", "expiresAt"])
      id = try fields.decode(String.self, forKey: "id")
      let stamp = try fields.decode(String.self, forKey: "expiresAt")
      guard WireValues.isID(id), WireValues.isUTCMillisecondTimestamp(stamp) else {
        throw AnswerAuthorityFailure.invalidResponse
      }
      expiry = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp)
    }
  }

  private struct Media: Decodable {
    let credentials: AnswerMediaCredentials

    init(from decoder: any Decoder) throws {
      let fields = try decoder.container(keyedBy: Key.self)
      try fields.requireOnly(["provider", "url", "room", "identity", "token", "expiresAt"])
      let address = try fields.decode(String.self, forKey: "url")
      let room = try fields.decode(String.self, forKey: "room")
      let identity = try fields.decode(String.self, forKey: "identity")
      let token = try fields.decode(String.self, forKey: "token")
      let expiry = try fields.decode(Int64.self, forKey: "expiresAt")
      guard try fields.decode(String.self, forKey: "provider") == "livekit",
        address.hasPrefix("wss://"), !address.contains("\\"),
        !address.unicodeScalars.contains(where: WireValues.isWhitespace),
        let url = URL(string: address, encodingInvalidCharacters: false),
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let host = parts.host, isHost(host), parts.user == nil, parts.password == nil,
        parts.query == nil, parts.fragment == nil,
        !room.isEmpty, !identity.isEmpty, !token.isEmpty,
        (1...9_007_199_254_740_991).contains(expiry)
      else { throw AnswerAuthorityFailure.invalidResponse }
      credentials = AnswerMediaCredentials(
        url: url, room: room, identity: identity, token: token,
        expiresAt: Date(timeIntervalSince1970: TimeInterval(expiry)))
    }
  }

  fileprivate struct Key: CodingKey, Hashable, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(stringLiteral value: String) { self.init(stringValue: value) }
  }
}

extension KeyedDecodingContainer where Key == HTTPAnswerWire.Key {
  fileprivate func requireOnly(_ allowed: Set<Key>) throws {
    guard Set(allKeys).isSubset(of: allowed) else { throw AnswerAuthorityFailure.invalidResponse }
  }
}
