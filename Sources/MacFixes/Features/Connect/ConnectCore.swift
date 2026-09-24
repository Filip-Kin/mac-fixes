import Foundation
import Security
import CryptoKit

// Protocol plumbing for talking to Zorin Connect / KDE Connect phones.
//
// Written from the public protocol (packet types, ports, pairing rules) as
// implemented by the KDE Connect Android app, protocol version 8. Every packet
// is one line of JSON: {"id": ms, "type": "kdeconnect.x", "body": {...}}.

enum ConnectProtocol {
    static let version = 8
    static let udpPort: UInt16 = 1716
    static let tcpPorts: ClosedRange<UInt16> = 1716...1764
    static let payloadPorts: ClosedRange<UInt16> = 1739...1764
    static let maxIdentitySize = 512 * 1024
    static let maxPacketSize = 32 * 1024 * 1024

    static let identity = "kdeconnect.identity"
    static let pair = "kdeconnect.pair"
    static let share = "kdeconnect.share.request"
    static let shareUpdate = "kdeconnect.share.request.update"
    static let clipboard = "kdeconnect.clipboard"
    static let clipboardConnect = "kdeconnect.clipboard.connect"

    static let notification = "kdeconnect.notification"
    static let notificationRequest = "kdeconnect.notification.request"
    static let notificationReply = "kdeconnect.notification.reply"
    static let notificationAction = "kdeconnect.notification.action"
    static let mousepad = "kdeconnect.mousepad.request"
    static let keyboardState = "kdeconnect.mousepad.keyboardstate"
    static let battery = "kdeconnect.battery"
    static let findMyPhone = "kdeconnect.findmyphone.request"

    /// What we accept and send. The phone only enables a plugin when the
    /// desktop lists the plugin's packet types here.
    static let incoming = [share, shareUpdate, clipboard, clipboardConnect, notification, mousepad, battery]
    static let outgoing = [share, shareUpdate, clipboard, clipboardConnect,
                           notificationRequest, notificationReply, notificationAction,
                           keyboardState, findMyPhone]

    static func isValidDeviceId(_ s: String) -> Bool {
        s.range(of: "^[a-zA-Z0-9_-]{32,38}$", options: .regularExpression) != nil
    }

    /// The same filter the phone applies to device names.
    static func cleanName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "\"',;:.!?()[]<>")
        return String(String(s.unicodeScalars.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces).prefix(32))
    }
}

/// One protocol packet. Body values are plain JSON types.
struct ConnectPacket: @unchecked Sendable {
    var type: String
    var body: [String: Any]
    var payloadSize: Int64?
    var payloadPort: Int?

    init(_ type: String, _ body: [String: Any] = [:]) {
        self.type = type
        self.body = body
    }

    func serialized() -> Data {
        var obj: [String: Any] = [
            "id": Int64(Date().timeIntervalSince1970 * 1000),
            "type": type,
            "body": body,
        ]
        if let payloadSize, let payloadPort {
            obj["payloadSize"] = payloadSize
            obj["payloadTransferInfo"] = ["port": payloadPort]
        }
        var data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    static func parse(_ line: Data) -> ConnectPacket? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String,
              let body = obj["body"] as? [String: Any] else { return nil }
        var p = ConnectPacket(type, body)
        if let size = (obj["payloadSize"] as? NSNumber)?.int64Value,
           let info = obj["payloadTransferInfo"] as? [String: Any],
           let port = (info["port"] as? NSNumber)?.intValue {
            p.payloadSize = size
            p.payloadPort = port
        }
        return p
    }

    func string(_ k: String) -> String? { body[k] as? String }
    func int64(_ k: String) -> Int64? { (body[k] as? NSNumber)?.int64Value }
    func bool(_ k: String) -> Bool { (body[k] as? NSNumber)?.boolValue ?? false }
    func stringList(_ k: String) -> [String] { body[k] as? [String] ?? [] }
}

/// A peer as described by its identity packet plus its TLS certificate.
struct ConnectPeer: Sendable {
    let id: String
    var name: String
    var type: String
    var protocolVersion: Int
    var certDER: Data
    var incoming: [String]
    var outgoing: [String]

    init?(identity p: ConnectPacket, certDER: Data) {
        guard p.type == ConnectProtocol.identity,
              let id = p.string("deviceId"), ConnectProtocol.isValidDeviceId(id) else { return nil }
        let name = ConnectProtocol.cleanName(p.string("deviceName") ?? "")
        guard !name.isEmpty else { return nil }
        self.id = id
        self.name = name
        self.type = p.string("deviceType") ?? "phone"
        self.protocolVersion = Int(p.int64("protocolVersion") ?? 0)
        self.certDER = certDER
        self.incoming = p.stringList("incomingCapabilities")
        self.outgoing = p.stringList("outgoingCapabilities")
    }
}

// MARK: - Our identity (device id + TLS certificate)

