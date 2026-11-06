import AppKit
import SwiftUI
import ServiceManagement

// All USB operations and the feedback baseline live on one serial queue.
final class LinkWorker {
    let queue = DispatchQueue(label: "local.connect6-link.usb", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var device: Device?
    private var previous: OutputState?
    private var linked = false
    private var mode = LinkMode.relative
    private var nextConnect = Date.distantPast
    var update: ((OutputState?, MobileInputState?, String, Bool) -> Void)?

    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(120), leeway: .milliseconds(15))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func configure(linked: Bool, mode: LinkMode) {
        queue.async {
            self.linked = linked
            self.mode = mode
            self.previous = nil // Arming/mode changes never write to the device.
        }
    }

    private func report(_ state: OutputState?, mobile: MobileInputState?, _ text: String) {
        let linked = self.linked
        DispatchQueue.main.async { self.update?(state, mobile, text, linked) }
    }

    private func failed(_ error: Error) {
        device = nil
        previous = nil
        linked = false
        nextConnect = Date().addingTimeInterval(2)
        report(nil, mobile: nil, String(describing: error))
    }

    private func poll() {
        do {
            if device == nil {
                guard Date() >= nextConnect else { return }
                device = try Device()
                previous = nil
            }
            guard let device else { return }
            let bytes = try device.read()
            let current = OutputState(bytes: bytes)
            let mobile = MobileInputState(bytes: try device.readMixer())
            if linked, let previous {
                let target = LinkEngine.follow(previous: previous, current: current, mode: mode)
                guard let confirmed = try device.apply(target, expected: bytes) else { return }
                let state = OutputState(bytes: confirmed)
                // An untouched leader can keep moving while followers settle.
                // Its later readback is new input, not part of this adjustment.
                self.previous = target
                report(state, mobile: mobile, "CONNECTED · Firmware 2.2.7")
            } else {
                previous = current
                report(current, mobile: mobile, "CONNECTED · Firmware 2.2.7")
            }
        } catch { failed(error) }
    }

    func adjust(source: Int, to raw: Int) {
        perform { current in
            LinkEngine.adjusting(current, source: source, to: raw, linked: self.linked, mode: self.mode)
        }
    }

    func step(_ amount: Int) {
        perform { current in
            var target = current
            target.levels = current.levels.map { LinkEngine.clamp($0 + amount) }
            return target
        }
    }

    func muteAll() {
        perform { current in
            var target = current
            target.mutes = Array(repeating: current.mutes.allSatisfy { $0 == 1 } ? 0 : 1, count: 3)
            return target
        }
    }

    func toggleOutputMute(_ output: Int) {
        perform { $0.togglingMute(output) }
    }

    func activateOutput(_ output: Int) {
        queue.async {
            do {
                guard (0..<3).contains(output), let device = self.device else { return }
                let bytes = try device.read()
                let mapping = UInt8(1 << output)
                guard let confirmed = try device.setNativeVolumeMapping(mapping, expected: bytes) else { return }
                // Preserve the volume feedback baseline: assigning the rocker
                // must not swallow a movement that happened between polls.
                self.previous?.nativeVolumeMapping = mapping
                let mobile = MobileInputState(bytes: try device.readMixer())
                self.report(OutputState(bytes: confirmed), mobile: mobile, "CONNECTED · Firmware 2.2.7")
            } catch { self.failed(error) }
        }
    }

    func adjustMobile(mix: Int, to raw: Int) {
        performMobile { $0.adjusting(mix, to: raw) }
    }

    func toggleMobileMute(_ mix: Int) {
        performMobile { $0.togglingMute(mix) }
    }

    private func performMobile(_ transform: @escaping (MobileInputState) -> MobileInputState) {
        queue.async {
            do {
                guard let device = self.device else { return }
                let bytes = try device.readMixer()
                let target = transform(MobileInputState(bytes: bytes))
                guard let confirmed = try device.applyMobile(target, expected: bytes) else { return }
                // Editing an input must not consume a pending output-knob move.
                let outputs = OutputState(bytes: try device.read())
                self.report(outputs, mobile: MobileInputState(bytes: confirmed), "CONNECTED · Firmware 2.2.7")
            } catch { self.failed(error) }
        }
    }

