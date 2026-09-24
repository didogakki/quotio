import Foundation
import QuotioDomain

/// Reads one whitelisted quota resource through the local quota-cache service
/// (`scripts/quota-cache`) instead of calling a remote CLIProxyAPI's `/api-call`
/// pass-through directly. Injectable via `QuotaHTTPSession` so tests never make a
/// real network request. The service is local-only, read-only, and reuses the same
/// management key already stored for the source — enabling it adds no new secret
/// surface. The client sends only `auth_index` on the query string and the existing
/// management key as a bearer token; it never sends a URL, header, or token for the
/// service to forward, matching the service's own contract that it alone decides
/// which upstream URL/headers a resource maps to.
public struct QuotaCacheClient: Sendable {
    /// The closed resource whitelist mirrored from `scripts/quota-cache/resources.py`'s
    /// `RESOURCES` table. Every call site already passes one of these fixed literals —
    /// this is defense in depth, not a real gate, since nothing derives `resource` from
    /// user input — but it keeps this client refusing to construct a request for
    /// anything the service itself wouldn't recognize either.
    private static let allowedResources: Set<String> = [
        "codex-usage", "codex-reset-credits", "claude-usage", "claude-profile", "grok-usage", "grok-settings",
    ]

    private let session: any QuotaHTTPSession

    public init(session: any QuotaHTTPSession = QuotaCacheClient.makeSession()) {
        self.session = session
    }

    /// A dedicated session, never `URLSession.shared`: this client sends the pool's
    /// management key as a bearer token, so it must never follow a redirect a
    /// compromised/misconfigured cache endpoint could issue to resend that key to an
    /// unrelated host. `AmpNoRedirectDelegate` already exists for exactly this
    /// purpose and denies every redirect unconditionally.
    public nonisolated static func makeSession() -> any QuotaHTTPSession {
        URLSession(
            configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 10),
            delegate: AmpNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    public func fetch(
        baseURL: String,
        resource: String,
        authIndex: String,
        managementKey: String
    ) async throws -> QuotaCacheResponse {
        guard Self.allowedResources.contains(resource) else {
            throw QuotaCacheError.invalidBaseURL
        }
        guard var components = URLComponents(string: baseURL),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil, components.fragment == nil
        else {
            throw QuotaCacheError.invalidBaseURL
        }
        // `http` is only ever trusted for the documented same-host deployment
        // (`http://127.0.0.1:...`, see scripts/quota-cache/README.md) — anything
        // else must be `https`, so the management key sent as this request's
        // bearer token is never carried in cleartext to a non-loopback host.
        // `RemoteManagementQuotaFetcher` layers a same-origin check for the
        // `https` case on top of this before it ever calls `fetch`.
        guard scheme == "https" || Self.isLoopbackHost(host) else {
            throw QuotaCacheError.invalidBaseURL
        }
        components.path = components.path.hasSuffix("/") ? components.path + resource : components.path + "/" + resource
        components.queryItems = [URLQueryItem(name: "auth_index", value: authIndex)]
        guard let url = components.url else {
            throw QuotaCacheError.invalidBaseURL
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaCacheError.connectionError
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaCacheError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if let envelope = try? JSONDecoder().decode(QuotaCacheErrorResponse.self, from: data),
               let statusCode = envelope.failure?.authInvalidStatusCode {
                throw QuotaCacheError.authInvalid(statusCode)
            }
            throw QuotaCacheError.httpError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(QuotaCacheResponse.self, from: data)
        } catch {
            throw QuotaCacheError.invalidResponse
        }
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "127.0.0.1" || normalized == "::1" || normalized == "localhost"
    }
}

/// One quota-cache service response envelope. `result` mirrors `ProxyAPICallResult`
/// exactly — the same upstream pass-through shape the direct `apiCall` path already
/// returns — so every existing response-mapping function consumes it unchanged.
/// `fetchedAt` is the real wall-clock time the cached value was last actually
/// obtained from upstream, never the moment this response was read from the cache,
/// so a `Retry-After` header on a stale `result` is still interpreted relative to
/// when it was really received, and `ProviderQuota.lastUpdated` never claims a
/// fresher reading than the cache actually holds.
public struct QuotaCacheResponse: Decodable, Sendable {
    public let result: ProxyAPICallResult
    public let fetchedAt: Double
    public let stale: Bool
    public let lastAttempt: Double
    public let nextRetryAt: Double?
    public let failure: QuotaCacheFailure?
    /// Optional CPA pool routing-weight reading, carried alongside this same
    /// `codex-usage` envelope rather than a separate request — absent entirely (never
    /// decoded as a synthetic zero) on a cache build that doesn't compute weights, or
    /// when this account/pool has none.
    public let routingWeights: QuotaCacheRoutingWeights?

