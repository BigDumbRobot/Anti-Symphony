import SwiftUI

/// Clock along the top, then calibration trims for every analog input and output.
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var cal: Calibration
    @State private var selectedOuts: Set<Int> = Set(3...8)

    var body: some View {
        Form {
            SwiftUI.Section("Clock") {
                Picker("Sample rate", selection: Binding(
                    get: { Int(store.value("/symphony/clock/rate") ?? 0) },
                    set: { store.set("/symphony/clock/rate", Double($0), float: true) })) {
                    ForEach(Names.rates, id: \.self) { Text(String(format: "%.1f kHz", Double($0) / 1000)).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Set through macOS, so it's the same as changing it in Audio MIDI Setup. The clock source (internal, word clock, digital input) is chosen on the Symphony itself: hold one of the rotary encoders.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Picker("Calibration level", selection: $cal.level) {
                    ForEach(Calibration.levels, id: \.self) { Text("\(Int($0)) dBFS").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("+4 dBu (\(String(format: "%.3f", Calibration.toneVolts)) V RMS, 1 kHz) = \(Int(cal.level)) dBFS. Common: −18 (EBU), −20 (SMPTE), −16 and −22 for hotter or quieter studios. Changing the level recalculates every trim; nothing needs measuring again.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Calibration") }

            inputsSection
            outputsSection

            SwiftUI.Section {
                if let s = cal.status { Label(s, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                if let p = cal.problem { Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack {
                    Text("The Symphony Mk1 has no fine trim of its own: trims are applied by Input Processing. The box's coarse level is the +4 dBu / −10 dBV setting; if you change it, measure that channel again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear All", role: .destructive) { cal.clear() }.disabled(cal.running)
                }
            }
        }
        .formStyle(.grouped)
        .wantsMeters()
    }

    private var inputsSection: some View {
        SwiftUI.Section {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Input").foregroundStyle(.secondary)
                    Text("Level").foregroundStyle(.secondary)
                    Text("Reads").foregroundStyle(.secondary)
                    Text("+4 dBu measured at").foregroundStyle(.secondary)
                    Text("Trim").foregroundStyle(.secondary)
                }
                .font(.caption)
                ForEach(1...8, id: \.self) { c in
                    let trim = cal.inputTrim(c)
                    GridRow {
                        Text("Analog In \(c)")
                        InputMeterBar(index: c - 1).frame(width: 110)
                        TrimmedReading(index: c - 1, trim: trim)
                        Text(cal.inputs[c].map { String(format: "%.1f dBFS", 4 - $0.fullScaleDBu) } ?? "not measured")
                            .monospacedDigit().foregroundStyle(cal.inputs[c] == nil ? .secondary : .primary)
                        trimText(trim, stale: cal.inputStale(c))
                    }
                }
            }
            HStack {
                Text("1. Feed a 1 kHz +4 dBu tone into the inputs (one at a time or all at once).\n2. Press Measure Inputs. Inputs with no tone are left as they were.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Measure Inputs") { Task { await cal.measureInputs() } }
                    .disabled(cal.running)
            }
        } header: { Text("Analog inputs") }
    }

    private var outputsSection: some View {
        SwiftUI.Section {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("").gridColumnAlignment(.center)
                    Text("Output").foregroundStyle(.secondary)
                    Text("Level").foregroundStyle(.secondary)
                    Text("Cabled to").foregroundStyle(.secondary)
                    Text("Level at \(Int(cal.level)) dBFS").foregroundStyle(.secondary)
                    Text("Trim").foregroundStyle(.secondary)
                }
                .font(.caption)
                ForEach(1...8, id: \.self) { c in
                    GridRow {
                        Toggle("", isOn: Binding(get: { selectedOuts.contains(c) },
                                                 set: { if $0 { selectedOuts.insert(c) } else { selectedOuts.remove(c) } }))
                            .labelsHidden()
                        Text("Analog Out \(c)")
                        OutputMeter(dest: 0x20 + c - 1).frame(width: 90)
                        Picker("", selection: Binding(get: { cal.loop(c) }, set: { cal.loopback[c] = $0 })) {
                            ForEach(1...8, id: \.self) { Text("In \($0)").tag($0) }
                        }
                        .labelsHidden().frame(width: 80)
                        Text(cal.outputs[c].map { String(format: "%+.1f dBu", $0.fullScaleDBu + cal.level) } ?? "not measured")
                            .monospacedDigit().foregroundStyle(cal.outputs[c] == nil ? .secondary : .primary)
                        trimText(cal.outputTrim(c), stale: cal.outputStale(c))
                    }
                }
            }
            HStack(alignment: .top) {
                Text("Patch each ticked output to an input you've calibrated (default: same number), then press Calibrate Outputs. The app plays the tone, routes it, measures it and puts the routing back. Outputs 1–2 are usually your speakers, so they start unticked.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if cal.running {
                    Button("Stop") { cal.stop() }
                    ProgressView().controlSize(.small)
                } else {
                    Button("Calibrate Outputs") { Task { await cal.measureOutputs(Array(selectedOuts)) } }
                        .disabled(selectedOuts.isEmpty)
                }
            }
        } header: { Text("Analog outputs") } footer: {
            Text("Optical I/O is digital, so it needs no calibration.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func trimText(_ t: Double?, stale: Bool) -> some View {
        HStack(spacing: 4) {
            Text(t.map { String(format: "%+.1f dB", $0) } ?? "—").monospacedDigit()
            if stale {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help("Measured at a different +4 dBu / −10 dBV setting. Measure again.")
            }
        }
    }
}

/// Live input reading with the trim applied (watches the meters on its own).
private struct TrimmedReading: View {
    @EnvironmentObject var meters: Meters
    let index: Int
    let trim: Double?
    var body: some View {
        let now = meters.input[index]
        Text(now <= -119 ? "—" : String(format: "%.1f", now + (trim ?? 0)))
            .monospacedDigit().foregroundStyle(.secondary)
            .help(trim == nil ? "dBFS" : "dBFS, with the trim applied")
    }
}