    private func perform(_ transform: @escaping (OutputState) -> OutputState) {
        queue.async {
            do {
                guard let device = self.device else { return }
                let bytes = try device.read()
                let current = OutputState(bytes: bytes)
                let target = transform(current)
                guard let confirmed = try device.apply(target, expected: bytes) else { return }
                if self.previous != nil && target.levels == current.levels {
                    // Mute-only edits must not swallow unseen volume movements.
                    self.previous?.mutes = target.mutes
                } else {
                    self.previous = target
                }
                let mobile = MobileInputState(bytes: try device.readMixer())
                self.report(OutputState(bytes: confirmed), mobile: mobile, "CONNECTED · Firmware 2.2.7")
            } catch { self.failed(error) }
        }
    }
}

final class AudioModel: ObservableObject {
    @Published var state: OutputState?
    @Published var mobile: MobileInputState?
    @Published var status = "Looking for CONNECT 6…"
    @Published var linked = false { didSet { configure() } }
    @Published var mode: LinkMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "linkMode")
            configure()
        }
    }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var notice: String?
    private let worker = LinkWorker()

    init() {
        // Keep the selected mode when upgrading from the private pre-release ID.
        let savedMode = UserDefaults.standard.string(forKey: "linkMode") ??
            UserDefaults(suiteName: "local.tim.connect6-link")?.string(forKey: "linkMode")
        mode = LinkMode(rawValue: savedMode ?? "") ?? .relative
        if let savedMode { UserDefaults.standard.set(savedMode, forKey: "linkMode") }
        worker.update = { [weak self] state, mobile, status, linked in
            guard let self else { return }
            self.state = state
            self.mobile = mobile
            self.status = status
            if state == nil && !linked && self.linked { self.linked = false }
        }
        configure()
        worker.start()
    }

    private func configure() { worker.configure(linked: linked, mode: mode) }
    func adjust(_ source: Int, _ db: Double) { worker.adjust(source: source, to: Int((db * 256).rounded())) }
    func step(_ db: Int) { worker.step(db * 256) }
    func muteAll() { worker.muteAll() }
    func toggleOutputMute(_ output: Int) { worker.toggleOutputMute(output) }
    func activateOutput(_ output: Int) { worker.activateOutput(output) }
    func adjustMobile(_ mix: Int, _ db: Double) { worker.adjustMobile(mix: mix, to: Int((db * 256).rounded())) }
    func toggleMobileMute(_ mix: Int) { worker.toggleMobileMute(mix) }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            notice = SMAppService.mainApp.status == .requiresApproval ? "Allow CONNECT 6 Link in System Settings → General → Login Items." : nil
        } catch { notice = error.localizedDescription }
    }

    func openControlCenter() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.LewittGmbH.LEWITTCONTROLCENTER") else {
            notice = "LEWITT CONTROL CENTER is not installed. Download it from lewitt-audio.com."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async { self?.notice = error.localizedDescription }
            }
        }
    }
}

