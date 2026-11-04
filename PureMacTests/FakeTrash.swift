import Foundation
@testable import PureMac

/// A stand-in for the Trash so tests never move fixtures into the real
/// `~/.Trash`. Items are moved into `<directory>/.FakeTrash`, which lives inside
/// the temp fixture the test already removes.
enum FakeTrash {
    static func folder(in directory: URL) -> URL {
        directory.appendingPathComponent(".FakeTrash", isDirectory: true)
    }

    static func operation(in directory: URL) -> CleaningEngine.TrashOperation {
        let folder = folder(in: directory)
        return { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }
}
