import Foundation
import Darwin

struct ActivityLog {
    let url: URL
    var maximumBytes = 1_048_576

    func append(_ line: String) throws {
        guard maximumBytes >= 128 else { throw CocoaError(.fileWriteInvalidFileName) }
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        // Bound both a single entry and the amount read from an old large log.
        let entryLimit = maximumBytes / 2
        var entry = Data((String(line.prefix(2048)) + "\n").utf8)
        if entry.count > entryLimit {
            var shortened = String(data: entry.prefix(entryLimit-1), encoding: .utf8)
            var length = entryLimit-1
            while shortened == nil && length > 0 {
                length -= 1; shortened = String(data: entry.prefix(length), encoding: .utf8)
            }
            entry = Data(((shortened ?? "") + "\n").utf8)
        }
        let size = try handle.seekToEnd()
        if size + UInt64(entry.count) > UInt64(maximumBytes) {
            try handle.seek(toOffset: size - min(size, UInt64(maximumBytes/2)))
            let tail = try handle.read(upToCount: maximumBytes/2) ?? Data()
            let retained = tail.firstIndex(of: 10).map { Data(tail.suffix(from: tail.index(after: $0))) } ?? Data()
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: retained)
        }
        try handle.write(contentsOf: entry)
    }
}
