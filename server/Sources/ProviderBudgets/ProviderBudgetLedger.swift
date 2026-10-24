import Foundation
import ClientSessions
import ServiceOwnership

struct MissLease: Sendable { let id: String; let clientID: String }
struct UnitReservation: Sendable { let id: String; let missID: String; let clientID: String }

/// Every durable row represents one potentially billable network operation,
/// independent of cache keys, result counts, retailer engines and credentials.
public actor ProviderBudgetLedger {
    private let ownership: ServiceOwnership?
    private let database: BudgetSQLite
    private let policy: ProviderBudgetPolicy
    private let now: @Sendable () -> Date
    public nonisolated let enabled: Bool
    private let retention: TimeInterval = 62 * 86_400

    public init(databasePath: String, policy: ProviderBudgetPolicy? = nil, ownership: ServiceOwnership? = nil, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try ownership?.claimDatabase(databasePath)
        self.ownership = ownership
        let policy = try policy ?? ProviderBudgetPolicy()
        let database = try BudgetSQLite(path: databasePath)
        self.database = database; self.policy = policy; self.enabled = policy.enabled; self.now = now
        let fingerprint = [policy.providerHourly, policy.providerDaily, policy.providerMonthly, policy.clientDaily,
                           policy.clientMonthly, policy.globalMissesDaily, policy.globalMissesMonthly, policy.clientMissesDaily,
                           policy.clientMissesMonthly, policy.maximumConcurrentMisses, policy.maximumConcurrentRequests, policy.maximumRequestsPerMiss].map(String.init).joined(separator: ":")
        try database.transaction {
            if let existing = try database.rows("SELECT policy FROM budget_configuration WHERE id = 1").first {
                guard existing["policy"] == fingerprint else { throw ProviderBudgetError.invalidRequest }
            } else { try database.run("INSERT INTO budget_configuration (id, policy) VALUES (1, ?)", [fingerprint]) }
        }
        if let ownership {
            try ownership.validate(databasePath: databasePath)
            // The non-expiring locks prove the predecessor cannot still send.
            // Never replay or refund: restart time begins a full conservative
            // hour/day/31-day charge for every unresolved operation.
            try database.transaction {
                let sampled = now().timeIntervalSince1970
                guard sampled.isFinite, (0..<253_402_300_800).contains(sampled) else { throw ProviderBudgetError.storageUnavailable }
                let previous = try database.rows("SELECT last_seen FROM budget_clock WHERE id = 1").first?["last_seen"].flatMap(Double.init) ?? 0
                let time = max(sampled, previous)
                try database.run("INSERT INTO budget_clock (id, last_seen) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen", [String(time)])
                try database.run("UPDATE budget_reservations SET state = 'uncertain', created_at = ? WHERE state IN ('reserved', 'dispatched')", [String(time)])
                try database.run("UPDATE budget_misses SET active = 0 WHERE active = 1")
            }
        }
    }

    func beginMiss(principal: ClientPrincipal) throws -> MissLease {
        guard enabled else { throw ProviderBudgetError.disabled }
        let client = try clientID(principal)
        return try clockedTransaction { time in try createMiss(client: client, time: time) }
    }

    func admit(principal: ClientPrincipal) throws -> (MissLease, UnitReservation) {
        try Task.checkCancellation()
        guard enabled else { throw ProviderBudgetError.disabled }
        let client = try clientID(principal)
        return try clockedTransaction { time in
            let lease = try createMiss(client: client, time: time)
            let first = try reserveUnit(lease: lease, purpose: .search, time: time)
            return (lease, first)
        }
    }

    private func createMiss(client: String, time: Double) throws -> MissLease {
        try prune(time)
        guard try count("budget_misses", "active = 1") < policy.maximumConcurrentMisses,
              try count("budget_misses", "active = 1 AND client_id = ?", [client]) == 0 else { throw ProviderBudgetError.workPending }
        guard try count("budget_misses", "created_at > ?", [String(time - 86_400)]) < policy.globalMissesDaily,
              try count("budget_misses", "created_at > ?", [String(time - 31 * 86_400)]) < policy.globalMissesMonthly else { throw ProviderBudgetError.providerLimit }
        let periods = try calendarBounds(time)
        guard try count("budget_misses", "client_id = ? AND created_at >= ? AND created_at < ?", [client, String(periods.day), String(periods.dayEnd)]) < policy.clientMissesDaily,
              try count("budget_misses", "client_id = ? AND created_at >= ? AND created_at < ?", [client, String(periods.month), String(periods.monthEnd)]) < policy.clientMissesMonthly else { throw ProviderBudgetError.clientLimit }
        if try count("budget_clients", "client_id = ?", [client]) == 0 {
            guard try count("budget_clients", "1 = 1") < 50 else { throw ProviderBudgetError.clientLimit }
            try database.run("INSERT INTO budget_clients (client_id) VALUES (?)", [client])
        }
        let lease = MissLease(id: UUID().uuidString, clientID: client)
        try database.run("INSERT INTO budget_misses (miss_id, client_id, created_at, active) VALUES (?, ?, ?, 1)", [lease.id, client, String(time)])
        return lease
    }
    func reserve(lease: MissLease, purpose: ProviderPurpose) throws -> UnitReservation {
        try Task.checkCancellation()
        guard enabled else { throw ProviderBudgetError.disabled }
        return try clockedTransaction { time in try reserveUnit(lease: lease, purpose: purpose, time: time) }
    }

    private func reserveUnit(lease: MissLease, purpose: ProviderPurpose, time: Double) throws -> UnitReservation {
        guard let miss = try database.rows("SELECT * FROM budget_misses WHERE miss_id = ? AND client_id = ? AND active = 1", [lease.id, lease.clientID]).first else { throw ProviderBudgetError.invalidRequest }
        guard Int(miss["operations"] ?? "") ?? Int.max < policy.maximumRequestsPerMiss else { throw ProviderBudgetError.operationLimit }
        guard try count("budget_reservations", "state IN ('reserved', 'dispatched')") < policy.maximumConcurrentRequests else { throw ProviderBudgetError.workPending }
        // Unknown account renewal/throughput boundaries: rolling windows
        // avoid a doubled allowance at UTC hour/month transitions.
        for (seconds, limit) in [(3_600.0, policy.providerHourly), (86_400.0, policy.providerDaily), (31 * 86_400.0, policy.providerMonthly)] {
            guard try count("budget_reservations", "(created_at > ? OR state IN ('reserved', 'dispatched'))", [String(time - seconds)]) < limit else { throw ProviderBudgetError.providerLimit }
        }
        let bounds = try calendarBounds(time)
        for (start, end, limit) in [(bounds.day, bounds.dayEnd, policy.clientDaily), (bounds.month, bounds.monthEnd, policy.clientMonthly)] {
            guard try count("budget_reservations", "client_id = ? AND ((created_at >= ? AND created_at < ?) OR state IN ('reserved', 'dispatched'))", [lease.clientID, String(start), String(end)]) < limit else { throw ProviderBudgetError.clientLimit }
        }
        let reservation = UnitReservation(id: UUID().uuidString, missID: lease.id, clientID: lease.clientID)
        try database.run("INSERT INTO budget_reservations (reservation_id, miss_id, created_at, client_id, purpose) VALUES (?, ?, ?, ?, ?)", [reservation.id, lease.id, String(time), lease.clientID, purpose.rawValue])
        try database.run("UPDATE budget_misses SET operations = operations + 1 WHERE miss_id = ?", [lease.id])
        return reservation
    }
    func dispatched(_ reservation: UnitReservation, purpose: ProviderPurpose? = nil) throws {
        try clockedTransaction { time in
            guard let row = try database.rows("SELECT state FROM budget_reservations WHERE reservation_id = ? AND miss_id = ? AND client_id = ?", [reservation.id, reservation.missID, reservation.clientID]).first,
                  row["state"] == "reserved" else { throw ProviderBudgetError.invalidRequest }
            if let purpose { try database.run("UPDATE budget_reservations SET purpose = ? WHERE reservation_id = ?", [purpose.rawValue, reservation.id]) }
            try database.run("UPDATE budget_reservations SET dispatched = 1, state = 'dispatched', created_at = ? WHERE reservation_id = ?", [String(time), reservation.id])
        }
    }

    func complete(_ reservation: UnitReservation, receivedSuccess: Bool) throws {
        try clockedTransaction { time in
            // Completion is idempotent. Failed, rejected, cached, cancelled and
            // ambiguous results never release the original capacity hold.
            try database.run("UPDATE budget_reservations SET state = ?, created_at = ? WHERE reservation_id = ? AND miss_id = ? AND client_id = ? AND state IN ('reserved', 'dispatched')", [receivedSuccess ? "completed" : "uncertain", String(time), reservation.id, reservation.missID, reservation.clientID])
        }
    }

    func endMiss(_ lease: MissLease) throws {
        try database.transaction {
            guard try count("budget_reservations", "miss_id = ? AND state IN ('reserved', 'dispatched')", [lease.id]) == 0 else { return }
            try database.run("UPDATE budget_misses SET active = 0 WHERE miss_id = ? AND client_id = ?", [lease.id, lease.clientID])
        }
    }

    public func usage(for principal: ClientPrincipal) throws -> ProviderUsageSnapshot {
        let client = try clientID(principal)
        return try clockedTransaction { time in
            let bounds = try calendarBounds(time)
            var windows: [ProviderUsageWindow] = []
            for (scope, seconds, limit) in [("provider_rolling_hour", 3_600.0, policy.providerHourly), ("provider_rolling_day", 86_400.0, policy.providerDaily), ("provider_rolling_31_days", 31 * 86_400.0, policy.providerMonthly)] {
                windows.append(try usageWindow(scope, cap: limit, condition: "(created_at > ? OR state IN ('reserved', 'dispatched'))", values: [String(time - seconds)]))
            }
            windows.append(try usageWindow("client_utc_day", cap: policy.clientDaily, condition: "client_id = ? AND ((created_at >= ? AND created_at < ?) OR state IN ('reserved', 'dispatched'))", values: [client, String(bounds.day), String(bounds.dayEnd)]))
            windows.append(try usageWindow("client_utc_month", cap: policy.clientMonthly, condition: "client_id = ? AND ((created_at >= ? AND created_at < ?) OR state IN ('reserved', 'dispatched'))", values: [client, String(bounds.month), String(bounds.monthEnd)]))
            return ProviderUsageSnapshot(enabled: enabled, windows: windows)
        }
    }

    /// Explicit operator maintenance never resets quotas or drops unresolved work.
    public func purgeRetainedData() throws {
        guard let ownership else { throw ProviderBudgetError.storageUnavailable }
        try ownership.validate()
        try clockedTransaction { time in try prune(time) }
        try database.checkpoint()
        try ownership.validate()
    }
    private func usageWindow(_ scope: String, cap: Int, condition: String, values: [String]) throws -> ProviderUsageWindow {
        let row = try database.rows("SELECT COUNT(*) AS reserved, COALESCE(SUM(dispatched), 0) AS attempted, COALESCE(SUM(state = 'completed'), 0) AS consumed, COALESCE(SUM(state IN ('reserved', 'dispatched')), 0) AS pending FROM budget_reservations WHERE " + condition, values).first ?? [:]
        guard let reserved = Int(row["reserved"] ?? ""), let attempted = Int(row["attempted"] ?? ""), let consumed = Int(row["consumed"] ?? ""), let pending = Int(row["pending"] ?? "") else { throw ProviderBudgetError.storageUnavailable }
        return ProviderUsageWindow(scope: scope, cap: cap, reserved: reserved, attempted: attempted, consumedUpperBound: consumed, pending: pending)
    }
    private func count(_ table: String, _ condition: String, _ values: [String] = []) throws -> Int {
        try database.scalar("SELECT COUNT(*) FROM " + table + " WHERE " + condition, values)
    }
    private func prune(_ time: TimeInterval) throws {
        // Pending work is never expired by retention. Only exclusive-owner
        // recovery may retire it, starting a fresh conservative charge window.
        try database.run("DELETE FROM budget_reservations WHERE rowid IN (SELECT rowid FROM budget_reservations WHERE created_at < ? AND state NOT IN ('reserved', 'dispatched') LIMIT 5000)", [String(time - retention)])
        try database.run("DELETE FROM budget_misses WHERE rowid IN (SELECT rowid FROM budget_misses WHERE created_at < ? AND active = 0 AND NOT EXISTS (SELECT 1 FROM budget_reservations WHERE miss_id = budget_misses.miss_id) LIMIT 5000)", [String(time - retention)])
    }
    private func clientID(_ principal: ClientPrincipal) throws -> String {
        let value = principal.clientID
        guard value.count == 40, value.hasPrefix("client1_"), value.dropFirst(8).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ProviderBudgetError.invalidRequest }
        return value
    }
    private func clockedTransaction<T>(_ body: (Double) throws -> T) throws -> T {
        try ownership?.validate()
        return try database.transaction {
            // Sample after the write lock. A request queued earlier cannot
            // spuriously move the durable clock backwards after a later one.
            let sampled = try timestamp()
            let previous = try database.rows("SELECT last_seen FROM budget_clock WHERE id = 1").first?["last_seen"].flatMap(Double.init) ?? 0
            let time = max(sampled, previous)
            try database.run("INSERT INTO budget_clock (id, last_seen) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen", [String(time)])
            return try body(time)
        }
    }
    private func timestamp() throws -> Double {
        let time = now().timeIntervalSince1970
        guard time.isFinite, (0..<253_402_300_800).contains(time) else { throw ProviderBudgetError.storageUnavailable }
        return time
    }
    private func calendarBounds(_ time: Double) throws -> (day: Double, dayEnd: Double, month: Double, monthEnd: Double) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: time)
        guard let day = calendar.dateInterval(of: .day, for: date), let month = calendar.dateInterval(of: .month, for: date) else { throw ProviderBudgetError.storageUnavailable }
        return (day.start.timeIntervalSince1970, day.end.timeIntervalSince1970, month.start.timeIntervalSince1970, month.end.timeIntervalSince1970)
    }
}
