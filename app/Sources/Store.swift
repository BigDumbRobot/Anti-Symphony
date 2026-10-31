import Foundation
import SwiftUI

/// Live copy of the Symphony's settings, kept in sync with symphonyd over OSC.
/// Everything runs on the main queue.
final class Store: ObservableObject {
    @Published private(set) var values: [String: Double] = [:]
    @Published private(set) var daemonReachable = false
    @Published private(set) var boxConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var profiles: [String] = []
    @Published private(set) var lastProfile: String?
    @Published private(set) var notice: String?

    private let client = OSCClient(host: "127.0.0.1", port: 7100)
    private var lastHeard = Date.distantPast
    private var localEdits: [String: Date] = [:]
    private var timer: Timer?
    private var volumeKeys: VolumeKeys?

    init() {
        client.onMessage = { [weak self] in self?.handle($0) }
        client.restart()
        subscribe()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        volumeKeys = VolumeKeys(store: self)
    }

    // MARK: sync

    private var lastSubscribe = Date.distantPast

    private func subscribe() {
        lastSubscribe = Date()
        client.send(OSCMessage(path: "/symphony/subscribe"))
    }

    private func tick() {
        let quiet = Date().timeIntervalSince(lastHeard)
        if quiet > 25 {
            if daemonReachable { daemonReachable = false; boxConnected = false }
            client.restart()            // symphonyd may have restarted
            subscribe()
        } else if Date().timeIntervalSince(lastSubscribe) > 20 {
            subscribe()
        }
    }

    private func handle(_ m: OSCMessage) {
        lastHeard = Date()
        if !daemonReachable { daemonReachable = true }
        switch m.path {
        case "/symphony/connected":
            boxConnected = (m.args.first?.double ?? 0) != 0
        case "/symphony/profiles":
            if case .string(let names)? = m.args.first {
                profiles = names.split(separator: "\n").map(String.init)
            }
        case "/symphony/profile/saved", "/symphony/profile/loaded":
            if case .string(let name)? = m.args.first {
                lastProfile = name
                notice = m.path.hasSuffix("saved") ? "Saved profile \u{201C}\(name)\u{201D}" : "Loaded profile \u{201C}\(name)\u{201D}"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.notice = nil }
            }
        case "/symphony/error":
            if case .string(let path)? = m.args.first, case .string(let why)? = m.args.dropFirst().first {
                lastError = "\(path): \(why)"
            }
        default:
            guard let v = m.args.first?.double else { return }
            // While a control is being dragged, ignore the echo of our own changes.
            if let t = localEdits[m.path], Date().timeIntervalSince(t) < 0.6 { return }
            if values[m.path] != v { values[m.path] = v }
        }
    }

    // MARK: access

    func value(_ path: String) -> Double? { values[path] }

    func set(_ path: String, _ v: Double, float: Bool) {
        values[path] = v
        localEdits[path] = Date()
        client.send(OSCMessage(path: path, args: [float ? .float(Float(v)) : .int(Int32(v.rounded()))]))
    }

    func send(_ path: String, _ args: [OSCValue] = []) {
        client.send(OSCMessage(path: path, args: args))
    }

    func clearError() { lastError = nil }

    // MARK: profiles

    func saveProfile(_ name: String) { send("/symphony/profile/save", [.string(name)]) }
    func loadProfile(_ name: String) { send("/symphony/profile/load", [.string(name)]) }
    func deleteProfile(_ name: String) { send("/symphony/profile/delete", [.string(name)]) }

    /// Same rule as symphonyd: 1-64 letters, digits, spaces or - _ . ( ).
    static func isValidProfileName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.()"))
        return !name.isEmpty && name.count <= 64 && !name.hasPrefix(".") && !name.hasPrefix(" ")
            && name.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }

    func level(_ path: String, default d: Double = -64) -> Binding<Double> {
        Binding(get: { self.values[path] ?? d }, set: { self.set(path, $0.rounded(), float: true) })
    }

    func number(_ path: String, default d: Double = 0) -> Binding<Double> {
        Binding(get: { self.values[path] ?? d }, set: { self.set(path, $0, float: true) })
    }

    func flag(_ path: String) -> Binding<Bool> {
        Binding(get: { (self.values[path] ?? 0) != 0 }, set: { self.set(path, $0 ? 1 : 0, float: false) })
    }

    func choice(_ path: String) -> Binding<Int> {
        Binding(get: { Int(self.values[path] ?? -1) }, set: { self.set(path, Double($0), float: false) })
    }
}