/// This Mac's device id and self-signed certificate. The id is the
/// certificate's common name, as the protocol expects.
///
/// The key and certificate are files in Application Support (mode 0600), not
/// keychain items: the keychain ties "Always Allow" to the exact binary for a
/// self-signed app, so every rebuild or update prompted for the login
/// password again. The in-memory key becomes a SecIdentity through
/// SecIdentityCreate, which Security.framework exports but does not declare
/// publicly. If that ever disappears we fall back to the keychain.
struct ConnectIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certDER: Data
    let deviceId: String

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filip's Mac Fixes/Connect", isDirectory: true)
    }
    private static var keyFile: URL { folder.appendingPathComponent("private-key.der") }
    private static var certFile: URL { folder.appendingPathComponent("certificate.der") }

    static func loadOrCreate() -> ConnectIdentity? {
        if let found = load() { return found }
        guard create() else { return nil }
        return load()
    }

    private static func load() -> ConnectIdentity? {
        guard let keyData = try? Data(contentsOf: keyFile),
              let certData = try? Data(contentsOf: certFile),
              let cert = SecCertificateCreateWithData(nil, certData as CFData) else { return nil }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ] as CFDictionary, &error) else {
            trace("Connect", "private key unreadable: \(error?.takeRetainedValue().localizedDescription ?? "?")")
            return nil
        }
        var cn: CFString?
        SecCertificateCopyCommonName(cert, &cn)
        guard let deviceId = cn as String?, ConnectProtocol.isValidDeviceId(deviceId) else { return nil }
        guard let identity = makeIdentity(cert, key) ?? keychainIdentity(cert, keyData) else {
            trace("Connect", "could not build a TLS identity")
            return nil
        }
        return ConnectIdentity(identity: identity, certDER: certData, deviceId: deviceId)
    }

    private typealias CreateFn = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?

    private static func makeIdentity(_ cert: SecCertificate, _ key: SecKey) -> SecIdentity? {
        guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(lib, "SecIdentityCreate") else { return nil }
        return unsafeBitCast(sym, to: CreateFn.self)(nil, cert, key)?.takeRetainedValue()
    }

    /// Fallback: put the key and certificate in the login keychain (prompts
    /// for the keychain password after each update, as before).
    private static func keychainIdentity(_ cert: SecCertificate, _ keyData: Data) -> SecIdentity? {
        trace("Connect", "SecIdentityCreate unavailable; falling back to the keychain")
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ] as CFDictionary, &error) else { return nil }
        SecItemAdd([kSecValueRef as String: key] as CFDictionary, nil)
        SecItemAdd([kSecValueRef as String: cert] as CFDictionary, nil)
        var identity: SecIdentity?
        SecIdentityCreateWithCertificate(nil, cert, &identity)
        return identity
    }

    private static func create() -> Bool {
        let deviceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("macfixes-connect-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return false }
        let pem = tmp.appendingPathComponent("key.pem").path
        let certPem = tmp.appendingPathComponent("cert.pem").path
        let keyDer = tmp.appendingPathComponent("key.der").path
        let certDer = tmp.appendingPathComponent("cert.der").path

        guard run(["genrsa", "-out", pem, "2048"]),
              run(["req", "-x509", "-new", "-key", pem, "-sha256", "-days", "3650", "-set_serial", "1",
                   "-subj", "/CN=\(deviceId)/OU=KDE Connect/O=KDE", "-out", certPem]),
              run(["rsa", "-in", pem, "-outform", "DER", "-out", keyDer]),      // PKCS#1, what SecKey expects
              run(["x509", "-in", certPem, "-outform", "DER", "-out", certDer]),
              let key = fm.contents(atPath: keyDer), let cert = fm.contents(atPath: certDer) else {
            trace("Connect", "certificate generation failed")
            return false
        }
        guard fm.createFile(atPath: keyFile.path, contents: key, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: certFile.path, contents: cert, attributes: [.posixPermissions: 0o600]) else { return false }
        trace("Connect", "generated identity \(deviceId)")
        return true
    }

    private static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }
}

// MARK: - Pairing verification code

enum ConnectVerification {
    /// The 8-character code both screens show while pairing: SHA-256 over the
    /// two public keys (larger first, compared as unsigned bytes) followed by
    /// the pairing timestamp in decimal.
    static func code(myCert: Data, peerCert: Data, timestamp: Int64) -> String? {
        guard let a = publicKeyInfo(myCert), let b = publicKeyInfo(peerCert) else { return nil }
        var input = a.lexicographicallyPrecedes(b) ? b + a : a + b
        input.append(Data(String(timestamp).utf8))
        let hex = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8)).uppercased()
    }

    /// The SubjectPublicKeyInfo element of an X.509 certificate, as DER.
    static func publicKeyInfo(_ cert: Data) -> Data? {
        let b = [UInt8](cert)
        guard let certSeq = element(b, 0), certSeq.tag == 0x30,
              let tbs = element(b, certSeq.body), tbs.tag == 0x30 else { return nil }
        var i = tbs.body
        if let v = element(b, i), v.tag == 0xA0 { i = v.end }   // optional version
        for _ in 0..<5 {                                         // serial, sigAlg, issuer, validity, subject
            guard let e = element(b, i) else { return nil }
            i = e.end
        }
        guard let spki = element(b, i), spki.tag == 0x30 else { return nil }
        return Data(b[i..<spki.end])
    }

    private static func element(_ b: [UInt8], _ i: Int) -> (tag: UInt8, body: Int, end: Int)? {
        guard i + 2 <= b.count else { return nil }
        let tag = b[i]
        var len = Int(b[i + 1])
        var body = i + 2
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, body + n <= b.count else { return nil }
            len = 0
            for k in 0..<n { len = (len << 8) | Int(b[body + k]) }
            body += n
        }
        guard body + len <= b.count else { return nil }
        return (tag, body, body + len)
    }
}
