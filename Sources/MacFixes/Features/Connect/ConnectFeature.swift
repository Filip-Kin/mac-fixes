import AppKit
import Darwin

/// Phone link compatible with Zorin Connect and KDE Connect for Android:
/// pairing, file transfer both ways, and clipboard sync, over the local network.
///
/// Discovery: we broadcast our identity on UDP 1716 and announce over Bonjour;
/// the phone does the same. Whoever hears the other connects over TCP, sends
/// its identity in plain text, and the socket is upgraded to TLS (the side
/// that opened the TCP connection is the TLS *server*). After that every
/// packet is a JSON line inside TLS.
final class ConnectFeature: NSObject, Feature, ObservableObject, @unchecked Sendable {

    /// What the Settings pane and menu show, published on main.
    struct DeviceRow: Identifiable, Equatable {
        let id: String
        var name: String
        var type: String
        var paired: Bool
        var connected: Bool
        var pairing: PairState
        var code: String?
        var battery: Int?
        var charging = false
    }
    enum PairState: Equatable { case none, requested, requestedByPeer }

    @Published private(set) var devices: [DeviceRow] = []
    @Published private(set) var status = "Off"
    @Published private(set) var transfer: String?

    private let defaults = UserDefaults.standard
    private let lock = NSRecursiveLock()

    // State below is guarded by `lock`.
    private var running = false
    private var identity: ConnectIdentity?
    private var tcpServer: (fd: Int32, port: UInt16)?
    private var udpFd: Int32 = -1
    private var links: [String: ConnectLink] = [:]
    private var pairing: [String: (state: PairState, timestamp: Int64, token: UUID)] = [:]
    private var lastSeenByIP: [UInt32: TimeInterval] = [:]
    private var connecting: Set<String> = []

    private var bonjour: NetService?
    private var broadcastTimer: Timer?
    private var clipboardTimer: Timer?
    private var lastChangeCount = 0
    private var ownChangeCount = -1
    private var clipboardUpdatedAt: Int64 = 0
    private let transfers = DispatchQueue(label: "com.filipkin.macfixes.connect.transfers")
    private let notificationQueue = DispatchQueue(label: "com.filipkin.macfixes.connect.notifications")
    private let input = ConnectInput()
    private var batteries: [String: (charge: Int, charging: Bool)] = [:]   // guarded by lock
    private var iconCache: [String: NSImage] = [:]                         // notificationQueue only

    // MARK: Settings

    var clipboardSync: Bool {
        get { defaults.object(forKey: "connectClipboard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "connectClipboard"); objectWillChange.send() }
    }

    /// Show the phone's notifications as banners on this Mac.
    var phoneNotifications: Bool {
        get { defaults.object(forKey: "connectNotifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "connectNotifications"); objectWillChange.send() }
    }

    /// Let the phone move the pointer and type (Zorin Connect's Remote input).
    var remoteInput: Bool {
        get { defaults.object(forKey: "connectRemoteInput") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "connectRemoteInput")
            objectWillChange.send()
            // The phone greys out its keyboard when this is off.
            for phone in connectedPhones() {
                pairedLink(phone.id)?.send(ConnectPacket(ConnectProtocol.keyboardState, ["state": newValue]))
            }
        }
    }

    var downloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    var deviceName: String {
        ConnectProtocol.cleanName(Host.current().localizedName ?? "Mac")
    }

    // MARK: Trusted devices (persisted)

    private struct Trusted: Codable {
        var name: String
        var type: String
        var cert: Data
    }

    private var trusted: [String: Trusted] {
        get {
            guard let d = defaults.data(forKey: "connectTrusted"),
                  let t = try? JSONDecoder().decode([String: Trusted].self, from: d) else { return [:] }
            return t
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "connectTrusted") }
    }

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return true }
        guard let id = ConnectIdentity.loadOrCreate() else {
            setStatus("Could not create this Mac's certificate (see ~/Library/Logs/MacFixes.log)")
            return false
        }
        guard let server = ConnectSocket.listen(in: ConnectProtocol.tcpPorts) else {
            setStatus("No free port in 1716–1764")
            return false
        }
        identity = id
        tcpServer = server
        running = true
        startUDP()
        spawn("tcp") { [weak self] in self?.acceptLoop(server.fd) }

        DispatchQueue.main.async { [self] in
            announceBonjour(port: server.port, deviceId: id.deviceId)
            broadcastIdentity()
            // Rebroadcast while no paired phone is connected, so it reconnects
            // after Wi-Fi changes or sleep without either side restarting.
            let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
                guard let self, !self.anyPairedConnected() else { return }
                self.broadcastIdentity()
            }
            RunLoop.main.add(t, forMode: .common)
            broadcastTimer = t
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
            startClipboardWatch()
        }
        trace("Connect", "started as \(id.deviceId) on TCP \(server.port)")
        setStatus("Waiting for your phone")
        publish()
        return true
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let all = Array(links.values)
        links.removeAll()
        pairing.removeAll()
        if let s = tcpServer { Darwin.shutdown(s.fd, SHUT_RDWR); Darwin.close(s.fd) }
        tcpServer = nil
        if udpFd >= 0 { Darwin.close(udpFd) }
        udpFd = -1
        lock.unlock()
        all.forEach { $0.close() }
        DispatchQueue.main.async { [self] in
            bonjour?.stop(); bonjour = nil
            broadcastTimer?.invalidate(); broadcastTimer = nil
            clipboardTimer?.invalidate(); clipboardTimer = nil
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
        setStatus("Off")
        publish()
    }

