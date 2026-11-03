import XCTest
@testable import SymphonyControl

/// MAIN / ALT / MINI and QUAD / 5.1 / 7.1, against a fake box that records every write.
@MainActor
final class SpeakersTests: XCTestCase {
    var box: [String: Double] = [:]
    var writes: [(String, Double)] = []
    var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("spk-\(UUID().uuidString).json")
        box = ["/symphony/monitor/main/mode": 2, "/symphony/monitor/main/mute": 1, "/symphony/monitor/main/dim": 0]
        for d in 0x20...0x2F { box["/symphony/route/\(d)"] = Double(0xC0 + d - 0x20) }   // Out n <- DAW n
        writes = []
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: url) }

    func make() -> Speakers {
        Speakers(value: { [unowned self] in self.box[$0] },
                 send: { [unowned self] p, v, _ in self.box[p] = v; self.writes.append((p, v)) },
                 url: url)
    }
    func route(_ d: Int) -> Int { Int(box["/symphony/route/\(d)"] ?? -1) }
    let none = Names.none

    func testMainPlaysSourceOnItsPair() {
        let s = make()
        s.assign(.main, 0x22)                 // Analog Out 3–4
        XCTAssertEqual(s.mode, .main)
        XCTAssertEqual(route(0x22), 0xC0)
        XCTAssertEqual(route(0x23), 0xC1)
        XCTAssertEqual(box["/symphony/monitor/main/mode"], 5, "Out 3–4 needs the 1–6 layout for the main level")
    }

    func testAltAndMiniExcludeOtherPairs() {
        let s = make()
        s.assign(.alt, 0x22)
        XCTAssertFalse(s.choices(for: .mini).contains { $0.id == 0x20 || $0.id == 0x22 })
        XCTAssertFalse(s.choices(for: .main).contains { $0.id == 0x22 })
        s.assign(.mini, 0x22)                 // taken by ALT: refused
        XCTAssertNil(s.mini)
        s.assign(.mini, 0x24)
        XCTAssertEqual(s.mini, 0x24)
    }

    func testSwitchingSilencesThePreviousPairOnly() {
        let s = make()
        s.select(.main)
        s.assign(.alt, 0x26)                  // Out 7–8
        s.select(.alt)
        XCTAssertEqual(route(0x26), 0xC0)
        XCTAssertEqual(route(0x27), 0xC1)
        XCTAssertEqual(route(0x20), none)
        XCTAssertEqual(route(0x21), none)
        XCTAssertEqual(route(0x24), 0xC4, "outputs never used here are left alone")
        XCTAssertEqual(box["/symphony/monitor/main/mode"], 6)
    }

    func testOffSlotsCantBeSelected() {
        let s = make()
        XCTAssertFalse(s.isAvailable(.alt))
        s.select(.alt)
        XCTAssertEqual(s.mode, .main)
        s.assign(.alt, 0x22); s.select(.alt); s.assign(.alt, nil)
        XCTAssertEqual(s.mode, .main, "turning off the active slot goes back to MAIN")
    }

    func testQuad51And71() {
        let s = make()
        s.setSurroundStart(0xC8)              // DAW 9–16
        s.select(.quad)
        XCTAssertEqual([0x20, 0x21, 0x26, 0x27].map(route), [0xC8, 0xC9, 0xCA, 0xCB], "fronts on Out 1–2, rears on Out 7–8")
        XCTAssertEqual(route(0x22), 0xC2, "Out 3–6 untouched by QUAD")
        XCTAssertEqual(box["/symphony/monitor/main/mode"], 6, "rears on Out 7–8 need the 1–8 layout")
        XCTAssertTrue(s.notice!.contains("Out 1–2") && s.notice!.contains("Out 7–8"))
        s.select(.surround51)
        XCTAssertEqual((0..<6).map { route(0x20 + $0) }, Array(0xC8...0xCD))
        XCTAssertEqual([0x26, 0x27].map(route), [none, none], "QUAD's rears cleared when 5.1 doesn't use them")
        XCTAssertEqual(box["/symphony/monitor/main/mode"], 5)
        s.select(.surround71)
        XCTAssertEqual((0..<8).map { route(0x20 + $0) }, Array(0xC8...0xCF))
        XCTAssertEqual(box["/symphony/monitor/main/mode"], 6)
    }

    func testStereoButtonCollapsesSurround() {
        let s = make()
        s.select(.surround51)
        s.select(.main)
        XCTAssertEqual(route(0x20), 0xC0)
        XCTAssertEqual(route(0x21), 0xC1)
        XCTAssertEqual((2..<6).map { route(0x20 + $0) }, Array(repeating: none, count: 4))
        XCTAssertEqual(box["/symphony/monitor/main/mode"], 2)
        XCTAssertEqual(route(0x26), 0xC6, "7.1 never ran, so Out 7–8 untouched")
    }

    func testLayoutChangeKeepsMuteAndDim() {
        let s = make()
        box["/symphony/monitor/main/dim"] = 1
        s.select(.surround71)
        XCTAssertEqual(box["/symphony/monitor/main/mute"], 1)
        XCTAssertEqual(box["/symphony/monitor/main/dim"], 1)
        let modeWrite = writes.firstIndex { $0.0 == "/symphony/monitor/main/mode" }!
        let muteWrite = writes.lastIndex { $0.0 == "/symphony/monitor/main/mute" }!
        XCTAssertGreaterThan(muteWrite, modeWrite, "mute is put back after the layout change")
    }

    func testSavedAndReloaded() {
        let s = make()
        s.assign(.alt, 0x24); s.assign(.mini, 0x2A); s.setSource(0x40); s.select(.mini)
        let t = make()
        XCTAssertEqual(t.alt, 0x24); XCTAssertEqual(t.mini, 0x2A); XCTAssertEqual(t.source, 0x40); XCTAssertEqual(t.mode, .mini)
        t.select(.main)                       // remembers it drove the MINI pair
        XCTAssertEqual(route(0x2A), none)
    }
}
