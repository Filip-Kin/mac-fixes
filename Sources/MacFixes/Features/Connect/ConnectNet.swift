import Foundation
import Security
import Darwin

// Blocking BSD sockets plus TLS, one thread per connection, the same shape as
// the Android side. Network.framework is not used because the protocol sends
// one plain-text line on the TCP socket before upgrading that same socket to
// TLS, and it needs TLS 1.2 with self-signed certificates checked by hand.
// SecureTransport is deprecated but still the only system API that does both.

enum ConnectSocket {
    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Receive timeout in seconds; 0 clears it.
    static func setTimeout(_ fd: Int32, _ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func address(_ ip: in_addr, _ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr = ip
        return a
    }

    /// Listening TCP socket on the first free port in `range`.
    static func listen(in range: ClosedRange<UInt16>) -> (fd: Int32, port: UInt16)? {
        for port in range {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var a = address(in_addr(s_addr: INADDR_ANY), port)
            let ok = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0
            if ok, Darwin.listen(fd, 16) == 0 { return (fd, port) }
            close(fd)
        }
        return nil
    }

    static func accept(_ server: Int32) -> (fd: Int32, ip: in_addr)? {
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = withUnsafeMutablePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(server, $0, &len) }
        }
        guard fd >= 0 else { return nil }
        configure(fd)
        return (fd, a.sin_addr)
    }

    static func connect(_ ip: in_addr, _ port: UInt16, timeout: Int = 5) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd)
        setTimeout(fd, timeout)
        var a = address(ip, port)
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
        if !ok { close(fd); return nil }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base + sent, raw.count - sent)
                if n > 0 { sent += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    /// Read one newline-terminated line byte by byte, so nothing past the
    /// newline (the start of the TLS handshake) is consumed.
    static func readLine(_ fd: Int32, max: Int) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < max {
            let n = Darwin.read(fd, &byte, 1)
            if n == 1 {
                if byte == 0x0A { return line }
                line.append(byte)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return nil
    }

    /// LAN-only: private IPv4 ranges, link-local and loopback.
    static func isPrivate(_ ip: in_addr) -> Bool {
        let a = UInt32(bigEndian: ip.s_addr)
        let b1 = a >> 24, b2 = (a >> 16) & 0xFF
        return b1 == 10 || b1 == 127 || (b1 == 172 && (16...31).contains(b2))
            || (b1 == 192 && b2 == 168) || (b1 == 169 && b2 == 254)
    }

    static func string(_ ip: in_addr) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var ip = ip
        inet_ntop(AF_INET, &ip, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}

// MARK: - TLS

/// A TLS session over a connected socket. Reads and writes are serialised by
/// one lock (SecureTransport contexts are not thread-safe); the link's reader
/// polls the socket first so it only holds the lock when data is waiting.
final class ConnectTLS: @unchecked Sendable {
    let fd: Int32
    private let ctx: SSLContext
    private let lock = NSLock()
    private(set) var peerCertDER: Data?
    private var closed = false

    /// Performs the handshake. The certificate is not validated here: an
    /// unpaired peer is accepted so pairing can happen, and a paired peer's
    /// certificate is compared byte for byte by the caller.
    init?(fd: Int32, server: Bool, identity: SecIdentity) {
        self.fd = fd
        guard let ctx = SSLCreateContext(nil, server ? .serverSide : .clientSide, .streamType) else { return nil }
        self.ctx = ctx
        SSLSetIOFuncs(ctx, connectTLSRead, connectTLSWrite)
        SSLSetConnection(ctx, UnsafeRawPointer(bitPattern: Int(fd) + 1))
        SSLSetCertificate(ctx, [identity] as CFArray)
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetProtocolVersionMax(ctx, .tlsProtocol12)
        if server {
            SSLSetClientSideAuthenticate(ctx, .alwaysAuthenticate)
            SSLSetSessionOption(ctx, .breakOnClientAuth, true)
        } else {
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        }

        var status: OSStatus
        repeat { status = SSLHandshake(ctx) } while status == errSSLPeerAuthCompleted || status == errSSLWouldBlock
        guard status == noErr else {
            trace("Connect", "TLS handshake failed (\(server ? "server" : "client")): \(status)")
            return nil
        }
        var trust: SecTrust?
        if SSLCopyPeerTrust(ctx, &trust) == noErr, let trust,
           let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            peerCertDER = SecCertificateCopyData(leaf) as Data
        }
        guard peerCertDER != nil else {
            trace("Connect", "TLS peer sent no certificate")
            return nil
        }
    }

    deinit { close() }

    func write(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var done = 0
            while done < raw.count {
                var n = 0
                let st = SSLWrite(ctx, base + done, raw.count - done, &n)
                done += n
                if st != noErr && st != errSSLWouldBlock { return false }
            }
            return true
        }
    }

    /// Up to `max` bytes; empty on timeout (only when `pollMillis` given);
    /// nil once the connection is closed or broken.
    func read(max: Int, pollMillis: Int32? = nil) -> Data? {
        if let pollMillis {
            var buffered = 0
            lock.lock(); SSLGetBufferedReadSize(ctx, &buffered); lock.unlock()
            if buffered == 0 {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let r = poll(&p, 1, pollMillis)
                if r == 0 { return Data() }
                if r < 0 { return errno == EINTR ? Data() : nil }
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        var buf = Data(count: max)
        var n = 0
        let st = buf.withUnsafeMutableBytes { SSLRead(ctx, $0.baseAddress!, max, &n) }
        if n > 0 { return buf.prefix(n) }
        if st == errSSLWouldBlock { return Data() }
        return nil
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        SSLClose(ctx)
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

private func connectTLSRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer,
                            _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(Int(bitPattern: conn) - 1)
    let want = length.pointee
    var got = 0
    while got < want {
        let n = Darwin.read(fd, data + got, want - got)
        if n > 0 { got += n; continue }
        if n < 0 && errno == EINTR { continue }
        length.pointee = got
        // EOF, error, or receive timeout: all end the session.
        return n == 0 ? errSSLClosedGraceful : errSSLClosedAbort
    }
    length.pointee = got
    return noErr
}

private func connectTLSWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer,
                             _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(Int(bitPattern: conn) - 1)
    let want = length.pointee
    var sent = 0
    while sent < want {
        let n = Darwin.write(fd, data + sent, want - sent)
        if n > 0 { sent += n; continue }
        if n < 0 && errno == EINTR { continue }
        length.pointee = sent
        return errSSLClosedAbort
    }
    length.pointee = sent
    return noErr
}
