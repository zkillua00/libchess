import Foundation

struct BoardCustomizationFileStore: Sendable {
    private let fileURL: URL

    init() throws {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        fileURL = root
            .appendingPathComponent("LibChess", isDirectory: true)
            .appendingPathComponent("board-customization.json", isDirectory: false)
    }

    func load() throws -> Data? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    func save(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

}
