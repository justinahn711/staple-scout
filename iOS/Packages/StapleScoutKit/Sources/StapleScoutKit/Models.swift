import Foundation

public enum StoreID: String, CaseIterable, Codable, Sendable {
    case wegmans, walmart, target, hmart, lidl
    public var name: String {
        switch self { case .wegmans: return "Wegmans"; case .walmart: return "Walmart"; case .target: return "Target"; case .hmart: return "H Mart"; case .lidl: return "Lidl" }
    }
}
public enum Channel: String, CaseIterable, Codable, Sendable {
    case inStore = "in_store", pickup, online
    public var name: String { switch self { case .inStore: return "In store"; case .pickup: return "Pickup"; case .online: return "Online reference" } }
}
public enum MeasureUnit: String, CaseIterable, Codable, Sendable {
    case oz, lb, g, kg, flOz = "fl_oz", ml, l, each
    public var name: String { self == .flOz ? "fl oz" : rawValue }
    public var basis: MeasureUnit {
        switch self { case .oz, .lb, .g, .kg: return .oz; case .flOz, .ml, .l: return .flOz; case .each: return .each }
    }
    /// Exact grams, milliliters, or count per unit; never convert through rounded reciprocals.
    public var baseFactor: Decimal {
        switch self {
        case .oz: return Decimal(string: "28.349523125")!
        case .lb: return Decimal(string: "453.59237")!
        case .flOz: return Decimal(string: "29.5735295625")!
        case .kg, .l: return 1000
        case .g, .ml, .each: return 1
        }
    }
}
public enum QuantityKind: String, CaseIterable, Codable, Sendable { case fixed, estimated, variable }
public enum MatchStatus: String, CaseIterable, Codable, Sendable { case pending, approved, rejected }
public enum SourceID: String, CaseIterable, Codable, Sendable { case manual, wegmans, hmart }

