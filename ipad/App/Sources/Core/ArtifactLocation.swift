import Foundation

/// Only identifies a file already known to the paired library. Never a host path.
struct ArtifactLocation: Equatable, Sendable {
    let artifactID: String
    let page: Int?
    let line: Int?
    let endLine: Int?

    init?(url: URL) {
        guard url.scheme?.lowercased() == "hajisaki", url.host == "artifact",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        let identifier = String(path.dropFirst())
        guard path.first == "/", identifier.count == 32,
              identifier.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        let items = components.queryItems ?? []
        let allowed: Set<String> = ["page", "line", "end"]
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ allowed.contains($0.name) }) else { return nil }
        var values: [String: Int] = [:]
        for item in items {
            guard let text = item.value, let number = Int(text), number > 0, number <= Int(Int32.max) else { return nil }
            values[item.name] = number
        }
        guard values["page"] == nil || values["line"] == nil,
              values["end"] == nil || (values["line"] != nil && values["end"]! >= values["line"]!) else { return nil }
        artifactID = identifier; page = values["page"]; line = values["line"]; endLine = values["end"]
    }
}
