import Foundation

enum Paths {
    static let support: URL = {
        if let home = ProcessInfo.processInfo.environment["SMILEY_HOME"] { return URL(fileURLWithPath: home, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Smiley", isDirectory: true)
    }()
    static var models: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Smiley/models", isDirectory: true)
    }
    static var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    static var database: URL { support.appendingPathComponent("smiley.sqlite") }

    static func ensure() {
        for dir in [support, models, logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

private let logQueue = DispatchQueue(label: "smiley.log")
private let logFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
}()

func smileyLog(_ message: String) {
    let line = "\(logFormatter.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    logQueue.async {
        let url = Paths.logs.appendingPathComponent("smiley.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}
