import SwiftUI
import UniformTypeIdentifiers

/// Text exports work with Files and other document providers.
struct TextTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json, .data] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

    static func readText(from url: URL, maximumBytes: Int = 8 * 1024 * 1024) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw ImportError.tooLarge }
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    private enum ImportError: LocalizedError {
        case tooLarge
        var errorDescription: String? { "This file is too large to import. Choose a text export smaller than 8 MB." }
    }
}
