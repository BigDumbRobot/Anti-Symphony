import Foundation
import SwiftUI

/// Live copy of the Symphony's settings, kept in sync with symphonyd over OSC.
/// Everything runs on the main queue.
final class Store: ObservableObject {
    @Published private(set) var values: [String: Double] = [:]
    @Published private(set) var daemonReachable = false
    @Published private(set) var boxConnected = false
    @Published private(set) var lastError: String?

    private let client = OSCClient(host: "127.0.0.1", port: 7100)
    private var lastHeard = Date.distantPast
    private var localEdits: [String: Date] = [:]
    private var timer: Timer?

    init() {
        client.onMessage = { [weak self] in self?.handle($0) }
        client.restart()
        subscribe()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
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
