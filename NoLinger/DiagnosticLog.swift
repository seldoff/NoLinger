import Foundation

/// A collection session owns a temporary file that is discarded when collection ends.
@MainActor
final class DiagnosticLog {
    enum CollectionError: LocalizedError {
        case sizeLimitReached

        var errorDescription: String? {
            "The log reached its 10 MB limit. Start a new collection to continue."
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NoLinger", isDirectory: true)
    }

    private let directory: URL
    private let maximumBytes: Int
    private var handle: FileHandle?
    private var fileURL: URL?
    private var bytesWritten = 0
    private let timestamp = ISO8601DateFormatter()

    init(directory: URL = DiagnosticLog.defaultDirectory, maximumBytes: Int = 10 * 1024 * 1024) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start() throws -> URL {
        try discard()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = timestamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("NoLinger-\(date)-\(UUID().uuidString).log")
        try Data().write(to: url, options: .withoutOverwriting)
        fileURL = url
        handle = try FileHandle(forWritingTo: url)
        bytesWritten = 0
        return url
    }

    func append(_ message: String, category: String) throws {
        guard let handle else { return }
        // App names and error messages must not introduce extra log records.
        let line = message.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let data = Data("\(timestamp.string(from: Date())) [\(category)] \(line)\n".utf8)
        guard data.count <= maximumBytes - bytesWritten else { throw CollectionError.sizeLimitReached }
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }

    func flush() throws {
        try handle?.synchronize()
    }

    func stop() throws {
        guard let current = handle else { return }
        handle = nil
        defer { try? current.close() }
        try current.synchronize()
    }

    func discard() throws {
        let current = handle
        handle = nil
        defer { try? current?.close() }
        guard let fileURL else { return }
        do { try FileManager.default.removeItem(at: fileURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        self.fileURL = nil
    }
}
