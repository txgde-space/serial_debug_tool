import SwiftUI
import UniformTypeIdentifiers

struct ScriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.javaScript, .plainText] }
    static var writableContentTypes: [UTType] { [.javaScript] }
    var source: String

    init(source: String) { self.source = source }

    init(configuration: ReadConfiguration) throws {
        source = try ScriptFile.decode(configuration.file.regularFileContents ?? Data(), sourceLimit: 65_536)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(source.utf8))
    }
}
