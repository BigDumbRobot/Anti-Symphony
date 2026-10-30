import Foundation

/// Routing IDs and names for an 8x8 Analog-Optical board in slot 1 (see docs/protocol.md).
enum Names {
    struct Item: Identifiable, Hashable { let id: Int; let name: String }

    static let none = 0xEC

    static let sources: [Item] = {
        var list = [Item(id: none, name: "None")]
        list += (0..<8).map { (i: Int) -> Item in Item(id: 0x20 + i, name: "Analog In \(i + 1)") }
        list += (0..<8).map { (i: Int) -> Item in Item(id: 0x28 + i, name: "Optical In \(i + 1)") }
        list += (0..<16).map { (i: Int) -> Item in Item(id: 0xC0 + i, name: "DAW \(i + 1)") }
        list += [Item(id: 0x40, name: "Mixer 1 L"), Item(id: 0x41, name: "Mixer 1 R"),
                 Item(id: 0x60, name: "Mixer 2 L"), Item(id: 0x61, name: "Mixer 2 R")]
        return list
    }()

    static let outputs: [Item] = {
        var list = (0..<8).map { (i: Int) -> Item in Item(id: 0x20 + i, name: "Analog Out \(i + 1)") }
        list += (0..<8).map { (i: Int) -> Item in Item(id: 0x28 + i, name: "Optical Out \(i + 1)") }
        return list
    }()

    static let toMac: [Item] = (0..<16).map { Item(id: $0, name: "To Mac \($0 + 1)") }

    static func source(_ id: Int) -> String {
        sources.first { $0.id == id }?.name ?? String(format: "Source 0x%02X", id)
    }

    /// Analog reference level codes. Provisional: from the order of Apogee's name table,
    /// still to be checked against the front panel.
    static let refLevels: [Item] = [Item(id: 0, name: "+4 dBu"), Item(id: 1, name: "−10 dBV"), Item(id: 2, name: "Variable")]

    static let rates: [Int] = [44100, 48000, 88200, 96000]
}
