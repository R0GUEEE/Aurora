import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Result of running a helper process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }

    /// Both streams concatenated, which is what an install log wants: dpkg
    /// interleaves progress on stdout and errors on stderr.
    public var combinedOutput: String {
        let out = stdoutString
        let err = stderrString
        if out.isEmpty { return err }
        if err.isEmpty { return out }
        return out + (out.hasSuffix("\n") ? "" : "\n") + err
    }
}

public enum ProcessError: Error, CustomStringConvertible {
    case notExecutable(String)
    case pipeFailed(Int32)
    case spawnFailed(String, Int32)
    case waitFailed(Int32)

    public var description: String {
        switch self {
        case .notExecutable(let path):
            return "\(path) is not an executable file"
        case .pipeFailed(let code):
            return "could not create a pipe for the helper process (errno \(code))"
        case .spawnFailed(let path, let code):
            return "could not start \(path) (errno \(code))"
        case .waitFailed(let code):
            return "could not collect the helper process (errno \(code))"
        }
    }
}

#if canImport(Darwin)
/// Darwin declares `posix_spawn_file_actions_t` as `void *`, so it imports into
/// Swift as a raw pointer and has to be nil-initialised rather than constructed.
/// glibc and musl use a real struct. This typealias is the only place in the
/// package that has to know the difference.
private typealias AuroraFileActions = posix_spawn_file_actions_t?
#else
private typealias AuroraFileActions = posix_spawn_file_actions_t
#endif

/// Runs helper binaries.
///
/// `Foundation.Process` does not exist on iOS, so this goes through
/// `posix_spawn` directly — which is also what lets Aurora run `dpkg` inside an
/// app on a jailbroken device. Output is drained with `poll(2)` on both pipes
/// instead of reading them sequentially, because a child that fills its stderr
/// buffer while we block on stdout would deadlock.
public enum ProcessRunner {

    /// True when the path exists and is executable.
    public static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return access(path, X_OK) == 0
    }

    /// A zeroed file-actions value for the platform's typedef.
    private static func defaultFileActions() -> AuroraFileActions {
        #if canImport(Darwin)
        return nil
        #else
        return posix_spawn_file_actions_t()
        #endif
    }

    /// First executable match in `searchPaths`, in order.
    public static func which(_ name: String, searchPaths: [String]) -> String? {
        if name.contains("/") {
            return isExecutable(name) ? name : nil
        }
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    public static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        standardInput: Data? = nil,
        onOutput: ((Data) -> Void)? = nil
    ) throws -> ProcessResult {
        guard isExecutable(executable) else { throw ProcessError.notExecutable(executable) }

        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        var stdinPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { throw ProcessError.pipeFailed(errno) }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw ProcessError.pipeFailed(errno)
        }
        if standardInput != nil, pipe(&stdinPipe) != 0 {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            throw ProcessError.pipeFailed(errno)
        }

        var actions = ProcessRunner.defaultFileActions()
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        if standardInput != nil {
            posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
        #if os(macOS)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory)
        }
        #else
        // `posix_spawn_file_actions_addchdir_np` is macOS-only: the iOS SDK marks
        // it unavailable, so this is the first thing that fails when the engine is
        // built for a device rather than for the test host. On iOS the child
        // inherits this process's working directory, which is enough — dpkg and
        // its maintainer scripts are given absolute paths.
        _ = currentDirectory
        #endif

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }

        var envp: [UnsafeMutablePointer<CChar>?] = []
        if let environment {
            envp = environment.map { strdup("\($0.key)=\($0.value)") }
            envp.append(nil)
        }
        defer { for pointer in envp where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let spawnResult: Int32
        if envp.isEmpty {
            // Inherit the app's environment, which is what dpkg wants: a package
            // manager's own environment already carries the jailbreak's PATH.
            spawnResult = posix_spawn(&pid, executable, &actions, nil, &argv, environ)
        } else {
            spawnResult = posix_spawn(&pid, executable, &actions, nil, &argv, &envp)
        }
        posix_spawn_file_actions_destroy(&actions)

        close(stdoutPipe[1])
        close(stderrPipe[1])
        if standardInput != nil { close(stdinPipe[0]) }

        guard spawnResult == 0 else {
            close(stdoutPipe[0]); close(stderrPipe[0])
            if standardInput != nil { close(stdinPipe[1]) }
            throw ProcessError.spawnFailed(executable, spawnResult)
        }

        if let standardInput {
            var offset = 0
            let bytes = [UInt8](standardInput)
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { buffer -> Int in
                    write(stdinPipe[1], buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                if written <= 0 { break }
                offset += written
            }
            close(stdinPipe[1])
        }

        var stdoutData = Data()
        var stderrData = Data()
        var openDescriptors: [Int32] = [stdoutPipe[0], stderrPipe[0]]

        while !openDescriptors.isEmpty {
            var descriptors = openDescriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), -1)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard ready > 0 else { break }

            for index in descriptors.indices.reversed() {
                let descriptor = descriptors[index].fd
                // POLLIN and friends are Int32 on Darwin and Int16 in revents, so
                // both sides are compared in Int32.
                let mask = Int32(POLLIN | POLLHUP | POLLERR)
                guard Int32(descriptors[index].revents) & mask != 0 else { continue }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    let chunk = Data(buffer[0..<count])
                    if descriptor == stdoutPipe[0] { stdoutData.append(chunk) } else { stderrData.append(chunk) }
                    onOutput?(chunk)
                } else {
                    close(descriptor)
                    openDescriptors.remove(at: index)
                }
            }
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { throw ProcessError.waitFailed(errno) }
        }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)

        return ProcessResult(status: exitCode, stdout: stdoutData, stderr: stderrData)
    }
}