public struct Staple: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var basis: MeasureUnit
    public var rules: String
    public var needed: Bool
    public var desiredQuantity: Decimal?
    public var desiredUnit: MeasureUnit?
    public init(id: UUID = UUID(), name: String, basis: MeasureUnit, rules: String = "", needed: Bool = true, desiredQuantity: Decimal? = nil, desiredUnit: MeasureUnit? = nil) {
        self.id = id; self.name = name; self.basis = basis; self.rules = rules; self.needed = needed; self.desiredQuantity = desiredQuantity; self.desiredUnit = desiredUnit
    }
}
public struct StoreLocation: Identifiable, Codable, Sendable {
    public var id: UUID
    public var store: StoreID
    public var name: String
    public var code: String?
    public init(id: UUID = UUID(), store: StoreID, name: String, code: String? = nil) { self.id = id; self.store = store; self.name = name; self.code = code }
    // Stable IDs keep independently initialized libraries and Codable references consistent.
    public static let defaults: [StoreLocation] = [
        .init(id: UUID(uuidString: "10000000-0000-0000-0000-000000000133")!, store: .wegmans, name: "Chantilly #133", code: "133"),
        .init(id: UUID(uuidString: "20000000-0000-0000-0000-000000001827")!, store: .target, name: "Target #1827", code: "1827"),
        .init(id: UUID(uuidString: "30000000-0000-0000-0000-000000005969")!, store: .walmart, name: "Chantilly #5969 (tentative)", code: "5969"),
        .init(id: UUID(uuidString: "40000000-0000-0000-0000-000000001112")!, store: .lidl, name: "Lidl US01112", code: "US01112"),
        .init(id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!, store: .hmart, name: "H Mart online reference", code: nil)
    ]
}
public struct ProductVariant: Identifiable, Codable, Sendable {
    public var id: UUID
    public var store: StoreID
    public var productID: String?
    public var barcode: String?
    public var name: String
    public var quantity: Decimal
    public var unit: MeasureUnit
    public var packCount: Int
    public var quantityKind: QuantityKind
    public init(id: UUID = UUID(), store: StoreID, productID: String? = nil, barcode: String? = nil, name: String, quantity: Decimal, unit: MeasureUnit, packCount: Int = 1, quantityKind: QuantityKind = .fixed) {
        self.id = id; self.store = store; self.productID = productID; self.barcode = barcode; self.name = name; self.quantity = quantity; self.unit = unit; self.packCount = packCount; self.quantityKind = quantityKind
    }
}
public struct ProductMatch: Identifiable, Codable, Sendable {
    public var id: UUID
    public var stapleID: UUID
    public var variantID: UUID
    public var status: MatchStatus
    public init(id: UUID = UUID(), stapleID: UUID, variantID: UUID, status: MatchStatus = .pending) { self.id = id; self.stapleID = stapleID; self.variantID = variantID; self.status = status }
}
public struct PriceObservation: Identifiable, Codable, Sendable {
    public var id: UUID
    public var sequence: Int
    public var stapleID: UUID
    public var variantID: UUID
    public var locationID: UUID
    public var channel: Channel
    public var price: Decimal?
    public var available: Bool?
    public var observedAt: Date
    public var retrievedAt: Date?
    public var conditions: String
    public var source: SourceID
    public var sourceURL: String?
    public var validFrom: Date?
    public var validUntil: Date?
    public var sourceExclusion: String?
    public var ingestedAt: Date?
    public init(id: UUID = UUID(), sequence: Int, stapleID: UUID, variantID: UUID, locationID: UUID, channel: Channel, price: Decimal?, available: Bool?, observedAt: Date, retrievedAt: Date? = nil, conditions: String = "", source: SourceID = .manual, sourceURL: String? = nil, validFrom: Date? = nil, validUntil: Date? = nil, sourceExclusion: String? = nil, ingestedAt: Date? = nil) {
        self.id = id; self.sequence = sequence; self.stapleID = stapleID; self.variantID = variantID; self.locationID = locationID; self.channel = channel; self.price = price; self.available = available; self.observedAt = observedAt; self.retrievedAt = retrievedAt; self.conditions = conditions; self.source = source; self.sourceURL = sourceURL; self.validFrom = validFrom; self.validUntil = validUntil; self.sourceExclusion = sourceExclusion; self.ingestedAt = ingestedAt
    }
}
public struct SourceRun: Identifiable, Codable, Sendable {
    public var id: UUID
    public var store: StoreID
    public var locationID: UUID
    public var channel: Channel
    public var attemptedAt: Date
    public var succeededAt: Date?
    public var error: String?
    public var finishedAt: Date?
    public init(id: UUID = UUID(), store: StoreID, locationID: UUID, channel: Channel, attemptedAt: Date, succeededAt: Date? = nil, error: String? = nil, finishedAt: Date? = nil) { self.id = id; self.store = store; self.locationID = locationID; self.channel = channel; self.attemptedAt = attemptedAt; self.succeededAt = succeededAt; self.error = error; self.finishedAt = finishedAt }
}
public struct LibraryState: Codable, Sendable {
    public var staples: [Staple]
    public var locations: [StoreLocation]
    public var preferredLocations: [StoreID: UUID]
    public var variants: [ProductVariant]
    public var matches: [ProductMatch]
    public var observations: [PriceObservation]
    public var reports: [WeeklyReport]
    public var sourceRuns: [SourceRun]
    public var lastRefreshDay: String?
    public init(staples: [Staple] = [], locations: [StoreLocation] = StoreLocation.defaults, preferredLocations: [StoreID: UUID]? = nil, variants: [ProductVariant] = [], matches: [ProductMatch] = [], observations: [PriceObservation] = [], reports: [WeeklyReport] = [], sourceRuns: [SourceRun] = [], lastRefreshDay: String? = nil) {
        self.staples = staples; self.locations = locations
        self.preferredLocations = preferredLocations ?? locations.reduce(into: [:]) { $0[$1.store] = $1.id }
        self.variants = variants; self.matches = matches; self.observations = observations; self.reports = reports; self.sourceRuns = sourceRuns; self.lastRefreshDay = lastRefreshDay
    }
    public func location(for store: StoreID) -> StoreLocation? { locations.first { $0.store == store && $0.id == preferredLocations[store] } }
}
public struct PackageOutlay: Codable, Sendable {
    public var packages: Int
    public var cost: Decimal
    public var excess: Decimal
    public var unit: MeasureUnit
    public init(packages: Int, cost: Decimal, excess: Decimal, unit: MeasureUnit) { self.packages = packages; self.cost = cost; self.excess = excess; self.unit = unit }
}
public struct OfferResult: Identifiable, Codable, Sendable {
    public var id: UUID { observation.id }
    public var observation: PriceObservation
    public var variant: ProductVariant
    public var location: StoreLocation
    public var unitPrice: Decimal?
    public var exclusionReasons: [String]
    public var outlay: PackageOutlay?
    public var eligible: Bool { exclusionReasons.isEmpty && unitPrice != nil }
    public init(observation: PriceObservation, variant: ProductVariant, location: StoreLocation, unitPrice: Decimal?, exclusionReasons: [String], outlay: PackageOutlay? = nil) { self.observation = observation; self.variant = variant; self.location = location; self.unitPrice = unitPrice; self.exclusionReasons = exclusionReasons; self.outlay = outlay }
}
public struct StapleComparison: Identifiable, Codable, Sendable {
    public var id: UUID { staple.id }
    public var staple: Staple
    public var offers: [OfferResult]
    public var winnerID: UUID?
    public var outlayWinnerID: UUID?
    public var winner: OfferResult? { offers.first { $0.id == winnerID } }
    public var outlayWinner: OfferResult? { offers.first { $0.id == outlayWinnerID } }
    public init(staple: Staple, offers: [OfferResult], winnerID: UUID? = nil, outlayWinnerID: UUID? = nil) { self.staple = staple; self.offers = offers; self.winnerID = winnerID; self.outlayWinnerID = outlayWinnerID }
}
public struct ReportRequest: Equatable, Codable, Sendable {
    public var asOf: Date
    public var stores: Set<StoreID>
    public var channel: Channel
    public var neededOnly: Bool
    public init(asOf: Date, stores: Set<StoreID>, channel: Channel = .inStore, neededOnly: Bool = true) { self.asOf = asOf; self.stores = stores; self.channel = channel; self.neededOnly = neededOnly }
}
public struct PriceDrop: Identifiable, Codable, Sendable {
    public var id: UUID
    public var stapleName: String
    public var productName: String
    public var previousObservationID: UUID
    public var observationID: UUID
    public var previousPrice: Decimal
    public var price: Decimal
    public var amount: Decimal { previousPrice - price }
    public init(id: UUID = UUID(), stapleName: String, productName: String, previousObservationID: UUID, observationID: UUID, previousPrice: Decimal, price: Decimal) { self.id = id; self.stapleName = stapleName; self.productName = productName; self.previousObservationID = previousObservationID; self.observationID = observationID; self.previousPrice = previousPrice; self.price = price }
}
public struct WeeklyReport: Identifiable, Codable, Sendable {
    public var id: UUID
    public var request: ReportRequest
    public var generatedAt: Date
    public var comparisons: [StapleComparison]
    public var priceDrops: [PriceDrop]
    public var locations: [StoreLocation]
    public var sourceRuns: [SourceRun]
    public init(id: UUID = UUID(), request: ReportRequest, generatedAt: Date, comparisons: [StapleComparison], priceDrops: [PriceDrop], locations: [StoreLocation], sourceRuns: [SourceRun]) { self.id = id; self.request = request; self.generatedAt = generatedAt; self.comparisons = comparisons; self.priceDrops = priceDrops; self.locations = locations; self.sourceRuns = sourceRuns }
}
