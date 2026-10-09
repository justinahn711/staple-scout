# Native iPhone implementation contract

The user clarified iPhone and Swift on October8, 2026. Native SwiftUI, iOS17+, local SwiftData storage. No Python server dependency. Existing Python code is historical reference. No Costco, account login, captcha bypass, fake production data, automatic approvals, deployment or scheduled background work.

Shared code is a Foundation-only Swift package `StapleScoutKit` in `iOS/Packages/StapleScoutKit`. Public structs Codable/Sendable, mutable properties and public initializers. Money/quantities use Decimal. IDs UUID. App persistence stores Codable LibraryState in a SwiftData record atomically.

Core API (worker1 owns Models.swift, ComparisonEngine.swift, ReportEngine.swift and core tests; parent owns Package.swift):
- StoreID: String CaseIterable Codable Sendable: wegmans,walmart,target,hmart,lidl; `name: String`.
- Channel: String CaseIterable Codable Sendable: inStore="in_store",pickup,online; `name: String`.
- MeasureUnit: String CaseIterable Codable Sendable: oz,lb,g,kg,flOz="fl_oz",ml,l,each. `name: String`, `basis: MeasureUnit` (.oz/.flOz/.each), `baseFactor: Decimal` exact grams/ml/count.
- QuantityKind: fixed,estimated,variable. MatchStatus: pending,approved,rejected. SourceID: manual,wegmans,hmart.
- Staple: id:UUID, name:String, basis:MeasureUnit, rules:String="", needed:Bool=true, desiredQuantity:Decimal?=nil, desiredUnit:MeasureUnit?=nil.
- StoreLocation: id:UUID, store:StoreID, name:String, code:String?; static `defaults: [StoreLocation]` with confirmedWegmans133, Target1827, Walmart5969(tentative), LidlUS01112, HMartonline code nil. Locations immutable in application history; preference changes append new context.
- ProductVariant: id:UUID, store:StoreID, productID:String?=nil, barcode:String?=nil, name:String, quantity:Decimal, unit:MeasureUnit, packCount:Int=1, quantityKind:QuantityKind=.fixed.
- ProductMatch: id:UUID, stapleID:UUID, variantID:UUID, status:MatchStatus=.pending.
- PriceObservation: id:UUID, sequence:Int, stapleID:UUID, variantID:UUID, locationID:UUID, channel:Channel, price:Decimal?, available:Bool?, observedAt:Date, retrievedAt:Date?=nil, conditions:String="", source:SourceID=.manual, sourceURL:String?=nil, validFrom:Date?=nil, validUntil:Date?=nil, sourceExclusion:String?=nil, ingestedAt:Date?=nil.
- SourceRun: id:UUID, store:StoreID, locationID:UUID, channel:Channel, attemptedAt:Date, succeededAt:Date?=nil, error:String?=nil, finishedAt:Date?=nil. Codable.
- LibraryState: staples:[Staple]=[], locations:[StoreLocation]=StoreLocation.defaults, preferredLocations:[StoreID:UUID] initialized from locations, variants:[ProductVariant]=[], matches:[ProductMatch]=[], observations:[PriceObservation]=[], reports:[WeeklyReport]=[], sourceRuns:[SourceRun]=[], lastRefreshDay:String?=nil. init() and all-property public init with defaults. `location(for: StoreID)->StoreLocation?`.
- OfferResult: id:UUID (observation.id), observation:PriceObservation, variant:ProductVariant, location:StoreLocation, unitPrice:Decimal?, exclusionReasons:[String], outlay:PackageOutlay?; eligible:Bool computed.
- PackageOutlay: packages:Int, cost:Decimal, excess:Decimal, unit:MeasureUnit.
- StapleComparison: id:UUID(staple.id), staple:Staple, offers:[OfferResult], winnerID:UUID?, outlayWinnerID:UUID?; winner:OfferResult?, outlayWinner:OfferResult?.
- ComparisonEngine.compare(state:LibraryState, channel:Channel=.inStore, stores:Set<StoreID>=Set(StoreID.allCases), neededOnly:Bool=false, asOf:Date=Date())->[StapleComparison]. Current preferred contexts only; latest per variant/context/channel by observedAt then sequence. Pending/rejected, old>=48h, future, conditional, unknown, unavailable, estimated/variable, incompatible units/sourceExclusion cannot win. Shelf and pickup separate; online never ranks. Exact whole-package cost separately ranks. Missing evidence remains visible.
- ReportRequest: asOf:Date, stores:Set<StoreID>, channel:Channel=.inStore, neededOnly:Bool=true; Equatable Codable Sendable. Canonical equality independent set order.
- PriceDrop: id:UUID, stapleName:String, productName:String, previousObservationID:UUID, observationID:UUID, previousPrice:Decimal, price:Decimal; amount:Decimal computed.
- WeeklyReport: id:UUID, request:ReportRequest, generatedAt:Date, comparisons:[StapleComparison], priceDrops:[PriceDrop], locations:[StoreLocation], sourceRuns:[SourceRun].
- ReportEngine.build(state:LibraryState, request:ReportRequest, generatedAt:Date=Date()) throws ->WeeklyReport. Reject future cutoffs/empty stores/online; reuse saved identical request in state.reports; frozen output settings and cutoff evidence (imports require retrievedAt and ingestedAt<=cutoff; source outcomes require finishedAt<=cutoff); price drops immediately prior same variant/location/channel/source ordered timestamp+sequence. No cherry picking unknown/unavailable/conditional previous offers.

Networking API (worker2 owns RetailClient.swift and networking tests/fixtures; imports the above models):
- FetchRequest: variant:ProductVariant, location:StoreLocation, channel:Channel.
- FetchedPrice: productID:String, productName:String, barcode:String?, price:Decimal?, quantity:Decimal?, unit:MeasureUnit?, packCount:Int, quantityKind:QuantityKind, available:Bool?, observedAt:Date, retrievedAt:Date, conditions:String, source:SourceID, sourceURL:String, sourceExclusion:String? optional. Public initializer.
- SourceCapability: enum or struct exposing `isConnected: Bool`, `message:String`; static `forLocation(_ location:StoreLocation, channel:Channel)->SourceCapability`. Wegmans exact133 shelf only. HMart online reference only; for shelf/pickup notconnected. Other stores explicitlyblocked/disconnected.
- RetailClient: actor or Sendable class; `init(session:URLSession=.shared)`; `fetch(_ request:FetchRequest) async throws ->FetchedPrice`. Exact IDs, validated context, safe numeric prices using Decimal, URLSession timeout≤10s; only normal supported Wegmans133 public product JSON and HMartVTEX online. No guessed endpoints/keys/challenge probing. Explicit sourceURL, conservative Date/Age, stockflags, condition/estimated handling. HMart never becomes Centreville shelf. Copy sanitized existing fixtures from research branches for offline tests.

All agents share this isolated branch. No one commits/pushes or changes files outside their ownership. Parent owns app, SwiftData persistence, Xcode project, Package.swift, docs and integration. Notify parent of any contract changes before editing others' files. Do not test real databases or call live retailers; no subagents.

Refresh links use the latest active package per staple, retailer product, preferred location and channel. Superseded packages remain in history but cannot import duplicate observations or invalidate a newly approved package on later refreshes. A single product request updates all active staple links.

A cached source response that changes package identity but predates newer evidence is rejected atomically and recorded as a failed source run. It cannot replace the newer package or reset its approval.
