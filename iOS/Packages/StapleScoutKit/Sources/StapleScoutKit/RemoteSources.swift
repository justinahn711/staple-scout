import Foundation

public protocol RemoteSourceLoading: Sendable {
    func sources() async throws -> RemoteSourceSnapshot
}

public enum RemoteSourceState: String, Codable, Sendable { case disabled, pending, ready, partial, failed, stale }
public struct RemoteEvidenceDates: Codable, Sendable {
    public let observedAt: Date
    public let retrievedAt: Date
    public let validFrom: Date?
    public let validUntil: Date?
}
public struct RemoteSourceStatus: Codable, Sendable, Identifiable {
    public let provider: String
    public let store: StoreID
    public let storeCode: String?
    public let channel: Channel
    public let technicallySupported: Bool
    public let channelVerified: Bool
    public let fetchingEnabled: Bool
    public let publicAccessApproved: Bool
    public let attribution: String
    public let referenceOnly: Bool
    public let limitation: String
    public let cacheTTLSeconds: Double
    public let displayTTLSeconds: Double
    public let maximumObservationAgeSeconds: Double
    public let retentionSeconds: Double
    public let state: RemoteSourceState
    public let evidence: RemoteEvidenceDates?
    public let pendingMeaning: String?
    public let lastAttemptedAt: Date?
    public let lastSucceededAt: Date?
    public var id: String { "\(store.rawValue)|\(storeCode ?? "")|\(channel.rawValue)" }
    public var context: SharedPriceContext { SharedPriceContext(store: store, storeCode: storeCode, channel: channel) }
    public var permitsRequests: Bool { technicallySupported && channelVerified && fetchingEnabled && publicAccessApproved && state != .disabled }
    public var statusText: String {
        switch state {
        case .disabled: return "Price retrieval disabled"
        case .pending: return "Pending — no complete result yet, or work is active"
        case .ready: return "A complete result is available; coverage may be limited"
        case .partial: return "Partial results; some prices could not be checked"
        case .failed: return "Last operation failed; saved evidence keeps its date"
        case .stale: return "Source evidence is stale"
        }
    }
}

