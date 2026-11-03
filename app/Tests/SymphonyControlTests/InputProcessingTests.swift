import XCTest
@testable import SymphonyControl

/// Input Processing page logic: slots, mono/stereo plugin versions, linking, settings carry-over,
/// bypass and saving. Uses a temporary file and a fixed plugin list, never the real setup.
@MainActor
final class InputProcessingTests: XCTestCase {
    typealias P = InputProcessing.Plugin
    let cla76m = P(type: 1, subType: 10, manufacturer: 7, name: "CLA-76 Mono", vendor: "Waves")
    let cla76s = P(type: 1, subType: 11, manufacturer: 7, name: "CLA-76 Stereo", vendor: "Waves")
    let api550m = P(type: 1, subType: 20, manufacturer: 7, name: "API-550A (m)", vendor: "Waves")
    let api550s = P(type: 1, subType: 21, manufacturer: 7, name: "API-550A (s)", vendor: "Waves")
    let spider = P(type: 1, subType: 30, manufacturer: 9, name: "Pink Spider-DMP", vendor: "Anti-Music")
    var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ip-test-\(UUID().uuidString).json")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: url) }

    func make() -> InputProcessing {
        InputProcessing(url: url, plugins: [cla76m, cla76s, api550m, api550s, spider])
    }

    func testStartsEmpty() {
        let p = make()
        XCTAssertEqual(p.channels.count, 16)
        XCTAssertTrue(p.channels.allSatisfy { $0.slots.count == 4 && $0.slots.allSatisfy { $0.plugin == nil } })
        XCTAssertTrue(p.linked.isEmpty)
    }

    func testChannelNames() {
        XCTAssertEqual(InputProcessing.name(1), "Analog 1")
        XCTAssertEqual(InputProcessing.name(9), "Optical 1")
        XCTAssertEqual(InputProcessing.pairName(7), "Analog 7–8")
        XCTAssertEqual(InputProcessing.pairName(15), "Optical 7–8")
    }

    func testBaseNames() {
        XCTAssertEqual(InputProcessing.baseName("CLA-76 Mono").base, "CLA-76")
        XCTAssertEqual(InputProcessing.baseName("CLA-76 Mono").width, .mono)
        XCTAssertEqual(InputProcessing.baseName("API-550A (s)").width, .stereo)
        XCTAssertNil(InputProcessing.baseName("Pink Spider-DMP").width)
    }

    func testMonoChannelGetsMonoVersion() {
        let p = make()
        p.setPlugin(cla76s, channel: 3, slot: 0)          // picking the stereo version on a mono channel
        XCTAssertEqual(p.channels[2].slots[0].plugin, cla76m)
        XCTAssertNil(p.channels[3].slots[0].plugin, "other channel untouched")
    }

    func testLinkSwapsToStereoAndCopiesSettings() {
        let p = make()
        p.setPlugin(cla76m, channel: 1, slot: 0)
        p.setPlugin(api550m, channel: 1, slot: 1)
        p.setPlugin(spider, channel: 1, slot: 2)
        let settings = Data([1, 2, 3])
        p.setState(settings, channel: 1, slot: 0)
        p.setLinked(1, true)
        XCTAssertTrue(p.isLinked(1) && p.isLinked(2))
        for ch in [0, 1] {
            XCTAssertEqual(p.channels[ch].slots[0].plugin, cla76s)
            XCTAssertEqual(p.channels[ch].slots[1].plugin, api550s)
            XCTAssertEqual(p.channels[ch].slots[2].plugin, spider, "plugins that handle both widths stay")
            XCTAssertEqual(p.channels[ch].slots[0].state, settings, "settings carried to the stereo version")
        }
    }

    func testUnlinkSwapsBackAndKeepsSettings() {
        let p = make()
        p.setLinked(5, true)
        p.setPlugin(cla76m, channel: 6, slot: 3)          // edit through the right channel of a pair
        XCTAssertEqual(p.channels[4].slots[3].plugin, cla76s)
        let settings = Data([9, 9])
        p.setState(settings, channel: 5, slot: 3)
        p.setLinked(5, false)
        for ch in [4, 5] {
            XCTAssertEqual(p.channels[ch].slots[3].plugin, cla76m)
            XCTAssertEqual(p.channels[ch].slots[3].state, settings)
        }
        XCTAssertFalse(p.isLinked(5))
    }

    func testLinkKeepsRightChannelPluginWhenLeftEmpty() {
        let p = make()
        p.setPlugin(api550m, channel: 2, slot: 0)
        p.setLinked(1, true)
        XCTAssertEqual(p.channels[0].slots[0].plugin, api550s)
    }

    func testOnlyOddChannelsStartPairs() {
        let p = make()
        p.setLinked(2, true)
        p.setLinked(16, true)
        XCTAssertTrue(p.linked.isEmpty)
    }

    func testBypassAndClearFollowThePair() {
        let p = make()
        p.setLinked(9, true)
        p.setPlugin(spider, channel: 9, slot: 0)
        p.toggleBypass(channel: 10, slot: 0)
        XCTAssertTrue(p.channels[8].slots[0].bypass && p.channels[9].slots[0].bypass)
        p.setPlugin(nil, channel: 9, slot: 0)
        XCTAssertNil(p.channels[8].slots[0].plugin)
        XCTAssertNil(p.channels[9].slots[0].plugin)
    }

    func testSavedAndReloaded() {
        let p = make()
        p.setLinked(3, true)
        p.setPlugin(cla76m, channel: 3, slot: 1)
        p.setState(Data([4, 2]), channel: 3, slot: 1)
        p.setPlugin(spider, channel: 12, slot: 0)
        let q = make()
        XCTAssertEqual(q.linked, [3])
        XCTAssertEqual(q.channels[2].slots[1].plugin, cla76s)
        XCTAssertEqual(q.channels[3].slots[1].state, Data([4, 2]))
        XCTAssertEqual(q.channels[11].slots[0].plugin, spider)
    }

    /// This Mac's plugins are found, and a real plugin with mono/stereo versions pairs up.
    func testRealPluginsOnThisMac() {
        let p = InputProcessing(url: url)
        XCTAssertFalse(p.available.isEmpty, "no Audio Units found")
        if let m = p.available.first(where: { InputProcessing.baseName($0.name).width == .mono }) {
            let s = p.variant(of: m, .stereo)
            XCTAssertNotEqual(s, m, "\(m.name) has no stereo version found")
            XCTAssertEqual(p.variant(of: s, .mono), m)
        }
    }
}
