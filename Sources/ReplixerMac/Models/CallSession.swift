import Foundation

struct CallSession: Identifiable, Equatable {
    let id: UUID
    let appName: String
    let bundleID: String
    let startedAt: Date
    var endedAt: Date?

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var isActive: Bool { endedAt == nil }

    init(bundleID: String, appName: String) {
        self.id = UUID()
        self.bundleID = bundleID
        self.appName = appName
        self.startedAt = Date()
    }

    mutating func end() { endedAt = Date() }
}