    enum CodingKeys: String, CodingKey {
        case result, stale, failure
        case fetchedAt = "fetched_at"
        case lastAttempt = "last_attempt"
        case nextRetryAt = "next_retry_at"
        case routingWeights = "routing_weights"
    }

    /// Decodes `routingWeights` tolerantly: a malformed `routing_weights` payload
    /// (wrong types, or values `QuotaCacheRoutingWeights` itself rejects) never fails
    /// this whole response's decode — it only means this optional reading comes back
    /// `nil`, exactly like a cache build that omits it entirely. Every other field is
    /// the real quota data and must still fail loudly if it doesn't decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(ProxyAPICallResult.self, forKey: .result)
        fetchedAt = try container.decode(Double.self, forKey: .fetchedAt)
        stale = try container.decode(Bool.self, forKey: .stale)
        lastAttempt = try container.decode(Double.self, forKey: .lastAttempt)
        nextRetryAt = try container.decodeIfPresent(Double.self, forKey: .nextRetryAt)
        failure = try container.decodeIfPresent(QuotaCacheFailure.self, forKey: .failure)
        routingWeights = (try? container.decodeIfPresent(QuotaCacheRoutingWeights.self, forKey: .routingWeights)) ?? nil
    }
}

/// Raw wire shape of `QuotaCacheResponse.routingWeights` — `updatedAt` is Unix
/// seconds, matching `fetched_at`/`last_attempt` on the same envelope. Mapped to the
/// Domain `AccountRoutingWeight` by `RemoteManagementQuotaFetcher`, which is the
/// layer that owns converting this raw timestamp into a `Date`.
public struct QuotaCacheRoutingWeights: Decodable, Sendable {
    public let account: Int
    public let channel: Int
    public let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case account, channel
        case updatedAt = "updated_at"
    }

    /// Rejects a reading the cache should never actually send: a negative weight, or a
    /// non-finite/non-positive `updated_at`. Throwing here (rather than clamping) is
    /// what lets `QuotaCacheResponse`'s tolerant decode turn this into `nil` instead of
    /// silently keeping a nonsensical weight/timestamp.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let account = try container.decode(Int.self, forKey: .account)
        let channel = try container.decode(Int.self, forKey: .channel)
        let updatedAt = try container.decode(Double.self, forKey: .updatedAt)
        guard account >= 0, channel >= 0, updatedAt.isFinite, updatedAt > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .updatedAt, in: container, debugDescription: "Invalid routing weights reading"
            )
        }
        self.account = account
        self.channel = channel
        self.updatedAt = updatedAt
    }
}

public struct QuotaCacheFailure: Decodable, Equatable, Sendable {
    public let kind: String
    public let statusCode: Int?

    enum CodingKeys: String, CodingKey {
        case kind
        case statusCode = "status_code"
    }

    var authInvalidStatusCode: Int? {
        guard kind == "auth_invalid", let statusCode, statusCode == 401 || statusCode == 403 else { return nil }
        return statusCode
    }

    var remoteAccountIssue: RemoteQuotaAccountIssue? {
        authInvalidStatusCode == nil ? nil : .invalidOAuth
    }
}

private struct QuotaCacheErrorResponse: Decodable {
    let failure: QuotaCacheFailure?
}

public enum QuotaCacheError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidResponse
    case connectionError
    case httpError(Int)
    case authInvalid(Int)
}
