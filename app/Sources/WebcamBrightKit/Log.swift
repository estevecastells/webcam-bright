import Foundation

/// ~/Library/Logs/webcam-bright.log: one line per event, emptied above 1 MB.
public enum Log {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/webcam-bright.log")
    private static let queue = DispatchQueue(label: "webcam-bright.log")
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func write(_ message: String) {
        let line = "\(dateFormat.string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Waits for the lines already written, before the app quits.
    public static func flush() {
        queue.sync {}
    }

    static func trim() {
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

func log(_ message: String) {
    Log.write(message)
}
