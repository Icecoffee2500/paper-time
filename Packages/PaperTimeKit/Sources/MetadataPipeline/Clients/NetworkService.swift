import Foundation

/// Shared HTTP access for the bibliographic APIs.
///
/// All four services Paper Time queries are free and unauthenticated, and all
/// four ask for the same courtesies: identify yourself, stay under one request
/// per second, and back off when told to. Routing every call through one actor
/// is the only way to keep that promise when several papers resolve at once.
public actor NetworkService {
    public enum Failure: LocalizedError, Sendable {
        case offline
        case notFound
        case rateLimited(retryAfter: TimeInterval?)
        case badStatus(Int)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .offline: "No internet connection."
            case .notFound: "The record was not found."
            case .rateLimited: "The service asked us to slow down."
            case let .badStatus(code): "The service returned status \(code)."
            case .malformedResponse: "The service returned something unreadable."
            }
        }

        /// Whether the caller should keep the paper queued and try again later.
        public var isTransient: Bool {
            switch self {
            case .offline, .rateLimited, .badStatus: true
            case .notFound, .malformedResponse: false
            }
        }
    }

    private let session: URLSession
    private let userAgent: String
    private var nextAllowedRequest: [String: Date] = [:]

    /// Each service publishes its own ceiling, and arXiv's is far stricter than
    /// the rest: querying it once a second earns an immediate "Rate exceeded"
    /// and every preprint in the library silently falls back to a title search.
    private func minimumInterval(forHost host: String) -> TimeInterval {
        if host.contains("arxiv.org") { return 3.0 }
        if host.contains("api.crossref.org") { return 1.0 }
        if host.contains("api.openalex.org") { return 0.2 }
        if host.contains("semanticscholar.org") { return 1.0 }
        return 0.5
    }

    public init(session: URLSession = .shared, contactEmail: String? = nil) {
        self.session = session
        let contact = contactEmail.map { " (mailto:\($0))" } ?? ""
        // Crossref routes requests that identify a contact into a faster pool.
        self.userAgent = "PaperTime/1.0\(contact)"
    }

    public func get(_ url: URL, accept: String? = nil) async throws -> Data {
        try await waitForTurn(host: url.host() ?? "")

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.timeoutInterval = 20

        return try await perform(request, url: url, allowRetry: true)
    }

    private func perform(
        _ request: URLRequest,
        url: URL,
        allowRetry: Bool
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw Failure.offline
            default:
                throw error
            }
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        switch http.statusCode {
        case 200...299:
            return data
        case 404, 410:
            throw Failure.notFound
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let pause = min(retryAfter ?? 5, 20)
            // Honour the server's own pacing rather than guessing, and give the
            // request one more chance before reporting failure upwards.
            backOff(host: url.host() ?? "", seconds: pause)
            guard allowRetry else { throw Failure.rateLimited(retryAfter: retryAfter) }
            try await Task.sleep(for: .seconds(pause))
            return try await perform(request, url: url, allowRetry: false)
        default:
            throw Failure.badStatus(http.statusCode)
        }
    }

    public func getJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        accept: String = "application/json",
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let data = try await get(url, accept: accept)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw Failure.malformedResponse
        }
    }

    private func waitForTurn(host: String) async throws {
        let now = Date.now
        if let next = nextAllowedRequest[host], next > now {
            try await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
        }
        nextAllowedRequest[host] = .now.addingTimeInterval(minimumInterval(forHost: host))
    }

    private func backOff(host: String, seconds: TimeInterval) {
        nextAllowedRequest[host] = .now.addingTimeInterval(seconds)
    }
}
