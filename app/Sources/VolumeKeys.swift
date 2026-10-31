import AppKit
import CoreAudio
import ServiceManagement

/// Mac volume keys -> Symphony main out level, while the Symphony is the Mac's sound output.
///
/// The Symphony has no USB volume control, so macOS can't change its level itself (the volume
/// slider is greyed out and the keys show "not available"). Apogee's software had a "keyboard
/// volume control" option for this; this is the same idea. Keys are observed, not intercepted.
final class VolumeKeys {
    private weak var store: Store?
    private var monitors: [Any] = []
    private let hud = LevelHUD()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "volumeKeys") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "volumeKeys") }
    }

    init(store: Store) {
        self.store = store
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(m)
        }
    }

    // NX_SYSDEFINED media key events: subtype 8, key code in the top half of data1.
    private func handle(_ e: NSEvent) {
        guard VolumeKeys.enabled, e.subtype.rawValue == 8, let store, store.boxConnected else { return }
        let code = (e.data1 & 0xFFFF0000) >> 16
        let isDown = ((e.data1 & 0xFF00) >> 8) == 0x0A
        guard isDown, [0, 1, 7].contains(code), VolumeKeys.symphonyIsDefaultOutput() else { return }
        let fine = e.modifierFlags.contains(.shift) && e.modifierFlags.contains(.option)
        let step = fine ? 1.0 : 3.0
        let level = "/symphony/monitor/main/level", mute = "/symphony/monitor/main/mute"
        var newLevel = store.value(level) ?? -64
        var muted = (store.value(mute) ?? 0) != 0
        switch code {
        case 0:  // volume up
            newLevel = min(0, newLevel + step)
            store.set(level, newLevel, float: true)
            if muted { store.set(mute, 0, float: false); muted = false }
        case 1:  // volume down
            newLevel = max(-64, newLevel - step)
            store.set(level, newLevel, float: true)
        default: // mute
            muted.toggle()
            store.set(mute, muted ? 1 : 0, float: false)
        }
        hud.show(level: newLevel, muted: muted)
    }

    static func symphonyIsDefaultOutput() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
        addr.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return false }
        return (n as String).contains("Symphony")
    }
}

/// Small on-screen level indicator shown after a volume key press.
final class LevelHUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    func show(level: Double, muted: Bool) {
        if panel == nil { build() }
        label?.stringValue = muted ? "Symphony  ·  Muted" : String(format: "Symphony  ·  %@%.0f dB", level < 0 ? "−" : "", abs(level))
        if let screen = NSScreen.main, let p = panel {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 120))
        }
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.panel?.animator().alphaValue = 0
            } completionHandler: { self?.panel?.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 48), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        l.alignment = .center
        l.frame = bg.bounds.insetBy(dx: 10, dy: 13)
        bg.addSubview(l)
        p.contentView = bg
        panel = p
        label = l
    }
}

/// "Open at login" for the app (macOS 13+ login items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Symphony Control: login item change failed: \(error)") }
    }
}
