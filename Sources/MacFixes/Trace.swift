import Foundation

/// Appends one line to ~/Library/Logs/MacFixes.log (capped at 256 KB). For the
/// few decisions worth being able to check after the fact.
func trace(_ tag: String, _ msg: String) {
    let path = "\(NSHomeDirectory())/Library/Logs/MacFixes.log"
    let line = "\(Date()) \(tag): \(msg)\n"
    if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 256 * 1024 {
        try? FileManager.default.removeItem(atPath: path)
    }
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
