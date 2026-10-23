import Foundation
import Darwin
import IOKit
import IOKit.serial

struct SerialTransportError: LocalizedError, Sendable {
    let message: String
    var bytesWritten: Int = 0
    var errorDescription: String? { message }
}

/// All descriptor access stays on this actor. Reads and writes never block the UI.
actor SerialTransport {
    private var descriptor: Int32 = -1
    private var readBuffer = [UInt8](repeating: 0, count: 16_384)
    private var originalOptions: termios?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var reader: Task<Void, Never>?
    private var generation = UUID()
    private var writing = false
    private var leasedPath: String?

    deinit {
        reader?.cancel()
        if descriptor >= 0 {
            if var saved = originalOptions { _ = tcsetattr(descriptor, TCSANOW, &saved) }
            _ = ioctl(descriptor, TIOCNXCL)
            Darwin.close(descriptor)
        }
        if let leasedPath { SerialPortRegistry.shared.release(leasedPath) }
        continuation?.finish()
    }

    static func availablePorts() -> [SerialPort] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var paths = Set<String>()
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            if let value = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                paths.insert(value)
            }
            IOObjectRelease(service)
        }
        return paths.sorted().map { SerialPort(path: $0) }
    }

    func open(_ configuration: SerialConfiguration, generation token: UUID = UUID()) throws -> AsyncThrowingStream<Data, Error> {
        guard descriptor < 0 else { throw SerialTransportError(message: AppText.disconnectFirst) }
        guard configuration.path.hasPrefix("/dev/"),
              (1...4_000_000).contains(configuration.baudRate),
              (5...8).contains(configuration.dataBits),
              (1...2).contains(configuration.stopBits) else {
            throw SerialTransportError(message: AppText.invalidSerialParameters)
        }
        let path = URL(fileURLWithPath: configuration.path).resolvingSymlinksInPath().path
        guard SerialPortRegistry.shared.acquire(path) else {
            throw SerialTransportError(message: AppText.portAlreadyOpen)
        }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let error = Self.posixError(AppText.openFailed(configuration.path))
            SerialPortRegistry.shared.release(path)
            throw error
        }
        var saved = termios()
        var savedOptionsValid = false
        var configured = false
        defer {
            if !configured {
                if savedOptionsValid { _ = tcsetattr(fd, TCSANOW, &saved) }
                Darwin.close(fd)
                SerialPortRegistry.shared.release(path)
            }
        }
        guard tcgetattr(fd, &saved) == 0 else { throw Self.posixError(AppText.readSettingsFailed) }
        savedOptionsValid = true
        guard ioctl(fd, TIOCEXCL) == 0 else { throw Self.posixError(AppText.exclusiveAccessFailed) }

        var options = saved
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY | INPCK | ISTRIP)
        let sizes = [5: CS5, 6: CS6, 7: CS7, 8: CS8]
        options.c_cflag |= tcflag_t(sizes[configuration.dataBits] ?? CS8)
        if configuration.stopBits == 2 { options.c_cflag |= tcflag_t(CSTOPB) }
        if configuration.parity != .none {
            options.c_cflag |= tcflag_t(PARENB)
            options.c_iflag |= tcflag_t(INPCK)
            if configuration.parity == .odd { options.c_cflag |= tcflag_t(PARODD) }
        }
        switch configuration.flowControl {
        case .none: break
        case .hardware: options.c_cflag |= tcflag_t(CRTSCTS)
        case .software: options.c_iflag |= tcflag_t(IXON | IXOFF)
        }
        withUnsafeMutableBytes(of: &options.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }
        let standardRates: Set<Int> = [50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 9600, 19200, 38400, 7200, 14400, 28800, 57600, 76800, 115200, 230400]
        let speed = speed_t(standardRates.contains(configuration.baudRate) ? configuration.baudRate : 9600)
        guard cfsetispeed(&options, speed) == 0,
              cfsetospeed(&options, speed) == 0,
              tcsetattr(fd, TCSANOW, &options) == 0 else {
            throw Self.posixError(AppText.unsupportedSettings)
        }
        if !standardRates.contains(configuration.baudRate) {
            var customSpeed = speed_t(configuration.baudRate)
            // IOSSIOSPEED is a C function-like macro, so Swift spells out _IOW('T', 2, speed_t).
            let request = UInt(0x80000000 | (UInt32(MemoryLayout<speed_t>.size) << 16) | (UInt32(0x54) << 8) | 2)
            guard ioctl(fd, request, &customSpeed) == 0 else {
                throw Self.posixError(AppText.unsupportedBaud(configuration.baudRate))
            }
        }
        descriptor = fd
        leasedPath = path
        originalOptions = saved
        generation = token
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        continuation = pair.continuation
        continuation?.onTermination = { [weak self] _ in
            Task { await self?.close(ifGeneration: token) }
        }
        configured = true
        reader = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.readAvailable(token: token) == true else { break }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
        }
        return pair.stream
    }

    func close(ifGeneration token: UUID? = nil) {
        if let token, token != generation { return }
        generation = UUID()
        reader?.cancel()
        reader = nil
        if descriptor >= 0 {
            if var saved = originalOptions { _ = tcsetattr(descriptor, TCSANOW, &saved) }
            _ = ioctl(descriptor, TIOCNXCL)
            Darwin.close(descriptor)
        }
        descriptor = -1
        if let leasedPath { SerialPortRegistry.shared.release(leasedPath) }
        leasedPath = nil
        originalOptions = nil
        continuation?.finish()
        continuation = nil
        writing = false
    }

    func write(_ data: Data) async throws -> Int {
        guard descriptor >= 0 else { throw SerialTransportError(message: AppText.portNotConnected) }
        guard !writing else { throw SerialTransportError(message: AppText.sendInProgress) }
        writing = true
        let token = generation
        defer { if token == generation { writing = false } }
        var offset = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while offset < data.count {
            guard token == generation, descriptor >= 0, !Task.isCancelled else {
                throw SerialTransportError(message: AppText.sendInterrupted, bytesWritten: offset)
            }
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                throw SerialTransportError(message: Self.posixError(AppText.writeFailed).message, bytesWritten: offset)
            }
            if ContinuousClock.now >= deadline {
                throw SerialTransportError(message: AppText.sendTimeout, bytesWritten: offset)
            }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { throw SerialTransportError(message: AppText.sendCancelled, bytesWritten: offset) }
        }
        return offset
    }

    private func readAvailable(token: UUID) -> Bool {
        guard token == generation, descriptor >= 0 else { return false }
        let capacity = readBuffer.count
        var received = Data()
        while received.count < 65_536 {
            let count = Darwin.read(descriptor, &readBuffer, capacity)
            if count > 0 {
                received.append(contentsOf: readBuffer.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                if !received.isEmpty { _ = continuation?.yield(received) }
                let message = count == 0 ? AppText.deviceDisconnected : Self.posixError(AppText.readFailed).message
                continuation?.finish(throwing: SerialTransportError(message: message))
                close(ifGeneration: token)
                return false
            }
        }
        if !received.isEmpty, case .dropped = continuation?.yield(received) {
            continuation?.finish(throwing: SerialTransportError(message: AppText.receiveQueueFull))
            close(ifGeneration: token)
            return false
        }
        return true
    }

    private static func posixError(_ operation: String) -> SerialTransportError {
        let code = errno
        return SerialTransportError(message: AppText.systemError(operation, String(cString: strerror(code)), code))
    }
}

/// TIOCEXCL alone does not reject every same-process reopen on macOS.
/// This registry protects multiple windows; its only mutable value is guarded by the lock.
private final class SerialPortRegistry: @unchecked Sendable {
    static let shared = SerialPortRegistry()
    private let lock = NSLock()
    private var paths = Set<String>()

    func acquire(_ path: String) -> Bool {
        lock.withLock { paths.insert(path).inserted }
    }

    func release(_ path: String) {
        _ = lock.withLock { paths.remove(path) }
    }
}
