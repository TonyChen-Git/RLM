import Darwin
import Foundation

/// Writes beside the destination and atomically renames into place. Foundation's
/// `.atomic` option may use a volume-level replacement directory; keeping the
/// temporary file beside its destination avoids hidden cache files elsewhere.
/// The file and containing directory are synchronized before success is
/// reported so transaction journals and session snapshots survive a sudden
/// process or host shutdown after the call returns.
enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let destination = destination.standardizedFileURL
        let directory = destination.deletingLastPathComponent()
        let destinationName = destination.lastPathComponent
        guard destination.isFileURL,
              destination.path.hasPrefix("/"),
              destination.path != "/",
              !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !destinationName.contains("/") else {
            throw POSIXError(.EINVAL)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(directoryDescriptor) }

        let temporaryName = ".temporary-\(UUID().uuidString.lowercased())"
        let temporaryDescriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryDescriptor >= 0 else { throw currentPOSIXError() }
        var temporaryIsOpen = true
        var temporaryExists = true

        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        temporaryDescriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw currentPOSIXError() }
                    offset += written
                }
            }
            guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0,
                  Darwin.fsync(temporaryDescriptor) == 0 else {
                throw currentPOSIXError()
            }
            guard Darwin.close(temporaryDescriptor) == 0 else {
                temporaryIsOpen = false
                throw currentPOSIXError()
            }
            temporaryIsOpen = false
            guard Darwin.renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                destinationName
            ) == 0 else {
                throw currentPOSIXError()
            }
            temporaryExists = false
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw currentPOSIXError()
            }
        } catch {
            if temporaryIsOpen { _ = Darwin.close(temporaryDescriptor) }
            if temporaryExists {
                _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
            }
            throw error
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
