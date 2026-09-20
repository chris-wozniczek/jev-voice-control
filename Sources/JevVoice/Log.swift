import OSLog

enum Log {
    static let speech = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "speech")
    static let agent  = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "agent")
    static let cua    = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "cua")
    static let command = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "command")
}
