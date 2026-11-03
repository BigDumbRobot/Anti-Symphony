import Foundation

/// Levels for anything the box can route, from the input meters (the box sends no output meters).
///
/// - Board inputs: measured.
/// - Bus A / Bus B outputs: estimated from the mixer settings and the measured input levels
///   (power sum, −3 dB pan law, mute/solo, master). DAW channels feeding a bus aren't measured,
///   so they don't count.
/// - DAW channels: not measured yet (nil).
enum Levels {
    static let silent = -120.0

    static func source(_ id: Int, store: Store, meters: Meters) -> Double? {
        if let db = meters.level(forSource: id) { return db }
        for (mixer, base) in [(1, Names.busA), (2, Names.busB)] where id == base || id == base + 1 {
            return bus(mixer, right: id == base + 1, store: store, meters: meters)
        }
        return nil
    }

    /// Level of an output destination (board output, headphone feed...), from what feeds it.
    static func destination(_ dest: Int, store: Store, meters: Meters) -> Double? {
        guard let src = store.value("/symphony/route/\(dest)") else { return nil }
        return source(Int(src), store: store, meters: meters)
    }

    static func bus(_ mixer: Int, right: Bool, store: Store, meters: Meters) -> Double? {
        let base = "/symphony/mixer/\(mixer)"
        let firstInput = mixer == 1 ? 0x40 : 0x60
        let anySolo = (1...16).contains { (store.value("\(base)/in/\($0)/solo") ?? 0) != 0 }
        var power = 0.0, measured = false
        for i in 1...16 {
            let p = "\(base)/in/\(i)"
            guard let src = store.value("/symphony/route/\(firstInput + i - 1)"),
                  let db = meters.level(forSource: Int(src)) else { continue }
            measured = true
            if (store.value("\(p)/mute") ?? 0) != 0 { continue }
            if anySolo && (store.value("\(p)/solo") ?? 0) == 0 { continue }
            let fader = store.value("\(p)/fader") ?? 0
            if fader <= -48 || db <= silent + 1 { continue }
            let theta = ((store.value("\(p)/pan") ?? 0) + 1) * .pi / 4
            let g = right ? sin(theta) : cos(theta)
            power += pow(10, (db + fader) / 10) * g * g
        }
        guard measured else { return nil }
        let master = store.value("\(base)/master/fader") ?? 0
        if power <= 0 || master <= -48 || (store.value("\(base)/master/mute") ?? 0) != 0 { return silent }
        return 10 * log10(power) + master
    }
}
