import Foundation
import XCTest
@testable import TelemprompitApp

private final class RecordingTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let responseBody: String
    let statusCode: Int

    init(responseBody: String, statusCode: Int = 200) {
        self.responseBody = responseBody
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(responseBody.utf8), response)
    }
}

final class NotionClientTests: XCTestCase {
    func testRecentProjectsAreNewestFirstAndSkipFinishedOnes() async throws {
        let transport = RecordingTransport(responseBody: #"""
        {
          "object": "list",
          "results": [{
            "object": "page",
            "id": "3fafd70e-cfa0-81fe-8c71-d539a0c7411a",
            "url": "https://www.notion.so/3fafd70ecfa081fe8c71d539a0c7411a",
            "last_edited_time": "2026-10-16T03:18:00.000Z",
            "properties": {
              "Name": {"id": "title", "type": "title", "title": [{"plain_text": "Convex 1.47 "}, {"plain_text": "release video"}]},
              "Status": {"id": "status", "type": "status", "status": {"name": "Writing"}}
            }
          }, {
            "object": "page",
            "id": "21ffd70e-cfa0-8067-8084-f5a01b98456f",
            "url": null,
            "last_edited_time": "2026-10-14T03:18:00.000Z",
            "properties": {
              "Name": {"id": "title", "type": "title", "title": []},
              "Status": {"id": "status", "type": "status", "status": null}
            }
          }],
          "next_cursor": null,
          "has_more": false
        }
        """#)
        let client = NotionClient(apiKey: "notion-test", transport: transport)

        let projects = try await client.recentProjects()

        XCTAssertEqual(projects, [
            NotionProject(id: "3fafd70e-cfa0-81fe-8c71-d539a0c7411a", name: "Convex 1.47 release video", status: "Writing"),
            NotionProject(id: "21ffd70e-cfa0-8067-8084-f5a01b98456f", name: "Untitled", status: nil),
        ])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.notion.com/v1/data_sources/\(NotionClient.projectsDataSourceID)/query"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer notion-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), NotionClient.apiVersion)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["page_size"] as? Int, NotionClient.recentProjectLimit)
        let sorts = try XCTUnwrap(json["sorts"] as? [[String: String]])
        XCTAssertEqual(sorts, [["timestamp": "last_edited_time", "direction": "descending"]])
        let filters = try XCTUnwrap((json["filter"] as? [String: Any])?["and"] as? [[String: Any]])
        let skipped = filters.compactMap { ($0["status"] as? [String: String])?["does_not_equal"] }
        XCTAssertEqual(skipped, ["Done", "Cancelled"])
    }

    func testPageMarkdownDownloadsThePage() async throws {
        let transport = RecordingTransport(responseBody: #"""
        {"object": "page_markdown", "id": "abc", "markdown": "# Script\n\tHello", "truncated": false, "unknown_block_ids": []}
        """#)
        let client = NotionClient(apiKey: "notion-test", transport: transport)

        let markdown = try await client.pageMarkdown(pageID: "3fafd70e-cfa0-81fe-8c71-d539a0c7411a")

        XCTAssertEqual(markdown, "# Script\n\tHello")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.notion.com/v1/pages/3fafd70e-cfa0-81fe-8c71-d539a0c7411a/markdown"
        )
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testErrorsShowNotionsOwnMessage() async {
        let transport = RecordingTransport(
            responseBody: #"{"object":"error","message":"Share the Projects database with your integration."}"#,
            statusCode: 404
        )
        let client = NotionClient(apiKey: "notion-test", transport: transport)

        do {
            _ = try await client.recentProjects()
            XCTFail("Expected the Notion request to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Notion said: Share the Projects database with your integration. (HTTP 404)"
            )
        }
    }
}

final class NotionScriptTests: XCTestCase {
    func testTakesTheScriptToggleFromAProjectPage() {
        let page = """
        # Notes {toggle="true"}
        \t## Pickup
        \t- Record on Friday
        # Script {toggle="true"}
        \tDraft 1.
        \t## Hook
        \t<callout icon="💡" color="gray_bg">
        \t\tme
        \t</callout>
        \tWe're back.
        \t\t- A nested bullet
        # Links {toggle="true"}
        \t- https://convex.dev
        """
        XCTAssertEqual(NotionScript.scriptSection(of: page), """
        Draft 1.
        ## Hook
        <callout icon="💡" color="gray_bg">
        \tme
        </callout>
        We're back.
        \t- A nested bullet
        """)
    }

    func testAPlainScriptHeadingRunsUntilTheNextHeadingAtTheSameLevel() {
        let page = """
        ## Notes
        Skip me
        ## Script v2
        Say this.
        ### Part two
        And this.
        ## Links
        Skip me too
        """
        XCTAssertEqual(NotionScript.scriptSection(of: page), "Say this.\n### Part two\nAnd this.")
    }

    func testFallsBackToTheWholePageWithoutAScriptSection() {
        let page = "# Scripting tips\nJust notes\n- one"
        XCTAssertEqual(NotionScript.scriptSection(of: page), page)
    }

    func testFallsBackToTheWholePageWhenTheScriptSectionIsEmpty() {
        let page = "# Script {toggle=\"true\"}\n# Links\n- a link"
        XCTAssertEqual(NotionScript.scriptSection(of: page), page)
    }
}

final class NotionCredentialsTests: XCTestCase {
    private func dotenv(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemprompit-\(UUID().uuidString).env")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheEnvironmentWinsOverTheDotenvFile() throws {
        let url = try dotenv("NOTION_API_KEY=from-file\n")
        XCTAssertEqual(
            NotionCredentials.apiKey(environment: ["NOTION_API_KEY": " from-env "], dotenvURL: url),
            "from-env"
        )
    }

    func testReadsQuotedKeysCommentsAndTheNotionTokenAlias() throws {
        let url = try dotenv("""
        # Notion
        NOTION_API_KEY=
        export NOTION_TOKEN="secret_abc"
        """)
        XCTAssertEqual(NotionCredentials.apiKey(environment: [:], dotenvURL: url), "secret_abc")
    }

    func testNoKeyWithoutAnEnvironmentVariableOrFile() {
        let missing = URL(fileURLWithPath: "/nonexistent/telemprompit/.env")
        XCTAssertNil(NotionCredentials.apiKey(environment: [:], dotenvURL: missing))
        XCTAssertNil(NotionCredentials.apiKey(environment: ["NOTION_API_KEY": ""], dotenvURL: nil))
    }
}

private final class FakeNotionSource: NotionScriptSource {
    var projects: Result<[NotionProject], Error>
    var pages: [String: String]

    init(projects: Result<[NotionProject], Error> = .success([]), pages: [String: String] = [:]) {
        self.projects = projects
        self.pages = pages
    }

    func recentProjects() async throws -> [NotionProject] {
        try projects.get()
    }

    func pageMarkdown(pageID: String) async throws -> String {
        guard let page = pages[pageID] else { throw URLError(.fileDoesNotExist) }
        return page
    }
}

/// A project list that never arrives unless the refresh is cancelled.
private struct SlowListSource: NotionScriptSource {
    func recentProjects() async throws -> [NotionProject] {
        try await Task.sleep(for: .seconds(60))
        return []
    }

    func pageMarkdown(pageID: String) async throws -> String {
        "- Hello"
    }
}

@MainActor
final class NotionPickerTests: XCTestCase {
    private let project = NotionProject(id: "p1", name: "Convex 1.47 release video", status: "Writing")

    private func makeModel() -> PrompterModel {
        PrompterModel(defaults: UserDefaults(suiteName: "telemprompit-notion-\(UUID().uuidString)")!)
    }

    func testRefreshListsRecentProjects() async {
        let picker = NotionPicker(source: FakeNotionSource(projects: .success([project])))
        await picker.refresh()
        XCTAssertEqual(picker.projects, [project])
        XCTAssertNil(picker.errorMessage)
        XCTAssertFalse(picker.isRefreshing)
        XCTAssertTrue(picker.canPick)
    }

    func testChoosingAProjectLoadsItsScriptIntoThePrompter() async {
        let page = "# Notes {toggle=\"true\"}\n\t- not this\n# Script {toggle=\"true\"}\n\t- Hello\n\t- World"
        let picker = NotionPicker(source: FakeNotionSource(pages: ["p1": page]))
        let model = makeModel()

        await picker.load(project, into: model)

        XCTAssertEqual(model.items, [.line("Hello"), .line("World")])
        XCTAssertEqual(model.current, 0)
        XCTAssertNil(picker.errorMessage)
        XCTAssertNil(picker.loadingProject)
    }

    func testAProjectCanBePickedWhileTheListRefreshes() async {
        let picker = NotionPicker(source: SlowListSource())
        let model = makeModel()
        let refresh = Task { await picker.refresh() }
        while !picker.isRefreshing { await Task.yield() }

        await picker.load(project, into: model)
        XCTAssertEqual(model.items, [.line("Hello")])

        refresh.cancel()
        await refresh.value
        XCTAssertFalse(picker.isRefreshing)
    }

    func testAnEmptyPageLeavesTheScriptAloneAndSaysSo() async {
        let picker = NotionPicker(source: FakeNotionSource(pages: ["p1": "  \n"]))
        let model = makeModel()

        await picker.load(project, into: model)

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(picker.errorMessage, "Convex 1.47 release video has nothing to read yet.")
    }

    func testFailuresAreShownAndClearedByTheNextAttempt() async {
        let source = FakeNotionSource(projects: .failure(URLError(.notConnectedToInternet)))
        let picker = NotionPicker(source: source)

        await picker.refresh()
        XCTAssertNotNil(picker.errorMessage)

        source.projects = .success([project])
        await picker.refresh()
        XCTAssertNil(picker.errorMessage)
        XCTAssertEqual(picker.projects, [project])
    }

    func testWithoutAKeyItExplainsHowToSetItUp() {
        let picker = NotionPicker(source: nil, setupHint: "Add NOTION_API_KEY to ~/telemprompit/.env")
        XCTAssertFalse(picker.isAvailable)
        XCTAssertEqual(picker.setupHint, "Add NOTION_API_KEY to ~/telemprompit/.env")
    }
}
