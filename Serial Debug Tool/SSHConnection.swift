import Foundation

enum SerialConnectionMode: String, CaseIterable, Sendable {
    case local, ssh
    var title: String { self == .local ? AppText.localSerial : AppText.sshSerial }
}

enum SSHAuthentication: String, CaseIterable, Codable, Sendable {
    case password, privateKey
    var title: String { self == .password ? AppText.sshPassword : AppText.sshPrivateKey }
}

struct SSHConfiguration: Sendable, Equatable {
    var host: String
    var port: Int = 22
    var username: String
    var authentication: SSHAuthentication = .password
    var identityURL: URL?
    var passwordAccount: String?

    func validate() throws {
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy(hostCharacters.contains),
              !username.isEmpty, username.count <= 128, !username.hasPrefix("-"),
              username.unicodeScalars.allSatisfy(userCharacters.contains),
              (1...65535).contains(port) else { throw SerialTransportError(message: AppText.sshInvalidConfiguration) }
        if authentication == .privateKey, identityURL == nil {
            throw SerialTransportError(message: AppText.sshChooseKey)
        }
    }

    var authority: String { "\(username)@\(host.contains(":") ? "[\(host)]" : host):\(port)" }

    func arguments(command: String, knownHostsURL: URL, interactive: Bool) throws -> [String] {
        try validate()
        let hostsPath = knownHostsURL.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "%", with: "%%")
        var args = ["-F", "/dev/null", "-T", "-p", String(port), "-l", username,
                    "-o", "ConnectTimeout=12", "-o", "ConnectionAttempts=1",
                    "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
                    "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none",
                    "-o", "GlobalKnownHostsFile=/dev/null",
                    "-o", "UserKnownHostsFile=\"\(hostsPath)\"",
                    "-o", "StrictHostKeyChecking=\(interactive ? "ask" : "yes")",
                    "-o", "BatchMode=\(interactive ? "no" : "yes")",
                    "-o", "NumberOfPasswordPrompts=1", "-o", "IdentityAgent=none"]
        if authentication == .privateKey, let identityURL {
            args += ["-o", "PreferredAuthentications=publickey", "-o", "IdentitiesOnly=yes", "-i", identityURL.path]
        } else {
            args += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive,password"]
        }
        return args + ["--", host, command]
    }
}

enum SSHFiles {
    static func directory() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SerialDebugTool/SSH", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func importIdentity(from url: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 131_072 else { throw SerialTransportError(message: AppText.sshInvalidKey) }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8), text.contains("PRIVATE KEY-----") else {
            throw SerialTransportError(message: AppText.sshInvalidKey)
        }
        let target = try directory().appendingPathComponent("identity-\(UUID().uuidString)")
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }
}


enum SSHSupportReport: Equatable, Sendable {
    case supported
    case missingTools([String])
    case unusableTools(String)
    case temporaryDirectoryUnavailable

    var isSupported: Bool { self == .supported }

    var detail: String? {
        switch self {
        case .supported: nil
        case .missingTools(let tools): AppText.sshMissingTools(tools.joined(separator: ", "))
        case .unusableTools(let tools): AppText.sshUnusableTools(tools)
        case .temporaryDirectoryUnavailable: AppText.sshTemporaryDirectoryUnavailable
        }
    }
}

enum SSHSupportStatus: Equatable, Sendable {
    case unchecked, checking
    case checked(SSHSupportReport)
    case failed(String)

    var title: String {
        switch self {
        case .unchecked: AppText.sshSupportUnchecked
        case .checking: AppText.sshSupportChecking
        case .checked(let report): report.isSupported ? AppText.sshSupported : AppText.sshUnsupported
        case .failed: AppText.sshSupportFailed
        }
    }

    var detail: String? {
        switch self {
        case .checked(let report): report.detail
        case .failed(let message): message
        default: nil
        }
    }
}

/// A temporary POSIX shell command; no interpreter package or remote installation.
enum SSHRemoteBridge {
    static let readyMarker = Data("SERIAL_DEBUG_READY\n".utf8)
    static let scanEnd = "SERIAL_DEBUG_END"
    static let supportPrefix = "SERIAL_DEBUG_SUPPORT\t"