    @objc private func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.broadcastIdentity() }
    }

    private func spawn(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let t = Thread(block: body)
        t.name = "com.filipkin.macfixes.connect.\(name)"
        t.start()
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    // MARK: Identity packets

    private func identityPacket(tcpPort: UInt16? = nil) -> ConnectPacket? {
        lock.lock(); let id = identity; lock.unlock()
        guard let id else { return nil }
        var body: [String: Any] = [
            "deviceId": id.deviceId,
            "deviceName": deviceName,
            "deviceType": Self.isLaptop ? "laptop" : "desktop",
            "protocolVersion": ConnectProtocol.version,
            "incomingCapabilities": ConnectProtocol.incoming,
            "outgoingCapabilities": ConnectProtocol.outgoing,
        ]
        if let tcpPort { body["tcpPort"] = Int(tcpPort) }
        return ConnectPacket(ConnectProtocol.identity, body)
    }

    private static let isLaptop: Bool = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf).lowercased().contains("book")
    }()

    // MARK: Discovery: UDP

    private func startUDP() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var a = ConnectSocket.address(in_addr(s_addr: INADDR_ANY), ConnectProtocol.udpPort)
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
        guard ok else {
            trace("Connect", "UDP \(ConnectProtocol.udpPort) bind failed: \(errno)")
            Darwin.close(fd)
            return
        }
        udpFd = fd
        spawn("udp") { [weak self] in self?.udpLoop(fd) }
    }

    private func udpLoop(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: ConnectProtocol.maxIdentitySize)
        while isRunning() {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n <= 0 { if errno == EINTR { continue } else { break } }
            let data = Data(buf[0..<n])
            let ip = from.sin_addr
            spawn("udp-in") { [weak self] in self?.udpReceived(data, from: ip) }
        }
    }

    private func udpReceived(_ data: Data, from ip: in_addr) {
        guard ConnectSocket.isPrivate(ip), let p = ConnectPacket.parse(data),
              let peerId = acceptableIdentity(p, ip: ip),
              let port = p.int64("tcpPort"), let port16 = UInt16(exactly: port),
              ConnectProtocol.tcpPorts.contains(port16) else { return }
        guard beginConnecting(peerId) else { return }
        defer { endConnecting(peerId) }
        guard let fd = ConnectSocket.connect(ip, port16) else { return }
        guard var mine = identityPacket() else { Darwin.close(fd); return }
        mine.body["targetDeviceId"] = peerId
        mine.body["targetProtocolVersion"] = ConnectProtocol.version
        guard ConnectSocket.writeAll(fd, mine.serialized()) else { Darwin.close(fd); return }
        // We opened the TCP connection, so we are the TLS server.
        establish(fd: fd, ip: ip, plainIdentity: p, tlsServer: true)
    }

    /// Validates an identity heard on the network; returns the peer's id if we
    /// should talk to it.
    private func acceptableIdentity(_ p: ConnectPacket, ip: in_addr) -> String? {
        guard p.type == ConnectProtocol.identity, let peerId = p.string("deviceId"),
              ConnectProtocol.isValidDeviceId(peerId),
              !ConnectProtocol.cleanName(p.string("deviceName") ?? "").isEmpty,
              Int(p.int64("protocolVersion") ?? 0) >= ConnectProtocol.version else { return nil }
        lock.lock(); defer { lock.unlock() }
        // A known phone reaching out again (new network, restart) replaces the old link.
        guard running, peerId != identity?.deviceId else { return nil }
        // At most one attempt per address per second, like the phone.
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastSeenByIP[ip.s_addr], now - last < 1 { return nil }
        lastSeenByIP[ip.s_addr] = now
        return peerId
    }

    private func beginConnecting(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connecting.insert(id).inserted
    }
    private func endConnecting(_ id: String) {
        lock.lock(); connecting.remove(id); lock.unlock()
    }

    /// Our identity to every interface's broadcast address.
    func broadcastIdentity() {
        lock.lock(); let port = tcpServer?.port; lock.unlock()
        guard let port, let packet = identityPacket(tcpPort: port) else { return }
        let data = packet.serialized()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var targets: Set<UInt32> = [INADDR_BROADCAST]
        var ifs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifs) == 0 {
            var cur = ifs
            while let i = cur?.pointee {
                if let a = i.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
                   (i.ifa_flags & UInt32(IFF_BROADCAST)) != 0, let b = i.ifa_dstaddr {
                    b.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { targets.insert($0.pointee.sin_addr.s_addr) }
                }
                cur = i.ifa_next
            }
            freeifaddrs(ifs)
        }
        for t in targets {
            var a = ConnectSocket.address(in_addr(s_addr: t), ConnectProtocol.udpPort)
            _ = data.withUnsafeBytes { raw in
                withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    // MARK: Discovery: Bonjour

    private func announceBonjour(port: UInt16, deviceId: String) {
        let s = NetService(domain: "", type: "_kdeconnect._udp.", name: deviceId, port: Int32(port))
        s.setTXTRecord(NetService.data(fromTXTRecord: [
            "id": Data(deviceId.utf8),
            "name": Data(deviceName.utf8),
            "type": Data((Self.isLaptop ? "laptop" : "desktop").utf8),
            "protocol": Data(String(ConnectProtocol.version).utf8),
        ]))
        s.publish()
        bonjour = s
    }

    // MARK: Incoming TCP

    private func acceptLoop(_ server: Int32) {
        while isRunning() {
            guard let c = ConnectSocket.accept(server) else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                break
            }
            spawn("tcp-in") { [weak self] in self?.tcpAccepted(c.fd, ip: c.ip) }
        }
    }

    private func tcpAccepted(_ fd: Int32, ip: in_addr) {
        ConnectSocket.setTimeout(fd, 10)
        guard ConnectSocket.isPrivate(ip),
              let line = ConnectSocket.readLine(fd, max: ConnectProtocol.maxIdentitySize),
              let p = ConnectPacket.parse(line), let peerId = acceptableIdentity(p, ip: ip) else {
            Darwin.close(fd); return
        }
        if let target = p.string("targetDeviceId") {
            lock.lock(); let mine = identity?.deviceId; lock.unlock()
            guard target == mine else { Darwin.close(fd); return }
        }
        guard beginConnecting(peerId) else { Darwin.close(fd); return }
        defer { endConnecting(peerId) }
        // They opened the connection, so we are the TLS client.
        establish(fd: fd, ip: ip, plainIdentity: p, tlsServer: false)
    }

    /// TLS handshake, identity exchange inside TLS, certificate check, link.
    private func establish(fd: Int32, ip: in_addr, plainIdentity: ConnectPacket, tlsServer: Bool) {
        lock.lock(); let id = identity; lock.unlock()
        ConnectSocket.setTimeout(fd, 10)
        guard let id, let tls = ConnectTLS(fd: fd, server: tlsServer, identity: id.identity) else {
            Darwin.close(fd); return
        }
        guard let mine = identityPacket(), tls.write(mine.serialized()) else { tls.close(); return }
        var buffer = Data()
        var secureLine: Data?
        while secureLine == nil, buffer.count < ConnectProtocol.maxIdentitySize {
            guard let chunk = tls.read(max: 16 * 1024), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let nl = buffer.firstIndex(of: 0x0A) { secureLine = buffer[buffer.startIndex..<nl] }
        }
        guard let secureLine, let secure = ConnectPacket.parse(Data(secureLine)),
              secure.string("deviceId") == plainIdentity.string("deviceId"),
              let cert = tls.peerCertDER, let peer = ConnectPeer(identity: secure, certDER: cert) else {
            trace("Connect", "identity exchange failed with \(ConnectSocket.string(ip))")
            tls.close(); return
        }
        if let known = trusted[peer.id], known.cert != cert {
            trace("Connect", "\(peer.name) presented a different certificate than when paired; refusing")
            tls.close(); return
        }
        ConnectSocket.setTimeout(fd, 0)

        let link = ConnectLink(peer: peer, ip: ip, tls: tls, identity: id)
        link.onPacket = { [weak self] l, p in self?.received(p, on: l) }
        link.onClose = { [weak self] l in self?.linkClosed(l) }
        lock.lock()
        let old = links[peer.id]
        links[peer.id] = link
        lock.unlock()
        old?.close()
        link.start()
        defaults.set(true, forKey: Permissions.localNetworkProvenKey)
        trace("Connect", "connected to \(peer.name) (\(ConnectSocket.string(ip))) as TLS \(tlsServer ? "server" : "client")")

        if var t = trusted[peer.id] {
            t.name = peer.name
            t.type = peer.type
            trusted[peer.id] = t
            pairedSetup(link)
        }
        refreshStatus()
    }

    /// Once a phone is connected and paired.
    private func pairedSetup(_ link: ConnectLink) {
        sendClipboardConnect(to: link)
        link.send(ConnectPacket(ConnectProtocol.keyboardState, ["state": remoteInput]))
    }

    private func linkClosed(_ link: ConnectLink) {
        transfers.async { [weak self] in self?.finishBatch(link.peer.id, name: link.peer.name) }
        lock.lock()
        if links[link.peer.id] === link { links[link.peer.id] = nil }
        if links[link.peer.id] == nil { pairing[link.peer.id] = nil; batteries[link.peer.id] = nil }
        lock.unlock()
        refreshStatus()
    }

    private func anyPairedConnected() -> Bool {
        lock.lock(); let ids = Array(links.keys); lock.unlock()
        let t = trusted
        return ids.contains { t[$0] != nil }
    }

    // MARK: Packets

    private func received(_ p: ConnectPacket, on link: ConnectLink) {
        if p.type == ConnectProtocol.pair { pairPacket(p, on: link); return }
        guard trusted[link.peer.id] != nil else {
            // The phone thinks we are paired but we are not (e.g. we unpaired
            // while it was away). Tell it, so it shows the right state.
            link.send(ConnectPacket(ConnectProtocol.pair, ["pair": false]))
            return
        }
        switch p.type {
        case ConnectProtocol.share: shareReceived(p, on: link)
        case ConnectProtocol.shareUpdate: shareReceived(p, on: link)
        case ConnectProtocol.clipboard: clipboardReceived(p.string("content"), timestamp: nil)
        case ConnectProtocol.clipboardConnect: clipboardReceived(p.string("content"), timestamp: p.int64("timestamp"))
        case ConnectProtocol.notification: notificationReceived(p, on: link)
        case ConnectProtocol.mousepad: if remoteInput { input.handle(p) }
        case ConnectProtocol.battery: batteryReceived(p, on: link)
        default: break
        }
    }

    // MARK: Pairing

    private func pairPacket(_ p: ConnectPacket, on link: ConnectLink) {
        let id = link.peer.id
        lock.lock()
        let current = pairing[id]?.state ?? PairState.none
        lock.unlock()
        let isTrusted = trusted[id] != nil

        guard p.bool("pair") else {
            // Unpair or rejection from the phone.
            setPairing(id, nil)
            if isTrusted {
                var t = trusted; t[id] = nil; trusted = t
                trace("Connect", "\(link.peer.name) unpaired")
            }
            refreshStatus()
            return
        }
        switch current {
        case .requested:
            pairingDone(link)
        case .requestedByPeer:
            break
        case .none:
            if isTrusted { var t = trusted; t[id] = nil; trusted = t }
            guard let ts = p.int64("timestamp"),
                  abs(ts - Int64(Date().timeIntervalSince1970)) <= 1800 else {
                trace("Connect", "pair request from \(link.peer.name) has a missing or skewed timestamp")
                link.send(ConnectPacket(ConnectProtocol.pair, ["pair": false]))
                return
            }
            let token = setPairing(id, (.requestedByPeer, ts))
            refreshStatus()
            DispatchQueue.main.async { [weak self] in self?.askToAccept(link, token: token) }
            // The phone gives up after 30 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.expirePairing(id, token: token) }
        }
    }

    @discardableResult
    private func setPairing(_ id: String, _ value: (PairState, Int64)?) -> UUID {
        let token = UUID()
        lock.lock()
        if let value { pairing[id] = (value.0, value.1, token) } else { pairing[id] = nil }
        lock.unlock()
        return token
    }

    private func expirePairing(_ id: String, token: UUID) {
        lock.lock()
        let stale = pairing[id]?.token == token
        if stale { pairing[id] = nil }
        lock.unlock()
        if stale {
            if let alert = pendingAlert, pendingAlertToken == token { NSApp.abortModal(); alert.window.orderOut(nil) }
            refreshStatus()
        }
    }

    func requestPairing(_ id: String) {
        lock.lock(); let link = links[id]; lock.unlock()
        guard let link else { return }
        let ts = Int64(Date().timeIntervalSince1970)
        let token = setPairing(id, (.requested, ts))
        link.send(ConnectPacket(ConnectProtocol.pair, ["pair": true, "timestamp": ts]))
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.expirePairing(id, token: token) }
    }

    func cancelPairing(_ id: String) {
        lock.lock(); let link = links[id]; lock.unlock()
        setPairing(id, nil)
        link?.send(ConnectPacket(ConnectProtocol.pair, ["pair": false]))
        refreshStatus()
    }

    func unpair(_ id: String) {
        lock.lock(); let link = links[id]; lock.unlock()
        link?.send(ConnectPacket(ConnectProtocol.pair, ["pair": false]))
        var t = trusted; t[id] = nil; trusted = t
        setPairing(id, nil)
        refreshStatus()
    }

    private func pairingDone(_ link: ConnectLink) {
        setPairing(link.peer.id, nil)
        var t = trusted
        t[link.peer.id] = Trusted(name: link.peer.name, type: link.peer.type, cert: link.peer.certDER)
        trusted = t
        trace("Connect", "paired with \(link.peer.name)")
        pairedSetup(link)
        refreshStatus()
        Notifier.post(title: "Paired with \(link.peer.name)", body: "You can now send files between this Mac and your phone.")
    }

    private var pendingAlert: NSAlert?
    private var pendingAlertToken: UUID?

    /// Main thread. Modal prompt; closed early if the phone gives up.
    private func askToAccept(_ link: ConnectLink, token: UUID) {
        let code = verificationCode(link.peer.id) ?? "?"
        let alert = NSAlert()
        alert.messageText = "Pair with \(link.peer.name)?"
        alert.informativeText = "Only accept if your phone shows the same code:\n\n\(code)"
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Decline")
        pendingAlert = alert
        pendingAlertToken = token
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        pendingAlert = nil
        pendingAlertToken = nil

        lock.lock(); let stillPending = pairing[link.peer.id]?.token == token; lock.unlock()
        guard stillPending else { return }
        if response == .alertFirstButtonReturn {
            if link.send(ConnectPacket(ConnectProtocol.pair, ["pair": true])) { pairingDone(link) }
        } else {
            cancelPairing(link.peer.id)
        }
    }

    private func verificationCode(_ id: String) -> String? {
        lock.lock()
        let link = links[id], state = pairing[id], mine = identity?.certDER
        lock.unlock()
        guard let link, let state, let mine else { return nil }
        return ConnectVerification.code(myCert: mine, peerCert: link.peer.certDER, timestamp: state.timestamp)
    }

    // MARK: Receiving files, text and links

    /// One incoming batch of files from a phone. Touched only on `transfers`.
    private struct Batch {
        var expected: Int
        var totalBytes: Int64
        var doneBytes: Int64 = 0
        var files: [URL] = []
        var failed: [String] = []
    }
    private var batches: [String: Batch] = [:]

    private func shareReceived(_ p: ConnectPacket, on link: ConnectLink) {
        if p.type == ConnectProtocol.shareUpdate {
            transfers.async { [weak self] in self?.updateBatch(link, p) }
        } else if let text = p.string("text") {
            setPasteboard(text)
            Notifier.post(title: "Text from \(link.peer.name)", body: "Copied to the clipboard.")
        } else if let url = p.string("url"), let u = URL(string: url),
                  ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            DispatchQueue.main.async { NSWorkspace.shared.open(u) }
        } else if p.payloadSize != nil {
            // Receive in order on one queue: the phone sends the next file only
            // after the previous payload finishes.
            transfers.async { [weak self] in self?.receiveFile(p, from: link) }
        }
    }

    /// transfers queue. The phone announces (and later grows) the batch size.
    private func updateBatch(_ link: ConnectLink, _ p: ConnectPacket) {
        let n = Int(p.int64("numberOfFiles") ?? 1)
        let total = p.int64("totalPayloadSize") ?? 0
        if var b = batches[link.peer.id] {
            b.expected = max(n, b.files.count + b.failed.count)
            b.totalBytes = max(total, b.doneBytes)
            batches[link.peer.id] = b
        } else {
            batches[link.peer.id] = Batch(expected: n, totalBytes: total)
        }
    }

    private func receiveFile(_ p: ConnectPacket, from link: ConnectLink) {
        let id = link.peer.id
        if batches[id] == nil { updateBatch(link, p) }
        let rawName = (p.string("filename") ?? "").replacingOccurrences(of: "/", with: "_")
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty
            ? "file-\(Int(Date().timeIntervalSince1970))" : rawName
        let dest = uniqueURL(in: downloadFolder, name: name)
        let partial = dest.appendingPathExtension("part")
        let size = p.payloadSize ?? 0
        let bannerId = "receive-\(id)"

        func progress(_ got: Int64) {
            guard let b = batches[id] else { return }
            let index = b.files.count + b.failed.count + 1
            let label = b.expected > 1 ? "\(name) (\(index) of \(b.expected))" : name
            let fraction = b.totalBytes > 0 ? Double(b.doneBytes + got) / Double(b.totalBytes)
                                            : (size > 0 ? Double(got) / Double(size) : 0)
            setTransfer("Receiving \(label) \(Int(fraction * 100))%")
            Notifier.show(Notifier.Banner(id: bannerId, title: "Receiving from \(link.peer.name)",
                                          body: label, progress: min(max(fraction, 0), 1), timeout: nil))
        }
        progress(0)
        var last = Date.distantPast
        let ok = link.receivePayload(of: p, to: partial) { got in
            guard Date().timeIntervalSince(last) > 0.25 else { return }
            last = Date()
            progress(got)
        }
        let saved = ok && (try? FileManager.default.moveItem(at: partial, to: dest)) != nil
        if saved {
            defaults.set(true, forKey: Permissions.downloadsKey)
            if let ms = p.int64("lastModified"), ms > 0 {
                try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(ms) / 1000)],
                                                       ofItemAtPath: dest.path)
            }
            trace("Connect", "received \(dest.lastPathComponent) (\(size) bytes)")
        } else {
            if !FileManager.default.fileExists(atPath: partial.path) {
                // Could not even create the file: the Downloads permission.
                defaults.set(false, forKey: Permissions.downloadsKey)
            }
            try? FileManager.default.removeItem(at: partial)
            trace("Connect", "receiving \(name) failed")
        }

        var b = batches[id] ?? Batch(expected: 1, totalBytes: size)
        b.doneBytes += size
        if saved { b.files.append(dest) } else { b.failed.append(name) }
        batches[id] = b
        guard b.files.count + b.failed.count >= b.expected || !saved else { return }
        finishBatch(id, name: link.peer.name)
    }

    /// transfers queue. One banner for the whole batch.
    private func finishBatch(_ id: String, name: String) {
        guard let b = batches.removeValue(forKey: id) else { return }
        setTransfer(nil)
        let bannerId = "receive-\(id)"
        if !b.failed.isEmpty {
            let got = b.files.isEmpty ? "" : " \(b.files.count) arrived."
            var banner = Notifier.Banner(id: bannerId, title: "Transfer from \(name) stopped",
                                         body: "Couldn't receive \(b.failed.joined(separator: ", ")).\(got)", timeout: 15)
            banner.files = b.files
            Notifier.show(banner)
            return
        }
        var banner = Notifier.Banner(id: bannerId,
                                     title: b.files.count == 1 ? "Received \(b.files[0].lastPathComponent)"
                                                               : "Received \(b.files.count) files",
                                     body: "From \(name). Saved to Downloads.", timeout: 15)
        banner.files = b.files
        Notifier.show(banner)
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.path + ".part") {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    // MARK: Sending files, text and links

    /// Paired phones that are connected right now.
    func connectedPhones() -> [(id: String, name: String)] {
        lock.lock(); let live = links; lock.unlock()
        let t = trusted
        return live.values.filter { t[$0.peer.id] != nil }.map { ($0.peer.id, $0.peer.name) }.sorted { $0.name < $1.name }
    }

    private func pairedLink(_ id: String) -> ConnectLink? {
        lock.lock(); let link = links[id]; lock.unlock()
        return trusted[id] != nil ? link : nil
    }

    func chooseAndSend(to id: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        send(files: panel.urls, to: id)
    }

    /// The Mac's clipboard to the phone: a web link opens in the phone's
    /// browser, anything else lands on its clipboard.
    func sendClipboard(to id: String) {
        guard let link = pairedLink(id) else { return }
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            Notifier.post(title: "Nothing to send", body: "The clipboard has no text.")
            return
        }
        let isLink = URL(string: text).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && !text.contains(" ") } ?? false
        link.send(ConnectPacket(ConnectProtocol.share, [isLink ? "url" : "text": text]))
        Notifier.post(title: isLink ? "Link sent to \(link.peer.name)" : "Text sent to \(link.peer.name)",
                      body: isLink ? "It opens in the phone's browser." : "It's on the phone's clipboard.")
    }

    func send(files: [URL], to id: String) {
        guard let link = pairedLink(id) else { return }
        let regular = files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        guard !regular.isEmpty else { return }
        let sizes = regular.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        let total = sizes.reduce(0, +)
        let bannerId = "send-\(id)"

        transfers.async { [weak self] in
            guard let self else { return }
            link.send(ConnectPacket(ConnectProtocol.shareUpdate, ["numberOfFiles": regular.count, "totalPayloadSize": total]))
            var sentCount = 0
            var doneBytes: Int64 = 0
            for (i, file) in regular.enumerated() {
                let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                let packet = ConnectPacket(ConnectProtocol.share, [
                    "filename": file.lastPathComponent,
                    "lastModified": Int64(mod.timeIntervalSince1970 * 1000),
                    "numberOfFiles": regular.count,
                    "totalPayloadSize": total,
                ])
                let label = regular.count > 1 ? "\(file.lastPathComponent) (\(i + 1) of \(regular.count))" : file.lastPathComponent
                let base = doneBytes
                func show(_ sent: Int64) {
                    let fraction = total > 0 ? Double(base + sent) / Double(total) : 0
                    setTransfer("Sending \(label) \(Int(fraction * 100))%")
                    Notifier.show(Notifier.Banner(id: bannerId, title: "Sending to \(link.peer.name)",
                                                  body: label, progress: min(fraction, 1), timeout: nil))
                }
                show(0)
                var last = Date.distantPast
                let ok = link.sendWithPayload(packet, file: file) { sent in
                    guard Date().timeIntervalSince(last) > 0.25 else { return }
                    last = Date()
                    show(sent)
                }
                doneBytes += sizes[i]
                if ok { sentCount += 1 } else { trace("Connect", "sending \(file.lastPathComponent) failed"); break }
            }
            setTransfer(nil)
            if sentCount == regular.count {
                Notifier.show(Notifier.Banner(id: bannerId,
                                              title: sentCount == 1 ? "Sent \(regular[0].lastPathComponent)" : "Sent \(sentCount) files",
                                              body: "To \(link.peer.name).", timeout: 6))
            } else {
                Notifier.show(Notifier.Banner(id: bannerId, title: "Sending stopped",
                                              body: "\(sentCount) of \(regular.count) files reached \(link.peer.name).", timeout: 15))
            }
        }
    }

    // MARK: Phone notifications

    private func notificationReceived(_ p: ConnectPacket, on link: ConnectLink) {
        guard let key = p.string("id") else { return }
        let bannerId = "note-\(link.peer.id)-\(key)"
        if p.bool("isCancel") { Notifier.close(bannerId); return }
        // Silent ones are notifications that were already on the phone when it
        // connected; showing them all at once would be a flood.
        guard phoneNotifications, !p.bool("silent") else {
            if p.payloadSize != nil { notificationQueue.async { _ = link.receivePayloadData(of: p) } }
            return
        }
        notificationQueue.async { [weak self] in
            guard let self else { return }
            let hashKey = p.string("payloadHash").map { "\(link.peer.id)-\($0)" }
            var image: NSImage?
            if p.payloadSize != nil, let data = link.receivePayloadData(of: p), let img = NSImage(data: data) {
                image = img
                if let hashKey { iconCache[hashKey] = img }
            } else if let hashKey {
                image = iconCache[hashKey]
            }
            let app = p.string("appName") ?? link.peer.name
            let title = p.string("title").flatMap { $0.isEmpty ? nil : $0 }
            let text = p.string("text") ?? p.string("ticker") ?? ""
            var banner = Notifier.Banner(id: bannerId, title: title ?? app,
                                         body: title == nil ? text : "\(text)", image: image, timeout: 8)
            banner.caption = "\(app) · \(link.peer.name)"
            for action in p.stringList("actions").prefix(3) {
                banner.actions.append(Notifier.Action(title: action) {
                    link.send(ConnectPacket(ConnectProtocol.notificationAction, ["key": key, "action": action]))
                })
            }
            if let replyId = p.string("requestReplyId") {
                banner.reply = Notifier.Reply(placeholder: "Reply") { message in
                    link.send(ConnectPacket(ConnectProtocol.notificationReply, ["requestReplyId": replyId, "message": message]))
                }
            }
            if p.bool("isClearable") {
                // The × also clears it on the phone.
                banner.onDismiss = {
                    link.send(ConnectPacket(ConnectProtocol.notificationRequest, ["cancel": key]))
                }
            }
            Notifier.show(banner)
        }
    }

    // MARK: Battery and ring

    private func batteryReceived(_ p: ConnectPacket, on link: ConnectLink) {
        guard let charge = p.int64("currentCharge"), (0...100).contains(charge) else { return }
        lock.lock(); batteries[link.peer.id] = (Int(charge), p.bool("isCharging")); lock.unlock()
        if p.int64("thresholdEvent") == 1 {
            Notifier.post(title: "\(link.peer.name) battery low", body: "\(charge)% left.")
        }
        publish()
    }

    func battery(of id: String) -> (charge: Int, charging: Bool)? {
        lock.lock(); defer { lock.unlock() }; return batteries[id]
    }

    /// Makes the phone ring at full volume until it is found.
    func ringPhone(_ id: String) {
        guard let link = pairedLink(id) else { return }
        link.send(ConnectPacket(ConnectProtocol.findMyPhone))
    }

    // MARK: Clipboard sync

    private static let skipTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Main thread.
    private func startClipboardWatch() {
        lastChangeCount = NSPasteboard.general.changeCount
        clipboardUpdatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollClipboard() }
        RunLoop.main.add(t, forMode: .common)
        clipboardTimer = t
    }

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        clipboardUpdatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        guard clipboardSync, pb.changeCount != ownChangeCount,
              !(pb.types ?? []).contains(where: Self.skipTypes.contains),
              let text = pb.string(forType: .string), !text.isEmpty else { return }
        let packet = ConnectPacket(ConnectProtocol.clipboard, ["content": text])
        for phone in connectedPhones() {
            lock.lock(); let link = links[phone.id]; lock.unlock()
            link?.send(packet)
        }
    }

    private func sendClipboardConnect(to link: ConnectLink) {
        DispatchQueue.main.async { [self] in
            guard clipboardSync else { return }
            let pb = NSPasteboard.general
            guard !(pb.types ?? []).contains(where: Self.skipTypes.contains),
                  let text = pb.string(forType: .string), !text.isEmpty else { return }
            link.send(ConnectPacket(ConnectProtocol.clipboardConnect, ["content": text, "timestamp": clipboardUpdatedAt]))
        }
    }

    private func clipboardReceived(_ content: String?, timestamp: Int64?) {
        guard let content, !content.isEmpty else { return }
        DispatchQueue.main.async { [self] in
            guard clipboardSync else { return }
            // On connect, only take the phone's clipboard if it is newer.
            if let timestamp, timestamp == 0 || timestamp < clipboardUpdatedAt { return }
            setPasteboard(content)
        }
    }

    private func setPasteboard(_ text: String) {
        DispatchQueue.main.async { [self] in
            let pb = NSPasteboard.general
            guard pb.string(forType: .string) != text else { return }
            pb.clearContents()
            pb.setString(text, forType: .string)
            ownChangeCount = pb.changeCount
        }
    }

    // MARK: UI state

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.status = s }
    }

    private func setTransfer(_ s: String?) {
        DispatchQueue.main.async { [weak self] in self?.transfer = s }
    }

    private func refreshStatus() {
        let phones = connectedPhones()
        lock.lock(); let on = running; lock.unlock()
        if on {
            setStatus(phones.isEmpty ? "Waiting for your phone" : "Connected to \(phones.map(\.name).joined(separator: ", "))")
        }
        publish()
    }

    private func publish() {
        lock.lock()
        let live = links
        let states = pairing
        let power = batteries
        lock.unlock()
        let t = trusted
        var rows: [String: DeviceRow] = [:]
        for (id, info) in t {
            rows[id] = DeviceRow(id: id, name: info.name, type: info.type, paired: true,
                                 connected: live[id] != nil, pairing: .none, code: nil)
        }
        for (id, link) in live {
            let state = states[id]?.state ?? PairState.none
            rows[id] = DeviceRow(id: id, name: link.peer.name, type: link.peer.type, paired: t[id] != nil,
                                 connected: true, pairing: state,
                                 code: state == .none ? nil : verificationCode(id),
                                 battery: power[id]?.charge, charging: power[id]?.charging ?? false)
        }
        let sorted = rows.values.sorted { ($0.paired ? 0 : 1, $0.name) < ($1.paired ? 0 : 1, $1.name) }
        DispatchQueue.main.async { [weak self] in self?.devices = sorted }
    }
}
