import Foundation
import Network

struct FoundDevice: Identifiable, Equatable {
    let host: String
    var name: String?
    var kind: String
    var id: String { host }
}

// Finds file-sharing devices on this Wi-Fi: Macs and NAS drives that announce SMB with Bonjour,
// and computers such as Windows PCs that answer on the file-sharing port 445. Windows names come
// from a NetBIOS name query sent to each found PC. Nothing is broadcast.
@MainActor
final class DeviceFinder: ObservableObject {
    @Published private(set) var devices: [FoundDevice] = []
    @Published private(set) var running = false
    @Published private(set) var note: String?
    private var browser: NWBrowser?
    private var work: Task<Void, Never>?

    func start() {
        stop()
        devices = []
        note = nil
        running = true
        browse()
        work = Task { [weak self] in
            await self?.scan()
            // Bonjour answers can still arrive for a moment.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.finish()
        }
    }
    func stop() {
        browser?.cancel()
        browser = nil
        work?.cancel()
        work = nil
        running = false
    }
    private func finish() {
        guard running else { return }
        browser?.cancel()
        browser = nil
        running = false
        if devices.isEmpty {
            note = "Nothing found. Check that the iPhone and the computer are on the same Wi-Fi, that file sharing is on, and that Local Network is allowed for Newexplorer in Settings."
        }
    }
    private func add(_ device: FoundDevice) {
        if let index = devices.firstIndex(where: { $0.host == device.host }) {
            if devices[index].name == nil { devices[index].name = device.name }
            return
        }
        devices.append(device)
        devices.sort { ($0.name ?? $0.host).localizedStandardCompare($1.name ?? $1.host) == .orderedAscending }
    }

    private func browse() {
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                let endpoint = result.endpoint
                Task { @MainActor [weak self] in
                    guard let host = await LocalNetwork.resolve(endpoint) else { return }
                    self?.add(FoundDevice(host: host, name: name, kind: "Mac or NAS (Bonjour)"))
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func scan() async {
        guard let wifi = LocalNetwork.wifiAddress() else {
            note = "Connect to Wi-Fi to find devices."
            return
        }
        var pending = LocalNetwork.hosts(address: wifi.address, mask: wifi.mask)[...]
        await withTaskGroup(of: (String, Bool, String?).self) { group in
            var started = 0
            while started < 32, let host = pending.popFirst() {
                group.addTask { await LocalNetwork.probe(host) }
                started += 1
            }
            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if result.1 { add(FoundDevice(host: result.0, name: result.2, kind: "File sharing (port 445)")) }
                if let host = pending.popFirst() { group.addTask { await LocalNetwork.probe(host) } }
            }
        }
    }
}

enum LocalNetwork {
    private static let queue = DispatchQueue(label: "Newexplorer.localNetwork", attributes: .concurrent)

    // Port 445 first; a PC that answers is then asked for its name.
    static func probe(_ host: String) async -> (String, Bool, String?) {
        guard await isOpen(host, port: 445) else { return (host, false, nil) }
        return (host, true, await netbiosName(host))
    }

    // The Wi-Fi address and netmask, in host byte order.
    static func wifiAddress() -> (address: UInt32, mask: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee
            pointer = entry.ifa_next
            guard String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr, let mask = entry.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let net = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            return (ip, net)
        }
        return nil
    }

    // The other addresses of the network, at most the 254 of the iPhone's own /24.
    static func hosts(address: UInt32, mask: UInt32) -> [String] {
        let netmask: UInt32 = mask.nonzeroBitCount < 24 ? 0xFFFF_FF00 : mask
        let network = address & netmask
        let broadcast = network | ~netmask
        guard broadcast > network &+ 1 else { return [] }
        return (network + 1 ..< broadcast).filter { $0 != address }.map(text)
    }
    static func text(_ value: UInt32) -> String {
        "\(value >> 24 & 255).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)"
    }

    static func isOpen(_ host: String, port: UInt16, timeout: TimeInterval = 1.2) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 445, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.finish(true)
                    connection.cancel()
                case .waiting, .failed:
                    once.finish(false)
                    connection.cancel()
                case .cancelled:
                    once.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.finish(false)
                connection.cancel()
            }
        }
    }

    // The IPv4 address of a Bonjour service.
    static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 3) async -> String? {
        await withCheckedContinuation { continuation in
            let once = Once<String?>(continuation)
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let connection = NWConnection(to: endpoint, using: parameters)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var host: String?
                    if case let .hostPort(address, _)? = connection.currentPath?.remoteEndpoint, case let .ipv4(ip) = address {
                        host = "\(ip)"
                    }
                    once.finish(host)
                    connection.cancel()
                case .waiting, .failed:
                    once.finish(nil)
                    connection.cancel()
                case .cancelled:
                    once.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.finish(nil)
                connection.cancel()
            }
        }
    }

    // A NetBIOS node status request for "*", sent straight to one address.
    static func netbiosQuery() -> Data {
        var packet = Data([0x4E, 0x58, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20])
        let name: [UInt8] = [0x2A] + [UInt8](repeating: 0, count: 15)
        for byte in name {
            packet.append(0x41 + (byte >> 4))
            packet.append(0x41 + (byte & 0x0F))
        }
        packet.append(contentsOf: [0x00, 0x00, 0x21, 0x00, 0x01])
        return packet
    }
    // The computer's own name from the answer: the first unique name with suffix 0x00.
    static func parseNetbiosName(_ response: Data) -> String? {
        let bytes = [UInt8](response)
        // Header (12), the encoded name (34), type, class, time to live and data length (10).
        let countOffset = 56
        guard bytes.count > countOffset else { return nil }
        var offset = countOffset + 1
        for _ in 0..<Int(bytes[countOffset]) {
            guard offset + 18 <= bytes.count else { break }
            let suffix = bytes[offset + 15]
            let flags = UInt16(bytes[offset + 16]) << 8 | UInt16(bytes[offset + 17])
            if suffix == 0x00 && flags & 0x8000 == 0 {
                let name = String(decoding: bytes[offset..<(offset + 15)], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(.controlCharacters))
                if !name.isEmpty { return name }
            }
            offset += 18
        }
        return nil
    }
    static func netbiosName(_ host: String, timeout: TimeInterval = 1) async -> String? {
        await withCheckedContinuation { continuation in
            let once = Once<String?>(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 137, using: .udp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: LocalNetwork.netbiosQuery(), completion: .contentProcessed { _ in })
                    connection.receiveMessage { data, _, _, _ in
                        once.finish(data.flatMap { LocalNetwork.parseNetbiosName($0) })
                        connection.cancel()
                    }
                case .waiting, .failed:
                    once.finish(nil)
                    connection.cancel()
                case .cancelled:
                    once.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.finish(nil)
                connection.cancel()
            }
        }
    }
}

// Resumes a continuation once, whichever callback comes first.
private final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func finish(_ value: Value) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
