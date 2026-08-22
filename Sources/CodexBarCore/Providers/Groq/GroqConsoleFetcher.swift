import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GroqConsoleError: LocalizedError, Sendable, Equatable {
    case missingSession
    case invalidSession(String)
    case accessDenied(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSession:
            "No Groq console session found. Sign in at console.groq.com in your browser."
        case let .invalidSession(message):
            "Groq console session is invalid: \(message)"
        case let .accessDenied(message):
            "Groq console access denied: \(message)"
        case let .apiError(message):
            "Groq console API error: \(message)"
        case let .parseFailed(message):
            "Groq console parse error: \(message)"
        }
    }
}

/// One row from `/platform/v1/organizations/{org}/activity`. Each row is a
/// per-model, per-day (daily `timestamp` bucket) usage/spend record.
private struct GroqActivityResponse: Decodable {
    struct Row: Decodable {
        let organizationName: String?
        let model: String?
        let timestamp: Double
        let numRequests: Int?
        let nContextTokensTotal: Int?
        let nNonCachedContextTokensTotal: Int?
        let nGeneratedTokensTotal: Int?
        let cost: Double?

        enum CodingKeys: String, CodingKey {
            case organizationName = "organization_name"
            case model
            case timestamp
            case numRequests = "num_requests"
            case nContextTokensTotal = "n_context_tokens_total"
            case nNonCachedContextTokensTotal = "n_non_cached_context_tokens_total"
            case nGeneratedTokensTotal = "n_generated_tokens_total"
            case cost
        }
    }

    let data: [Row]
}

public struct GroqConsoleFetcher: Sendable {
    public init() {}

    static func fetchUsage(
        session: GroqConsoleSession.SessionInfo,
        historyDays: Int = 30,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> GroqConsoleUsageSnapshot
    {
        let jwt = try await GroqConsoleSession.resolveJWT(
            for: session,
            environment: environment,
            transport: transport)
        return try await self.fetchUsage(
            sessionJWT: jwt,
            historyDays: historyDays,
            environment: environment,
            transport: transport,
            now: now)
    }

    public static func fetchUsage(
        sessionJWT: String,
        historyDays: Int = 30,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> GroqConsoleUsageSnapshot
    {
        let token = sessionJWT.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GroqConsoleError.missingSession }

        guard let orgID = Self.organizationID(fromJWT: token) else {
            throw GroqConsoleError.invalidSession("session token is missing the organization claim")
        }

        try GroqSettingsReader.validateEndpointOverrides(environment: environment)
        let days = max(1, min(365, historyDays))
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        // Include the full current day; the platform API bounds by unix seconds.
        let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) ?? startOfToday

        let rows = try await Self.fetchActivity(
            orgID: orgID,
            sessionJWT: token,
            window: DateInterval(start: start, end: end),
            environment: environment,
            transport: transport)

        return try Self.makeSnapshot(rows: rows, historyDays: days, updatedAt: now, calendar: calendar)
    }

    public static func _makeSnapshotForTesting(
        activityJSON: Data,
        historyDays: Int = 30,
        updatedAt: Date,
        calendar: Calendar = .current) throws -> GroqConsoleUsageSnapshot
    {
        let rows = try JSONDecoder().decode(GroqActivityResponse.self, from: activityJSON).data
        return try Self.makeSnapshot(rows: rows, historyDays: historyDays, updatedAt: updatedAt, calendar: calendar)
    }

