import Foundation
import SwiftUI

/// Pulls the part of a Notion project page that's meant to be read out.
enum NotionScript {
    /// Mike's project pages keep the words under a "Script" heading, usually
    /// a toggle, alongside notes, titles and links. Returns that section, or
    /// the whole page when there isn't one or it's empty.
    static func scriptSection(of markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: isScriptHeading),
              let level = headingLevel(lines[start])
        else { return markdown }

        let headingIndent = indent(of: lines[start])
        // A toggle heading's children are indented beneath it. A plain
        // heading runs until the next heading at its level or above.
        let isToggle = lines[start].contains(#"toggle="true""#)
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if !isBlank(line) {
                let lineIndent = indent(of: line)
                if lineIndent < headingIndent { break }
                if isToggle, lineIndent == headingIndent { break }
                if !isToggle, lineIndent == headingIndent,
                   let next = headingLevel(line), next <= level { break }
            }
            body.append(line)
        }

        while let first = body.first, isBlank(first) { body.removeFirst() }
        while let last = body.last, isBlank(last) { body.removeLast() }
        guard !body.isEmpty else { return markdown }
        let common = body.filter { !isBlank($0) }.map(indent).min() ?? 0
        return body.map { isBlank($0) ? "" : String($0.dropFirst(common)) }.joined(separator: "\n")
    }

    private static func isScriptHeading(_ line: String) -> Bool {
        guard headingLevel(line) != nil else { return false }
        let title = line
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^#+\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\{[^{}]*\}\s*$"#, with: "", options: .regularExpression)
        return title.range(of: #"^script\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func headingLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marks = trimmed.range(of: #"^#{1,6}(?=\s)"#, options: .regularExpression) else {
            return nil
        }
        return trimmed.distance(from: marks.lowerBound, to: marks.upperBound)
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == "\t" || $0 == " " }.count
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The recent Notion projects offered when the prompter is empty, and
/// loading one of them as the script.
@MainActor
final class NotionPicker: ObservableObject {
    @Published private(set) var projects: [NotionProject] = []
    @Published private(set) var isRefreshing = false
    /// The name of the project whose script is downloading.
    @Published private(set) var loadingProject: String?
    @Published private(set) var errorMessage: String?
    /// Set when there's no Notion key, saying where to put one.
    let setupHint: String?
    private let source: (any NotionScriptSource)?

    init(source: (any NotionScriptSource)?, setupHint: String? = nil) {
        self.source = source
        self.setupHint = setupHint
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> NotionPicker {
        let dotenvURL = NotionCredentials.dotenvURL(bundle: bundle)
        if let apiKey = NotionCredentials.apiKey(environment: environment, dotenvURL: dotenvURL) {
            return NotionPicker(source: NotionClient(apiKey: apiKey))
        }
        let place = dotenvURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
            ?? "this clone's .env"
        return NotionPicker(source: nil, setupHint: "Add NOTION_API_KEY to \(place) to load scripts from Notion.")
    }

    var isAvailable: Bool { source != nil }

    /// A refresh keeps showing the previous list, so only the first load
    /// and script downloads hold up picking.
    var canPick: Bool { loadingProject == nil && !(isRefreshing && projects.isEmpty) }

    func refresh() async {
        guard let source, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            projects = try await source.recentProjects()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(_ project: NotionProject, into model: PrompterModel) async {
        guard let source, loadingProject == nil else { return }
        loadingProject = project.name
        errorMessage = nil
        defer { loadingProject = nil }
        do {
            let script = NotionScript.scriptSection(of: try await source.pageMarkdown(pageID: project.id))
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "\(project.name) has nothing to read yet."
                return
            }
            model.load(script)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A dropdown of recent Notion projects. Picking one replaces the script.
struct NotionScriptMenu: View {
    @ObservedObject var picker: NotionPicker
    let model: PrompterModel

    var body: some View {
        if let hint = picker.setupHint {
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(picker.projects) { project in
                            Button(Self.menuTitle(for: project)) {
                                Task { await picker.load(project, into: model) }
                            }
                        }
                        if picker.projects.isEmpty {
                            Text("No recent projects")
                        }
                        Divider()
                        Button("Refresh List") {
                            Task { await picker.refresh() }
                        }
                    } label: {
                        Label(title, systemImage: "doc.text")
                    }
                    .fixedSize()
                    .disabled(!picker.canPick)

                    if picker.isRefreshing || picker.loadingProject != nil {
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = picker.errorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // An unstructured task, so the list still finishes loading if
            // this view goes away first.
            .onAppear { Task { await picker.refresh() } }
        }
    }

    private var title: String {
        if let name = picker.loadingProject { return "Loading \(name)…" }
        if picker.isRefreshing, picker.projects.isEmpty { return "Loading Notion projects…" }
        return "Load a script from Notion"
    }

    static func menuTitle(for project: NotionProject) -> String {
        guard let status = project.status else { return project.name }
        return "\(project.name)  ·  \(status)"
    }
}
