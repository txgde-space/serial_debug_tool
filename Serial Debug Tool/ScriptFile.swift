import Foundation

enum ScriptFileError: LocalizedError {
    case invalidEncoding
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: AppText.scriptImportEncoding
        case .tooLarge: AppText.scriptOutputTooLarge
        }
    }
}

/// A plain UTF-8 JavaScript file. Importing reads source only; it never executes a script.
struct ScriptFile {
    let name: String
    let source: String

    static func read(from url: URL, sourceLimit: Int) throws -> ScriptFile {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Read one byte beyond the limit, allowing for a UTF-8 BOM, to reject large files
        // without loading arbitrary-sized data into the editor.
        var data = Data()
        let maximumRead = sourceLimit + 4
        while data.count < maximumRead {
            let chunk = try handle.read(upToCount: min(8192, maximumRead - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return ScriptFile(
            name: url.deletingPathExtension().lastPathComponent,
            source: try decode(data, sourceLimit: sourceLimit)
        )
    }

    static func decode(_ data: Data, sourceLimit: Int) throws -> String {
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        guard bytes.count <= sourceLimit else { throw ScriptFileError.tooLarge }
        guard let source = String(data: bytes, encoding: .utf8) else { throw ScriptFileError.invalidEncoding }
        return source
    }

    static func exportFilename(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.components(separatedBy: CharacterSet(charactersIn: "/:\r\n")).joined(separator: "-")
        let base = sanitized.isEmpty ? AppText.scriptCustom : sanitized
        return base.lowercased().hasSuffix(".js") ? base : base + ".js"
    }
}
