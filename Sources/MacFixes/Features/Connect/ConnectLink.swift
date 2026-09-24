import Foundation
import Darwin

/// One live, encrypted connection to a phone. Owns a reader thread that turns
/// the byte stream into packets, and knows how to move file payloads, which
/// travel on their own short-lived TLS sockets.
final class ConnectLink: @unchecked Sendable {
    let peer: ConnectPeer
    let ip: in_addr
    private let tls: ConnectTLS
    private let identity: ConnectIdentity
    private var running = true

    var onPacket: ((ConnectLink, ConnectPacket) -> Void)?
    var onClose: ((ConnectLink) -> Void)?

    init(peer: ConnectPeer, ip: in_addr, tls: ConnectTLS, identity: ConnectIdentity) {
        self.peer = peer
        self.ip = ip
        self.tls = tls
        self.identity = identity
    }

    func start() {
        let t = Thread { [self] in readLoop() }
        t.name = "com.filipkin.macfixes.connect.link"
        t.start()
    }

    func close() {
        running = false
        tls.close()
    }

    @discardableResult
    func send(_ packet: ConnectPacket) -> Bool {
        tls.write(packet.serialized())
    }

    private func readLoop() {
        var buffer = Data()
        while running {
            guard let chunk = tls.read(max: 64 * 1024, pollMillis: 1000) else { break }
            if chunk.isEmpty { continue }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                if line.isEmpty { continue }
                if let p = ConnectPacket.parse(Data(line)) { onPacket?(self, p) }
            }
            if buffer.count > ConnectProtocol.maxPacketSize { break }
        }
        running = false
        tls.close()
        trace("Connect", "link to \(peer.name) closed")
        onClose?(self)
    }

    // MARK: Payloads

    /// Download a packet's payload into `file`. The sender listens; we connect
    /// and act as the TLS client. `progress` gets bytes so far.
    func receivePayload(of packet: ConnectPacket, to file: URL, progress: ((Int64) -> Void)? = nil) -> Bool {
        guard let size = packet.payloadSize, let port = packet.payloadPort,
              let p16 = UInt16(exactly: port), let fd = ConnectSocket.connect(ip, p16) else { return false }
        ConnectSocket.setTimeout(fd, 30)
        guard let session = ConnectTLS(fd: fd, server: false, identity: identity.identity) else {
            Darwin.close(fd); return false
        }
        defer { session.close() }
        guard session.peerCertDER == peer.certDER else {
            trace("Connect", "payload socket certificate mismatch")
            return false
        }
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let out = try? FileHandle(forWritingTo: file) else { return false }
        defer { try? out.close() }
        var got: Int64 = 0
        while got < size {
            guard let chunk = session.read(max: Int(min(256 * 1024, size - got))), !chunk.isEmpty else { break }
            do { try out.write(contentsOf: chunk) } catch { return false }
            got += Int64(chunk.count)
            progress?(got)
        }
        return got == size
    }

    /// Small payloads (notification icons) straight into memory.
    func receivePayloadData(of packet: ConnectPacket, limit: Int64 = 2 * 1024 * 1024) -> Data? {
        guard let size = packet.payloadSize, size > 0, size <= limit, let port = packet.payloadPort,
              let p16 = UInt16(exactly: port), let fd = ConnectSocket.connect(ip, p16) else { return nil }
        ConnectSocket.setTimeout(fd, 10)
        guard let session = ConnectTLS(fd: fd, server: false, identity: identity.identity) else {
            Darwin.close(fd); return nil
        }
        defer { session.close() }
        guard session.peerCertDER == peer.certDER else { return nil }
        var data = Data()
        while Int64(data.count) < size {
            guard let chunk = session.read(max: Int(size) - data.count), !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }

    /// Send `packet` with `file` as its payload: listen on a payload port,
    /// announce it, wait for the phone to connect, act as TLS server.
    func sendWithPayload(_ packet: ConnectPacket, file: URL, progress: ((Int64) -> Void)? = nil) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              let input = try? FileHandle(forReadingFrom: file),
              let server = ConnectSocket.listen(in: ConnectProtocol.payloadPorts) else { return false }
        defer { try? input.close(); Darwin.close(server.fd) }

        var p = packet
        p.payloadSize = size.int64Value
        p.payloadPort = Int(server.port)
        guard send(p) else { return false }

        // The phone has 10 seconds to connect, as on its side.
        var pfd = pollfd(fd: server.fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 10_000) == 1, let conn = ConnectSocket.accept(server.fd) else {
            trace("Connect", "phone never connected for payload")
            return false
        }
        ConnectSocket.setTimeout(conn.fd, 30)
        guard let session = ConnectTLS(fd: conn.fd, server: true, identity: identity.identity) else {
            Darwin.close(conn.fd); return false
        }
        defer { session.close() }
        guard session.peerCertDER == peer.certDER else {
            trace("Connect", "payload socket certificate mismatch")
            return false
        }
        var sent: Int64 = 0
        while true {
            guard let chunk = try? input.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            guard session.write(chunk) else { return false }
            sent += Int64(chunk.count)
            progress?(sent)
        }
        return sent == size.int64Value
    }
}