    /// Extracts the Groq organization id from the session JWT's
    /// `https://groq.com/organization` claim (no signature verification — the
    /// API authenticates the token, this only reads the routing claim).
    public static func organizationID(fromJWT jwt: String) -> String? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let payload = Self.base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        if let org = object["https://groq.com/organization"] as? [String: Any],
           let id = org["id"] as? String, !id.isEmpty
        {
            return id
        }
        if let org = object["https://stytch.com/organization"] as? [String: Any],
           let slug = org["slug"] as? String, !slug.isEmpty
        {
            return slug
        }
        return nil
    }

    static func base64URLDecode(_ input: String) -> Data? {
        var value = input.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 {
            value.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: value)
    }

    private static func fetchActivity(
        orgID: String,
        sessionJWT: String,
        window: DateInterval,
        environment: [String: String],
        transport: any ProviderHTTPTransport) async throws -> [GroqActivityResponse.Row]
    {
        // The console platform API is rooted at the host, not under the
        // public `/v1` base that GroqSettingsReader.apiURL returns.
        let apiURL = GroqSettingsReader.apiURL(environment: environment)
        guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            throw GroqConsoleError.invalidSession("could not build activity URL")
        }
        components.path = "/platform/v1/organizations/\(orgID)/activity"
        components.queryItems = [
            URLQueryItem(name: "start_date", value: String(Int(window.start.timeIntervalSince1970))),
            URLQueryItem(name: "end_date", value: String(Int(window.end.timeIntervalSince1970))),
        ]
        guard let url = components.url else {
            throw GroqConsoleError.invalidSession("could not build activity URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(sessionJWT)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let summary = Self.responseSummary(response.data)
            if response.statusCode == 401 || response.statusCode == 403 {
                throw GroqConsoleError.accessDenied(summary)
            }
            throw GroqConsoleError.apiError("HTTP \(response.statusCode): \(summary)")
        }

        do {
            return try JSONDecoder().decode(GroqActivityResponse.self, from: response.data).data
        } catch {
            throw GroqConsoleError.parseFailed(error.localizedDescription)
        }
    }

    fileprivate static func makeSnapshot(
        rows: [GroqActivityResponse.Row],
        historyDays: Int,
        updatedAt: Date,
        calendar: Calendar) throws -> GroqConsoleUsageSnapshot
    {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        struct ModelAccumulator {
            var requests = 0
            var inputTokens = 0
            var cachedInputTokens = 0
            var outputTokens = 0
            var totalTokens = 0
            var costUSD = 0.0
        }
        struct DayAccumulator {
            var startTime: Date
            var models: [String: ModelAccumulator] = [:]
        }

        var byDay: [String: DayAccumulator] = [:]
        var organizationName: String?

        for (index, row) in rows.enumerated() {
            guard row.timestamp.isFinite else {
                throw GroqConsoleError.parseFailed("activity row \(index) has an invalid timestamp")
            }
            guard let requests = row.numRequests, requests >= 0,
                  let contextTokens = row.nContextTokensTotal, contextTokens >= 0,
                  let generatedTokens = row.nGeneratedTokensTotal, generatedTokens >= 0,
                  let costUSD = row.cost, costUSD.isFinite, costUSD >= 0
            else {
                throw GroqConsoleError.parseFailed("activity row \(index) has incomplete usage or spend")
            }
            let nonCachedTokens = row.nNonCachedContextTokensTotal ?? contextTokens
            guard nonCachedTokens >= 0, nonCachedTokens <= contextTokens else {
                throw GroqConsoleError.parseFailed("activity row \(index) has invalid cached-token usage")
            }
            if organizationName == nil, let name = row.organizationName, !name.isEmpty {
                organizationName = name
            }
            let date = Date(timeIntervalSince1970: row.timestamp)
            let dayStart = calendar.startOfDay(for: date)
            let key = dayFormatter.string(from: dayStart)
            let modelName = (row.model?.isEmpty == false ? row.model : nil) ?? "unknown"

            let cachedTokens = contextTokens - nonCachedTokens

            var day = byDay[key] ?? DayAccumulator(startTime: dayStart)
            var model = day.models[modelName] ?? ModelAccumulator()
            model.requests = try Self.checkedSum(model.requests, requests, row: index)
            model.inputTokens = try Self.checkedSum(model.inputTokens, nonCachedTokens, row: index)
            model.cachedInputTokens = try Self.checkedSum(model.cachedInputTokens, cachedTokens, row: index)
            model.outputTokens = try Self.checkedSum(model.outputTokens, generatedTokens, row: index)
            let rowTokens = try Self.checkedSum(contextTokens, generatedTokens, row: index)
            model.totalTokens = try Self.checkedSum(model.totalTokens, rowTokens, row: index)
            model.costUSD += costUSD
            guard model.costUSD.isFinite else {
                throw GroqConsoleError.parseFailed("activity row \(index) spend overflowed")
            }
            day.models[modelName] = model
            byDay[key] = day
        }

        let buckets = try byDay.map { key, day -> GroqConsoleUsageSnapshot.DailyBucket in
            let models = day.models.map { name, acc in
                GroqConsoleUsageSnapshot.ModelBreakdown(
                    name: name,
                    requests: acc.requests,
                    inputTokens: acc.inputTokens,
                    cachedInputTokens: acc.cachedInputTokens,
                    outputTokens: acc.outputTokens,
                    totalTokens: acc.totalTokens,
                    costUSD: acc.costUSD)
            }.sorted { $0.totalTokens > $1.totalTokens }
            var requests = 0
            var inputTokens = 0
            var cachedInputTokens = 0
            var outputTokens = 0
            var totalTokens = 0
            var costUSD = 0.0
            for model in models {
                requests = try Self.checkedSum(requests, model.requests, row: nil)
                inputTokens = try Self.checkedSum(inputTokens, model.inputTokens, row: nil)
                cachedInputTokens = try Self.checkedSum(cachedInputTokens, model.cachedInputTokens, row: nil)
                outputTokens = try Self.checkedSum(outputTokens, model.outputTokens, row: nil)
                totalTokens = try Self.checkedSum(totalTokens, model.totalTokens, row: nil)
                costUSD += model.costUSD
                guard costUSD.isFinite else {
                    throw GroqConsoleError.parseFailed("daily spend overflowed")
                }
            }
            let endTime = calendar.date(byAdding: .day, value: 1, to: day.startTime) ?? day.startTime
            return GroqConsoleUsageSnapshot.DailyBucket(
                day: key,
                startTime: day.startTime,
                endTime: endTime,
                costUSD: costUSD,
                requests: requests,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                totalTokens: totalTokens,
                models: models)
        }

        return GroqConsoleUsageSnapshot(
            daily: buckets,
            updatedAt: updatedAt,
            historyDays: historyDays,
            organizationName: organizationName)
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int, row: Int?) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            let scope = row.map { "activity row \($0)" } ?? "daily usage"
            throw GroqConsoleError.parseFailed("\(scope) overflowed")
        }
        return result.partialValue
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}
