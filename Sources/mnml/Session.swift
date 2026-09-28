import Foundation

// What was open last time. A list of addresses and their names, and which one
// you were looking at — nothing else, because everything else is either on the
// page or in the history file next door.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
        /// Its tab group, if any. Absent in sessions from before groups.
        var group: UUID?
        /// The name you gave the tab, when you gave it one.
        var name: String?
        /// The right half of a split with the entry before it.
        var split: Bool?
        /// The pinned URL (Tab.home).
        var home: String?
        /// Its chat (Ask.swift), and whether its panel was open.
        var chat: UUID?
        var asking: Bool?
        /// A pin’s identity, shared across windows.
        var pinID: UUID? = nil
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
        /// The tab groups, in order. Absent in sessions from before groups.
        var groups: [TabGroup]?
    }

    /// The first space's is the session there always was; each other space
    /// keeps its own beside it.
    private static func file(_ space: UUID) -> URL {
        Store.file(space == Space.firstID ? "session.json" : "session-\(space.uuidString).json")
    }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        try? FileManager.default.removeItem(at: file(space))
    }

    static func read(space: UUID = Space.firstID) -> Shape {
        let file = file(space)
        guard let data = try? Data(contentsOf: file) else { return Shape(tabs: [], active: 0) }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else {
            // A file that's there but won't decode is not the same as no
            // file: something wrote it, and overwriting it on the next save
            // without a trace is how yesterday's tabs actually disappear.
            Store.quarantine(file)
            return Shape(tabs: [], active: 0)
        }
        return shape
    }

    /// `now` writes on the calling thread. Quitting doesn't wait for a
    /// background queue, and a session handed to one on the way out is a
    /// session that may never reach the disk.
    static func write(now: Bool = false, space: UUID = Space.firstID, _ shape: Shape) {
        // One after another, the newest last (see Disk).
        Disk.write(file(space), now: now) { try? JSONEncoder().encode(shape) }
    }
}

// The groups are the one part of the file an older or newer version may not
// agree on, so they are read leniently: a value that doesn't make sense is
// taken for no groups at all, never for a file that won't decode. That would
// put the whole session in quarantine and bring back not a single tab. In an
// extension, so the memberwise initialiser stays. (Upstream reads each entry
// by hand too; mnml's entries keep the synthesised reader, which knows their
// groups, splits and chats.)

extension Session.Shape {
    private enum Keys: String, CodingKey { case tabs, active, groups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        tabs = try c.decode([Session.Entry].self, forKey: .tabs)
        active = try c.decode(Int.self, forKey: .active)
        groups = try? c.decodeIfPresent([TabGroup].self, forKey: .groups)
    }
}