/// Immutable, validated exact-context catalog. It is held in memory, never in the private library.
public struct RemoteSourceSnapshot: Sendable {
    public let generatedAt: Date
    public let sources: [RemoteSourceStatus]
    private let receivedAt: Date
    private let receivedUptime: TimeInterval
    public func isCurrent(at date: Date = Date()) -> Bool {
        date >= receivedAt && date.timeIntervalSince(receivedAt) < 300 && date.timeIntervalSince(generatedAt) < 300
            && ProcessInfo.processInfo.systemUptime >= receivedUptime && ProcessInfo.processInfo.systemUptime - receivedUptime < 300
    }
    public func status(location: StoreLocation, channel: Channel? = nil) -> RemoteSourceStatus? {
        sources.first { $0.store == location.store && $0.storeCode == location.code && (channel == nil || $0.channel == channel) }
    }
    public func require(_ context: SharedPriceContext, at date: Date = Date()) throws -> RemoteSourceStatus {
        guard isCurrent(at: date), let source = sources.first(where: { $0.context == context }), source.permitsRequests else {
            throw RetailClientError.unsupportedSource("Check source status in My stores. This exact store and channel must be approved and available before requesting prices.")
        }
        return source
    }
    public static func decode(_ data: Data, at date: Date = Date()) throws -> Self {
        do {
            try SharedJSONStructure.validateSources(data)
            let envelope = try SharedMarketWire.decoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1, envelope.generatedAt.timeIntervalSince1970 > 0,
                  envelope.generatedAt <= date.addingTimeInterval(5), date.timeIntervalSince(envelope.generatedAt) < 300,
                  envelope.sources.count <= 5, Set(envelope.sources.map(\.id)).count == envelope.sources.count else { throw invalid() }
            for value in envelope.sources { try validate(value, generatedAt: envelope.generatedAt) }
            return Self(generatedAt: envelope.generatedAt, sources: envelope.sources, receivedAt: date, receivedUptime: ProcessInfo.processInfo.systemUptime)
        } catch { throw invalid() }
    }
    private struct Envelope: Decodable { let schemaVersion: Int; let generatedAt: Date; let sources: [RemoteSourceStatus] }
    private static func invalid() -> RetailClientError { .invalidResponse("The pilot returned unsupported source status. Check again later; saved evidence is preserved.") }
    private static func validate(_ source: RemoteSourceStatus, generatedAt: Date) throws {
        let expected = StoreLocation.defaults.first { $0.store == source.store }!
        let validChannel: Bool
        switch source.store {
        case .wegmans, .lidl: validChannel = source.channel == .inStore
        case .hmart: validChannel = source.channel == .online
        case .walmart: validChannel = source.channel == .pickup
        case .target: validChannel = [.inStore, .pickup].contains(source.channel)
        }
        func text(_ value: String, maximum: Int, nonempty: Bool = false) -> Bool {
            (!nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && value.utf8.count <= maximum
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.subtracting(.newlines).contains($0) }
        }
        let limits = [source.cacheTTLSeconds, source.displayTTLSeconds, source.maximumObservationAgeSeconds, source.retentionSeconds]
        guard source.storeCode == expected.code, validChannel,
              text(source.provider, maximum: 100, nonempty: true), source.provider.range(of: #"^[a-z][a-z0-9_]{0,99}$"#, options: .regularExpression) != nil,
              text(source.attribution, maximum: 1024, nonempty: true), text(source.limitation, maximum: 4096),
              limits.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 172_800 }),
              !source.fetchingEnabled || (source.publicAccessApproved && source.technicallySupported && source.channelVerified && limits.allSatisfy({ $0 > 0 })),
              source.state == .disabled || source.permitsRequests,
              (source.pendingMeaning != nil) == (source.state == .pending),
              source.pendingMeaning.map({ text($0, maximum: 1024, nonempty: true) }) ?? true,
              source.store != .hmart || (source.referenceOnly && !source.limitation.isEmpty),
              source.store != .lidl || !source.limitation.isEmpty,
              source.store != .target || source.channelVerified || !source.fetchingEnabled else { throw invalid() }
        for operational in [source.lastAttemptedAt, source.lastSucceededAt].compactMap({ $0 }) {
            guard operational.timeIntervalSince1970 > 0, operational <= generatedAt else { throw invalid() }
        }
        if let evidence = source.evidence {
            guard evidence.observedAt.timeIntervalSince1970 > 0, evidence.observedAt <= evidence.retrievedAt,
                  evidence.retrievedAt <= generatedAt,
                  evidence.validFrom.map({ $0.timeIntervalSince1970 > 0 && $0 <= generatedAt }) ?? true,
                  evidence.validUntil.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 && $0 > (evidence.validFrom ?? .distantPast) }) ?? true else { throw invalid() }
        }
    }
}

public actor RemoteSourceCatalog {
    private var snapshot: RemoteSourceSnapshot?
    private var revision = UUID()
    private var sessionEpoch: Int?
    public init() {}
    public func replace(_ value: RemoteSourceSnapshot) { snapshot = value; sessionEpoch = nil; revision = UUID() }
    public func clear() { snapshot = nil; sessionEpoch = nil; revision = UUID() }
    func beginCheck() -> UUID { snapshot = nil; sessionEpoch = nil; revision = UUID(); return revision }
    func replace(_ value: RemoteSourceSnapshot, expected: UUID, sessionEpoch: Int) -> Bool {
        guard revision == expected else { return false }; snapshot = value; self.sessionEpoch = sessionEpoch; revision = UUID(); return true
    }
    func capture() -> (RemoteSourceSnapshot?, UUID, Int?) { (current(), revision, sessionEpoch) }
    func matches(_ value: UUID) -> Bool { revision == value && current() != nil }
    public func current() -> RemoteSourceSnapshot? { snapshot?.isCurrent() == true ? snapshot : nil }
}

