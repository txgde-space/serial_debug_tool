import Foundation

/// Read the matching release's notes from GitHub's public Atom feed.
enum ReleaseNotes {
    static func fromFeed(_ data: Data, releaseURL: URL) -> String? {
        guard data.count <= 1_000_000 else { return nil }
        let delegate = ReleaseNotesParser(releaseURL: releaseURL)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let html = delegate.content else { return nil }
        let text = plainText(fromHTML: html).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func plainText(fromHTML html: String) -> String {
        var text = html
            .replacingOccurrences(of: #"(?i)<li\b[^>]*>"#, with: "• ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|h[1-6]|ul|ol|pre)>|</li>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        // Decode after removing markup so escaped code such as &lt;value&gt; stays visible.
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            let original = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
                let number = original.substring(with: match.range(at: 1))
                let value = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let value, let scalar = Unicode.Scalar(value),
                   let range = Range(match.range, in: text) {
                    text.replaceSubrange(range, with: String(scalar))
                }
            }
        }
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
    }
}

private final class ReleaseNotesParser: NSObject, XMLParserDelegate {
    private let releaseURL: URL
    private var inEntry = false
    private var inContent = false
    private var entryURL: URL?
    private var entryContent = ""
    private(set) var content: String?

    init(releaseURL: URL) { self.releaseURL = releaseURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "entry":
            inEntry = true
            entryURL = nil
            entryContent = ""
        case "link" where inEntry:
            if attributeDict["rel"] == "alternate", let href = attributeDict["href"] {
                entryURL = URL(string: href)
            }
        case "content" where inEntry:
            inContent = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inContent { entryContent += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inContent, let text = String(data: CDATABlock, encoding: .utf8) { entryContent += text }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "content" { inContent = false }
        if elementName == "entry" {
            if entryURL == releaseURL, content == nil { content = entryContent }
            inEntry = false
            inContent = false
        }
    }
}
