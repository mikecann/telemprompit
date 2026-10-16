import Foundation

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

struct NotionProject: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String?
}

protocol NotionScriptSource {
    func recentProjects() async throws -> [NotionProject]
    func pageMarkdown(pageID: String) async throws -> String
}

enum NotionClientError: LocalizedError {
    case unexpectedResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "Notion sent back something unexpected."
        case let .requestFailed(status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Notion request failed (HTTP \(status))."
                : "Notion said: \(detail) (HTTP \(status))"
        }
    }
}

/// Reads video projects and their pages from Notion, the same way Video HQ
/// does.
struct NotionClient: NotionScriptSource {
    static let endpoint = URL(string: "https://api.notion.com/v1")!
    static let apiVersion = "2026-03-11"
    /// Mike's Projects database. Change this to use your own.
    static let projectsDataSourceID = "1a8fd70e-cfa0-8076-8e19-000bbdf1cc35"
    static let recentProjectLimit = 25
    /// Statuses for projects that are finished with, so they stay out of the list.
    static let skippedStatuses = ["Done", "Cancelled"]

    let apiKey: String
    var transport: any HTTPTransport = URLSessionHTTPTransport()

    func recentProjects() async throws -> [NotionProject] {
        let body: [String: Any] = [
            "filter": [
                "and": Self.skippedStatuses.map { status in
                    ["property": "Status", "status": ["does_not_equal": status]]
                },
            ],
            "sorts": [["timestamp": "last_edited_time", "direction": "descending"]],
            "page_size": Self.recentProjectLimit,
        ]
        let url = Self.endpoint
            .appendingPathComponent("data_sources")
            .appendingPathComponent(Self.projectsDataSourceID)
            .appendingPathComponent("query")
        var request = request(url: url, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try JSONDecoder().decode(QueryResponse.self, from: try await send(request))
        return response.results.map { page in
            let title = page.properties.values
                .first { $0.type == "title" }?
                .title?
                .map(\.plainText)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return NotionProject(
                id: page.id,
                name: title.isEmpty ? "Untitled" : title,
                status: page.properties["Status"]?.status?.name
            )
        }
    }

    func pageMarkdown(pageID: String) async throws -> String {
        let url = Self.endpoint
            .appendingPathComponent("pages")
            .appendingPathComponent(pageID)
            .appendingPathComponent("markdown")
        let data = try await send(request(url: url, method: "GET"))
        return try JSONDecoder().decode(PageMarkdown.self, from: data).markdown
    }

    private func request(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionClientError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data).message)
                ?? String(decoding: data, as: UTF8.self)
            throw NotionClientError.requestFailed(status: http.statusCode, message: message)
        }
        return data
    }
}

private extension NotionClient {
    struct APIError: Decodable {
        let message: String
    }

    struct PageMarkdown: Decodable {
        let markdown: String
    }

    struct QueryResponse: Decodable {
        let results: [Page]
    }

    struct Page: Decodable {
        let id: String
        let properties: [String: Property]
    }

    struct Property: Decodable {
        let type: String
        let title: [RichText]?
        let status: Status?
    }

    struct Status: Decodable {
        let name: String
    }

    struct RichText: Decodable {
        let plainText: String

        enum CodingKeys: String, CodingKey {
            case plainText = "plain_text"
        }
    }
}

/// Finds the Notion API key without it ever being part of the app or repo.
enum NotionCredentials {
    static let keyNames = ["NOTION_API_KEY", "NOTION_TOKEN"]
    /// `build-app.sh` records this clone's `.env` under this key, so the
    /// installed app finds it when it's opened from Spotlight.
    static let dotenvInfoKey = "TelemprompitDotenvPath"

    static func apiKey(environment: [String: String], dotenvURL: URL?) -> String? {
        for name in keyNames {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        guard let dotenvURL,
              let contents = try? String(contentsOf: dotenvURL, encoding: .utf8)
        else { return nil }
        let values = dotenvValues(contents)
        return keyNames.lazy.compactMap { values[$0] }.first { !$0.isEmpty }
    }

    static func dotenvURL(bundle: Bundle = .main) -> URL? {
        guard let path = bundle.object(forInfoDictionaryKey: dotenvInfoKey) as? String,
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func dotenvValues(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}