/// This is an adapter attestation, not a grant of public access. Remote Walmart/Target
/// evidence additionally needs an approved exact catalog tuple and strict retailer URL.
public struct SharedRetailProvenance: Codable, Sendable {
    public let schemaVersion: Int
    public let provider: String
    public let store: StoreID
    public let storeCode: String
    public let channel: Channel
    public let seller: String
    public let priceType: String
    public init(provider: String, store: StoreID, storeCode: String, channel: Channel, seller: String, priceType: String) {
        schemaVersion = 1; self.provider = provider; self.store = store; self.storeCode = storeCode
        self.channel = channel; self.seller = seller; self.priceType = priceType
    }
}

/// JSONDecoder normally accepts duplicate/unknown keys. Source status is an authority
/// boundary: reject both, including duplicate escaped keys, before decoding values.
enum SharedJSONStructure {
    static func rejectDuplicates(_ data: Data) throws {
        guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        var scan = Scan(bytes: Array(text.utf8)); try scan.value(depth: 0); scan.space()
        guard scan.index == scan.bytes.count else { throw Failure.invalid }
    }
    static func validateProvenance(_ data: Data) throws {
        try rejectDuplicates(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
        let records = (root["products"] as? [[String: Any]]) ?? (root["product"] as? [String: Any]).map { [$0] } ?? []
        for record in records {
            guard let raw = record["provenance"], !(raw is NSNull) else { continue }
            guard let object = raw as? [String: Any], Set(object.keys) == ["schemaVersion", "provider", "store", "storeCode", "channel", "seller", "priceType"] else { throw Failure.invalid }
        }
    }
    static func validateSources(_ data: Data) throws {
        guard data.count <= 32_768, let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        var scan = Scan(bytes: Array(text.utf8)); try scan.value(depth: 0); scan.space()
        guard scan.index == scan.bytes.count,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "generatedAt", "sources"],
              let array = root["sources"] as? [[String: Any]], array.count <= 5,
              text.range(of: #""schemaVersion"\s*:\s*1\s*[,}]"#, options: .regularExpression) != nil else { throw Failure.invalid }
        let required: Set<String> = ["provider", "store", "channel", "technicallySupported", "channelVerified", "fetchingEnabled", "publicAccessApproved", "attribution", "referenceOnly", "limitation", "cacheTTLSeconds", "displayTTLSeconds", "maximumObservationAgeSeconds", "retentionSeconds", "state"]
        let optional: Set<String> = ["storeCode", "evidence", "pendingMeaning", "lastAttemptedAt", "lastSucceededAt"]
        for object in array {
            guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional)) else { throw Failure.invalid }
            if let evidence = object["evidence"], !(evidence is NSNull) {
                guard let object = evidence as? [String: Any], Set(["observedAt", "retrievedAt"]).isSubset(of: Set(object.keys)),
                      Set(object.keys).isSubset(of: ["observedAt", "retrievedAt", "validFrom", "validUntil"]) else { throw Failure.invalid }
            }
        }
    }
    enum Failure: Error { case invalid }
    struct Scan {
        let bytes: [UInt8]; var index = 0
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func string() throws -> String {
            let start = index; guard index < bytes.count && bytes[index] == 34 else { throw Failure.invalid }; index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { guard index < bytes.count else { throw Failure.invalid }; index += 1 }
                else if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            }
            throw Failure.invalid
        }
        mutating func value(depth: Int) throws {
            space(); guard depth <= 6, index < bytes.count else { throw Failure.invalid }
            if bytes[index] == 34 { _ = try string(); return }
            if bytes[index] == 123 || bytes[index] == 91 {
                let object = bytes[index] == 123, close: UInt8 = object ? 125 : 93
                index += 1; space(); var keys = Set<String>()
                if index < bytes.count && bytes[index] == close { index += 1; return }
                while index < bytes.count {
                    if object { space(); let key = try string(); guard keys.insert(key).inserted else { throw Failure.invalid }; space(); guard index < bytes.count && bytes[index] == 58 else { throw Failure.invalid }; index += 1 }
                    try value(depth: depth + 1); space(); guard index < bytes.count else { throw Failure.invalid }
                    if bytes[index] == close { index += 1; return }
                    guard bytes[index] == 44 else { throw Failure.invalid }; index += 1
                }
                throw Failure.invalid
            }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw Failure.invalid }
        }
    }
}
