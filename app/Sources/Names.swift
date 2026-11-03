import Foundation

/// Routing IDs and names for an 8x8 Analog-Optical board in slot 1 (see docs/protocol.md).
enum Names {
    struct Item: Identifiable, Hashable { let id: Int; let name: String }

    static let none = 0xEC

    /// Headphone mix buses: the box's two hardware mixers (mixer 1 = Bus A, mixer 2 = Bus B).
    /// Source IDs of each bus's left output (right is +1).
    static let busA = 0x40, busB = 0x60
    static func busName(_ mixer: Int) -> String { mixer == 1 ? "Bus A" : "Bus B" }

    static let sources: [Item] = {
        var list = [Item(id: none, name: "None")]
        list += (0..<8).map { (i: Int) -> Item in Item(id: 0x20 + i, name: "Analog In \(i + 1)") }
        list += (0..<8).map { (i: Int) -> Item in Item(id: 0x28 + i, name: "Optical In \(i + 1)") }
        list += (0..<16).map { (i: Int) -> Item in Item(id: 0xC0 + i, name: "DAW \(i + 1)") }
        list += [Item(id: busA, name: "Bus A L"), Item(id: busA + 1, name: "Bus A R"),
                 Item(id: busB, name: "Bus B L"), Item(id: busB + 1, name: "Bus B R")]
        return list
    }()

    static let outputs: [Item] = {
        var list = (0..<8).map { (i: Int) -> Item in Item(id: 0x20 + i, name: "Analog Out \(i + 1)") }
        list += (0..<8).map { (i: Int) -> Item in Item(id: 0x28 + i, name: "Optical Out \(i + 1)") }
        return list
    }()

    /// Output pairs a headphone can mirror, by the left channel's destination ID.
    static let outputPairs: [Item] = {
        var list = (0..<4).map { (i: Int) -> Item in Item(id: 0x20 + 2 * i, name: "Analog Out \(2 * i + 1)–\(2 * i + 2)") }
        list += (0..<4).map { (i: Int) -> Item in Item(id: 0x28 + 2 * i, name: "Optical Out \(2 * i + 1)–\(2 * i + 2)") }
        return list
    }()

    /// Stereo source pairs a headphone can take directly, by the left channel's source ID.
    static let sourcePairs: [Item] = {
        var list = (0..<8).map { (i: Int) -> Item in Item(id: 0xC0 + 2 * i, name: "DAW \(2 * i + 1)–\(2 * i + 2)") }
        list = [Item(id: busA, name: "Bus A"), Item(id: busB, name: "Bus B")] + list
        list += (0..<4).map { (i: Int) -> Item in Item(id: 0x20 + 2 * i, name: "Analog In \(2 * i + 1)–\(2 * i + 2)") }
        list += (0..<4).map { (i: Int) -> Item in Item(id: 0x28 + 2 * i, name: "Optical In \(2 * i + 1)–\(2 * i + 2)") }
        return list
    }()

    /// Headphone feed destinations (left; right is +1).
    static func headphoneFeed(_ h: Int) -> Int { 0xE0 + 2 * (h - 1) }

    /// The 16 channels the Mac records (destinations 0xD0-0xDF).
    static let toMac: [Item] = (0..<16).map { Item(id: 0xD0 + $0, name: "To Mac \($0 + 1)") }

    static func source(_ id: Int) -> String {
        sources.first { $0.id == id }?.name ?? String(format: "Source 0x%02X", id)
    }

    /// Analog reference level codes, measured through a loopback cable (tests/hwtest.py):
    /// code 1 and 2 are 11.7 dB apart (the +4 dBu / −10 dBV difference). On inputs code 0 isn't a
    /// level (it keeps the previous one); on outputs it's the box's power-on default, 3 dB under +4 dBu.
    static let inputRefLevels: [Item] = [Item(id: 2, name: "+4 dBu"), Item(id: 1, name: "−10 dBV")]
    static let outputRefLevels: [Item] = [Item(id: 2, name: "+4 dBu"), Item(id: 1, name: "−10 dBV"),
                                          Item(id: 0, name: "Default (+1 dBu)")]

    static let rates: [Int] = [44100, 48000, 88200, 96000]
}
