import Foundation

/// Appends one line to ~/Library/Logs/MacFixes.log (capped at 256 KB). For the
/// few decisions worth being able to check after the fact.
func trace(_ tag: String, _ msg: String, at: Date = Date()) {
    let path = "\(NSHomeDirectory())/Library/Logs/MacFixes.log"
    let line = "\(at) \(tag): \(msg)\n"
    if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 256 * 1024 {
        try? FileManager.default.removeItem(atPath: path)
    }
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

private let traceQueue = DispatchQueue(label: "com.filipkin.macfixes.trace", qos: .utility)

/// `trace` without blocking the caller. Use from event-tap callbacks: file I/O
/// can stall for seconds when the disk is busy, and every key waits on the tap.
func traceAsync(_ tag: String, _ msg: String) {
    let at = Date()
    traceQueue.async { trace(tag, msg, at: at) }
}
