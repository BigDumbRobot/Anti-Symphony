import CoreAudio
import Foundation

/// Plays a sine on one output channel of the Symphony through Core Audio (calibration tone).
/// Other apps keep playing; Core Audio mixes them.
final class ToneOut {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var rate = 48000.0
    // Read by the audio thread; set before start, only changed while stopped.
    private var channel = 0, freq = 1000.0, amp = 0.0, phase = 0.0

    /// The Symphony's Core Audio device, by name.
    static func symphonyDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &n, &name) == noErr,
               let s = name?.takeRetainedValue() as String?, s.localizedCaseInsensitiveContains("Symphony") {
                return id
            }
        }
        return nil
    }

    /// Starts a tone on output channel `ch` (1-based) at `dbfs` (sine peak, so −18 dBFS reads −18 on the meters).
    func start(channel ch: Int, dbfs: Double, hz: Double = 1000) throws {
        stop()
        guard let dev = Self.symphonyDevice() else { throw CalibrationError("The Symphony isn't available as a Core Audio device.") }
        device = dev
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r = Float64(0); var n = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(dev, &rateAddr, 0, nil, &n, &r) == noErr, r > 0 { rate = r }
        channel = ch - 1; freq = hz; amp = pow(10, dbfs / 20); phase = 0

        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, dev, nil) { [unowned self] _, _, _, outData, _ in
            let list = UnsafeMutableAudioBufferListPointer(outData)
            guard let b = list.first, let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let chans = Int(max(b.mNumberChannels, 1)), frames = Int(b.mDataByteSize) / 4 / chans
            memset(p, 0, Int(b.mDataByteSize))
            guard self.channel < chans else { return }
            let step = 2 * Double.pi * self.freq / self.rate
            var ph = self.phase
            for f in 0..<frames {
                p[f * chans + self.channel] = Float(self.amp * sin(ph))
                ph += step
                if ph > 2 * .pi { ph -= 2 * .pi }
            }
            self.phase = ph
        }
        guard status == noErr, let id else { throw CalibrationError("Couldn't open the Symphony for playback (\(status)).") }
        proc = id
        AudioDeviceStart(dev, id)
    }

    func stop() {
        guard let p = proc else { return }
        AudioDeviceStop(device, p)
        AudioDeviceDestroyIOProcID(device, p)
        proc = nil
    }

    deinit { stop() }
}

struct CalibrationError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