    static func command(configuration: SerialConfiguration?) throws -> String {
        let arguments: [String]
        if let configuration {
            guard configuration.path.hasPrefix("/dev/"), configuration.path.utf8.count <= 4096,
                  !configuration.path.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }),
                  (1...4_000_000).contains(configuration.baudRate),
                  (5...8).contains(configuration.dataBits), (1...2).contains(configuration.stopBits) else {
                throw SerialTransportError(message: AppText.sshInvalidConfiguration)
            }
            var options = ["raw", "-echo", "-ixon", "-ixoff", "-ixany", "-istrip",
                           "-inlcr", "-igncr", "-icrnl", "-opost", "clocal", "cread",
                           "min", "1", "time", "0", String(configuration.baudRate),
                           "cs\(configuration.dataBits)",
                           configuration.stopBits == 2 ? "cstopb" : "-cstopb",
                           "-parenb", "-parodd", "-inpck", "-crtscts"]
            switch configuration.parity {
            case .none: break
            case .even: options += ["parenb", "inpck"]
            case .odd: options += ["parenb", "parodd", "inpck"]
            }
            switch configuration.flowControl {
            case .none: break
            case .hardware: options += ["crtscts"]
            case .software: options += ["ixon", "ixoff"]
            }
            arguments = [configuration.path] + options
        } else {
            arguments = ["scan"]
        }
        // SSH sends one shell command: quote every argument, including embedded apostrophes.
        return "exec sh -c \(quote(source)) serial-debug " + arguments.map(quote).joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static let source = #"""
LC_ALL=C
export LC_ALL
missing=
for tool in sh stty cat ls mkdir rmdir; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    printf 'SERIAL_DEBUG_SUPPORT\tMISSING\t%s\n' "$missing"
    exit 1
fi
if [ "$(printf 'SerialDebugTool\rcheck' | cat)" != "$(printf 'SerialDebugTool\rcheck')" ]; then
    printf 'SERIAL_DEBUG_SUPPORT\tTOOLS\tcat\n'
    exit 1
fi
stty -g </dev/null >/dev/null 2>&1
case $? in
    1) ;;
    *) printf 'SERIAL_DEBUG_SUPPORT\tTOOLS\tstty\n'; exit 1 ;;
esac
if ! ls -Lid /dev/null >/dev/null 2>&1; then
    printf 'SERIAL_DEBUG_SUPPORT\tTOOLS\tls\n'
    exit 1
fi
probe=/tmp/serial-debug-tool-probe-$$
umask 077
if ! mkdir "$probe" 2>/dev/null; then
    printf 'SERIAL_DEBUG_SUPPORT\tTEMP\n'
    exit 1
fi
if ! rmdir "$probe" 2>/dev/null; then
    printf 'SERIAL_DEBUG_SUPPORT\tTEMP\n'
    exit 1
fi
printf 'SERIAL_DEBUG_SUPPORT\tOK\n'
if [ "$1" = scan ]; then
    printf 'SERIAL_DEBUG_READY\n'
    for path in /dev/serial/by-id/* /dev/ttyUSB* /dev/ttyACM* /dev/ttyAMA* /dev/ttyS* /dev/ttyTHS* /dev/rfcomm* /dev/cu.*; do
        [ -c "$path" ] || continue
        case "$path" in *'
'*) continue ;; esac
        printf '%s\n' "$path"
    done
    printf 'SERIAL_DEBUG_END\n'
    exit 0
fi
device=$1
shift
[ -c "$device" ] || { printf 'Not a serial character device: %s\n' "$device" >&2; exit 1; }
# Dereference symlinks so aliases of the same device share this cooperative lock.
inode=$(set -- $(ls -Lid "$device"); printf '%s' "$1")
case "$inode" in ''|*[!0-9]*) exit 1 ;; esac
lock=/tmp/serial-debug-tool-$inode.lock
umask 077
mkdir "$lock" 2>/dev/null || { printf 'Serial device is already in use: %s\n' "$device" >&2; exit 1; }
saved=
reader=
writer=
cleanup() {
    trap '' HUP INT TERM
    [ -z "$reader" ] || kill "$reader" 2>/dev/null
    [ -z "$writer" ] || kill "$writer" 2>/dev/null
    [ -z "$reader" ] || wait "$reader" 2>/dev/null
    [ -z "$writer" ] || wait "$writer" 2>/dev/null
    [ -z "$saved" ] || stty "$mode" "$device" "$saved" 2>/dev/null
    exec 3>&- 4<&-
    rmdir "$lock" 2>/dev/null
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
# GNU/BusyBox use -F; macOS/BSD use -f. Both open without waiting for carrier.
mode=-F
saved=$(stty "$mode" "$device" -g 2>/dev/null) || {
    mode=-f
    saved=$(stty "$mode" "$device" -g) || exit 1
}
stty "$mode" "$device" "$@" || exit 1
exec 3<>"$device" || exit 1
exec 4<&0
printf 'SERIAL_DEBUG_READY\n'
parent=$$
# The reader signals the waiting shell on device EOF; its trap also stops cat.
(
    trap 'kill "$copy" 2>/dev/null; wait "$copy" 2>/dev/null; exit 1' HUP INT TERM
    cat <&3 4<&- &
    copy=$!
    wait "$copy"
    kill -TERM "$parent" 2>/dev/null
) &
reader=$!
cat <&4 >&3 &
writer=$!
# wait is interrupted by signals, so cleanup need not poll or leave a reader behind.
wait "$writer"
exit $?
"""#
}
