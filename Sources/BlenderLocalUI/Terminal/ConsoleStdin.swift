import Darwin

/// Standard input for a console command.
///
/// A command that reads the keyboard — `top` waiting for q, `cat` reading lines
/// — reads file descriptor 0, as it does in BenchCode's terminal. Nothing in an
/// iOS app is connected there, so for each run fd 0 is pointed at a fresh pipe
/// the terminal writes keys into, and closing the terminal's end is end of
/// file. Afterwards fd 0 goes back to what it was, so nothing outside a run is
/// left reading a pipe nobody writes.
final class ConsoleStdin {
    private var writeEnd: Int32 = -1
    private var original: Int32 = -1

    var isOpen: Bool { writeEnd >= 0 }

    /// Points fd 0 at a new pipe. Call before the command starts reading.
    @discardableResult
    func open() -> Bool {
        finish()
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return false }
        // Never block the interface: a command that is not reading lets the
        // pipe fill, and a key typed then is dropped rather than freezing the
        // main thread in write(2).
        let flags = fcntl(fds[1], F_GETFL)
        _ = fcntl(fds[1], F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        if original < 0 { original = dup(STDIN_FILENO) }
        guard dup2(fds[0], STDIN_FILENO) >= 0 else {
            close(fds[0])
            close(fds[1])
            return false
        }
        close(fds[0])
        writeEnd = fds[1]
        return true
    }

    func write(_ bytes: [UInt8]) {
        guard writeEnd >= 0, !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { buffer in
            _ = Darwin.write(writeEnd, buffer.baseAddress, buffer.count)
        }
    }

    /// End of file for the command: a blocked read returns, `cat` stops.
    func closeInput() {
        guard writeEnd >= 0 else { return }
        close(writeEnd)
        writeEnd = -1
    }

    /// The run is over: end of file, and fd 0 back as it was.
    func finish() {
        closeInput()
        if original >= 0 {
            _ = dup2(original, STDIN_FILENO)
        }
    }

    deinit {
        finish()
        if original >= 0 { close(original) }
    }
}
