import Darwin
import Foundation

/// Prevents duplicate Wordhand processes from competing for the microphone,
/// global shortcut, clipboard, and insertion target.
final class SingleInstanceLock {
    private let descriptor: Int32

    init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(fileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SingleInstanceError.lockUnavailable(
                String(cString: strerror(errno))
            )
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            close(descriptor)
            throw SingleInstanceError.lockUnavailable(
                String(cString: strerror(code))
            )
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw SingleInstanceError.alreadyRunning
            }
            throw SingleInstanceError.lockUnavailable(
                String(cString: strerror(code))
            )
        }

        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

enum SingleInstanceError: LocalizedError {
    case alreadyRunning
    case lockUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Wordhand is already running. Open it from the Dock or menu bar."
        case .lockUnavailable(let reason):
            return "Wordhand couldn’t create its single-instance lock: \(reason)"
        }
    }
}