struct ControlView: View {
    @ObservedObject var model: AudioModel
    private let names = ["Speakers", "Headphone 1", "Headphone 2"]
    private let icons = ["hifispeaker.fill", "headphones", "headphones"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "link.circle.fill").font(.title).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CONNECT 6 Link").font(.title3.bold())
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Link all three outputs", isOn: $model.linked)
                .toggleStyle(.switch).disabled(model.state == nil)
                .help("Use the hardware knob, CONTROL CENTER, or mapped Mac volume keys to move all three output volumes together.")
            Picker("Link mode", selection: $model.mode) {
                ForEach(LinkMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .help(model.mode == .relative
                 ? "Changing any output moves the others by the same amount. Each stops at −60 or 0 dB."
                 : "The next output you change sets all three to the same dB level.")
            Divider()
            ForEach(0..<3, id: \.self) { i in
                VStack(spacing: 3) {
                    HStack {
                        Label(names[i], systemImage: icons[i])
                        Spacer()
                        Text(model.state.map { String(format: "%.1f dB", Double($0.levels[i]) / 256) } ?? "—")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Button {
                            model.activateOutput(i)
                        } label: {
                            Image(systemName: model.state?.volumeKeyTarget == i ? "keyboard.fill" : "keyboard")
                                .foregroundStyle(model.state?.volumeKeyTarget == i ? .green : .secondary)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.state?.volumeKeyTarget == i ? .green : .gray)
                        .help(model.state?.volumeKeyTarget == i
                              ? "Mac volume keys control \(names[i]). Linked outputs also follow when linking is on."
                              : "Activate \(names[i]): assign the Mac volume keys to this output")
                        .accessibilityLabel("Assign Mac volume keys to \(names[i])")
                        .accessibilityValue(model.state?.volumeKeyTarget == i ? "Active" : "Inactive")
                        .disabled(model.state == nil)
                        MuteButton(name: names[i], muted: model.state?.mutes[i] == 1) {
                            model.toggleOutputMute(i)
                        }.disabled(model.state == nil)
                    }
                    Slider(value: Binding(
                        get: { Double(model.state?.levels[i] ?? -60 * 256) / 256 },
                        set: { model.adjust(i, $0) }
                    ), in: -60...0, step: 0.5)
                    .accessibilityLabel("\(names[i]) volume in decibels")
                    .disabled(model.state == nil)
                }
            }
            HStack {
                Button("−1 dB all") { model.step(-1) }
                Button("+1 dB all") { model.step(1) }
                Spacer()
                MuteButton(name: "all outputs", muted: model.state?.mutes.allSatisfy { $0 == 1 } == true) {
                    model.muteAll()
                }
            }.disabled(model.state == nil)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Mobile in", systemImage: "desktopcomputer").font(.headline)
                    .help("Audio from the computer or phone connected to the Mobile port. These sends are independent of output linking. Moving a slider preserves its mute state.")
                ForEach(0..<2, id: \.self) { mix in
                    VStack(spacing: 3) {
                        HStack {
                            Text(mix == 0 ? "To Mix A" : "To Mix B")
                            Spacer()
                            Text(model.mobile.map { String(format: "%.1f dB", Double($0.levels[mix]) / 256) } ?? "—")
                                .monospacedDigit().foregroundStyle(.secondary)
                            Button {
                                model.adjustMobile(mix, 0)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.bordered)
                            .help("Reset Mobile in to Mix \(mix == 0 ? "A" : "B") to 0 dB (unity gain)")
                            .accessibilityLabel("Reset Mobile in to Mix \(mix == 0 ? "A" : "B") to zero decibels")
                            .disabled(model.mobile == nil || model.mobile?.levels[mix] == 0)
                            MuteButton(name: mix == 0 ? "Mobile in to Mix A" : "Mobile in to Mix B",
                                       muted: model.mobile?.mutes[mix] == 1) {
                                model.toggleMobileMute(mix)
                            }.disabled(model.mobile == nil)
                        }
                        Slider(value: Binding(
                            get: { Double(model.mobile?.levels[mix] ?? -60 * 256) / 256 },
                            set: { model.adjustMobile(mix, $0) }
                        ), in: -60...10, step: 0.5)
                        .accessibilityLabel("Mobile in to Mix \(mix == 0 ? "A" : "B") volume in decibels")
                        .disabled(model.mobile == nil)
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: { _ in model.toggleLogin() }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("CONTROL CENTER") {
                    model.openControlCenter()
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.font(.caption)
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MuteButton: View {
    let name: String
    let muted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .tint(muted ? .red : .gray)
        .accessibilityLabel("\(muted ? "Unmute" : "Mute") \(name)")
        .help("\(muted ? "Unmute" : "Mute") \(name)")
    }
}

@main
struct Connect6LinkApp: App {
    @StateObject private var model = AudioModel()
    var body: some Scene {
        MenuBarExtra("CONNECT 6 Link", systemImage: model.linked ? "link" : "speaker.wave.2") {
            ControlView(model: model)
        }.menuBarExtraStyle(.window)
    }
}
