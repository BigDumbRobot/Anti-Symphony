import AVFoundation
import AppKit
import AudioToolbox
import CoreAudioKit

/// Opens a slot's plugin in its own window (the plugin's own interface) and saves its settings
/// back to the slot when they change or the window closes.
@MainActor
final class PluginWindows: NSObject, NSWindowDelegate {
    static let shared = PluginWindows()

    private struct Open {
        let window: NSWindow
        let unit: AVAudioUnit
        let channel: Int, slot: Int
    }
    private var open: [ObjectIdentifier: Open] = [:]
    private var saveTimer: Timer?

    func show(_ proc: InputProcessing, channel ch: Int, slot i: Int, title: String) {
        if let existing = open.values.first(where: { $0.channel == ch && $0.slot == i }) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let s = proc.channels[ch - 1].slots[i]
        guard let p = s.plugin else { return }
        let desc = AudioComponentDescription(componentType: p.type, componentSubType: p.subType,
                                             componentManufacturer: p.manufacturer, componentFlags: 0, componentFlagsMask: 0)
        AVAudioUnit.instantiate(with: desc, options: []) { unit, error in
            DispatchQueue.main.async {
                guard let unit else {
                    proc.problem = "\(p.name) didn't load: \(error?.localizedDescription ?? "unknown error")"
                    return
                }
                if let data = s.state,
                   let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    unit.auAudioUnit.fullState = state
                }
                Self.view(for: unit) { view in
                    self.present(view ?? Self.genericView(unit), unit: unit, proc: proc, channel: ch, slot: i,
                                 title: "\(title) · Insert \(i + 1) · \(p.name)")
                }
            }
        }
    }

    private func present(_ view: NSView, unit: AVAudioUnit, proc: InputProcessing, channel: Int, slot: Int, title: String) {
        let size = view.frame.size.width > 10 ? view.frame.size : NSSize(width: 600, height: 400)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        open[ObjectIdentifier(w)] = Open(window: w, unit: unit, channel: channel, slot: slot)
        weakProc = proc
        // Plugins don't announce every change, so save their settings every couple of seconds while open.
        if saveTimer == nil {
            saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveAll() }
            }
        }
    }

    private weak var weakProc: InputProcessing?

    private func save(_ o: Open) {
        guard let proc = weakProc, let state = o.unit.auAudioUnit.fullState,
              let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) else { return }
        proc.setState(data, channel: o.channel, slot: o.slot)
    }

    private func saveAll() { open.values.forEach(save) }

    nonisolated func windowWillClose(_ n: Notification) {
        MainActor.assumeIsolated {
            guard let w = n.object as? NSWindow, let o = open.removeValue(forKey: ObjectIdentifier(w)) else { return }
            save(o)
            if open.isEmpty { saveTimer?.invalidate(); saveTimer = nil }
        }
    }

    /// The plugin's own interface: Audio Unit v3 view controller, or the v2 Cocoa view.
    private static func view(for unit: AVAudioUnit, done: @escaping (NSView?) -> Void) {
        if let v = cocoaView(unit.audioUnit) { done(v); return }
        unit.auAudioUnit.requestViewController { vc in
            DispatchQueue.main.async {
                guard let vc else { done(nil); return }
                let v = vc.view
                if v.frame.width < 10 { v.frame.size = vc.preferredContentSize.width > 10 ? vc.preferredContentSize : NSSize(width: 600, height: 400) }
                done(v)
            }
        }
    }

    /// Audio Unit v2 Cocoa interface (kAudioUnitProperty_CocoaUI): load its bundle and ask its factory.
    private static func cocoaView(_ au: AudioUnit) -> NSView? {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr,
              size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { raw.deallocate() }
        guard AudioUnitGetProperty(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }
        let info = raw.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee
        let bundleURL = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String
        guard let bundle = Bundle(url: bundleURL), bundle.load(),
              let cls = bundle.classNamed(className) as? NSObject.Type else { return nil }
        let factory = cls.init()
        let sel = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard factory.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> NSView?
        let fn = unsafeBitCast(factory.method(for: sel), to: Fn.self)
        return fn(factory, sel, au, NSSize(width: 600, height: 400))
    }

    /// Apple's generic sliders, for plugins with no interface of their own.
    private static func genericView(_ unit: AVAudioUnit) -> NSView {
        let v = AUGenericView(audioUnit: unit.audioUnit)
        v.showsExpertParameters = true
        return v
    }
}
