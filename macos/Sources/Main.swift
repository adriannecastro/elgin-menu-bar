import AppKit
import SwiftUI
import Darwin
import Combine

private let accent = Color.accentColor
private let surface = Color.primary.opacity(0.06)
private let lampPalette: [(name: String, color: Color)] = [
    ("Vermelha", Color(red: 1, green: 0, blue: 0)),
    ("Coral", Color(red: 1, green: 0.30, blue: 0.20)),
    ("Laranja", .orange),
    ("Âmbar", Color(red: 1, green: 0.65, blue: 0.15)),
    ("Amarela", .yellow),
    ("Lima", Color(red: 0.65, green: 1, blue: 0)),
    ("Verde", Color(red: 0, green: 1, blue: 0)),
    ("Esmeralda", Color(red: 0, green: 0.8, blue: 0.35)),
    ("Menta", Color(red: 0.35, green: 1, blue: 0.70)),
    ("Turquesa", Color(red: 0, green: 0.85, blue: 0.75)),
    ("Ciano", Color(red: 0, green: 1, blue: 1)),
    ("Azul", Color(red: 0, green: 0.25, blue: 1)),
    ("Índigo", Color(red: 0.30, green: 0.10, blue: 1)),
    ("Violeta", Color(red: 0.55, green: 0.15, blue: 1)),
    ("Roxa", .purple),
    ("Rosa", .pink),
    ("Magenta", Color(red: 1, green: 0, blue: 1)),
    ("Branca", .white)
]


final class MenuChoice: NSObject {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    @objc func select() { callback() }
}

// Preserve known values on a failed read, while marking them as stale and disabling writes.
func mergeSnapshot(_ previous: [String: Any], _ response: [String: Any]?) -> [String: Any] {
    var merged = previous
    var incoming = response ?? ["ac_connected": false, "lamp_connected": false,
        "ac": ["connected": false], "lamp": ["connected": false],
        "error": "Falha na leitura. Tentando reconectar…"]
    for role in ["ac", "lamp"] {
        if let current = incoming[role] as? [String: Any], current["connected"] as? Bool == false {
            var retained = previous[role] as? [String: Any] ?? current
            retained["connected"] = false
            incoming[role] = retained
            if role == "ac" { incoming["temperature"] = previous["temperature"] }
        }
    }
    merged.merge(incoming) { _, new in new }
    return merged
}

final class DemoState: ObservableObject {
    @Published var live = true
    @Published var acConnected = false
    @Published var lampConnected = false
    @Published var busy = false
    @Published var commandPending = false
    private var activeProcess: Process?
    private var activeRequest = UUID()
    private var lastResult: [String: Any] = [:]
    @Published var requestedTemperature: Double?
    @Published var message = "Conectando aos aparelhos…"
    @Published var acCapabilities: [String: [String: Any]] = [:]
    @Published var lampCapabilities: [String: [String: Any]] = [:]
    @Published var ambient: Double?
    @Published var minTemperature = 25.0
    @Published var maxTemperature = 27.0
    @Published var lampMode = "white"
    @Published var whiteTemperature = 1.0
    @Published var editingBrightness = false
    @Published var editingHue = false
    @Published var editingWhiteTemperature = false
    @Published var editingTemperature = false
    @Published var temperatureUnit = "C"
    var lampTint: Color {
        lampMode == "white" ? Color(red: 1, green: 0.78 + 0.22 * whiteTemperature, blue: 0.45 + 0.55 * whiteTemperature) : lightColor
    }
    @Published var draftTemperature = 27.0
    func canControl(_ role: String, _ control: String) -> Bool {
        if !live { return true }
        let connected = role == "ac" ? acConnected : lampConnected
        if role == "ac" && control == "temperature" && temperatureUnit != "C" { return false }
        return connected && !commandPending && (role == "ac" ? acCapabilities : lampCapabilities)[control] != nil
    }
    func options(_ role: String, _ control: String) -> [String] {
        (role == "ac" ? acCapabilities : lampCapabilities)[control]?["options"] as? [String] ?? []
    }
    func setControl(_ role: String, _ control: String, _ value: Any) {
        guard live else { return }
        guard canControl(role, control), let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        request(["set", role, control, json])
    }
    func chooseColor(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        setControl("lamp", "color", ["h": h, "s": s, "v": max(0.01, brightness / 100)])
    }
    func chooseHue() {
        setControl("lamp", "color", ["h": hue, "s": 1.0, "v": max(0.01, brightness / 100)])
    }
    var onUpdate: (() -> Void)?
    private let queue = DispatchQueue(label: "elgin.local.connection")
    private var timer: Timer?
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    init(live: Bool = true) { self.live = live }
    var limits: ClosedRange<Double> { live ? minTemperature...maxTemperature : 16...32 }
    var hasACState: Bool { !acCapabilities.isEmpty }
    var hasLampState: Bool { !lampCapabilities.isEmpty }
    var connectionLabel: String {
        let connected = tab == 0 ? acConnected : lampConnected
        let known = tab == 0 ? hasACState : hasLampState
        return L(connected ? "Conectado" : known ? "Reconectando" : "Conectando")
    }
    var temperatureLabel: String { live && !hasACState ? "—" : String(Int(temperature)) }
    func connect() {
        guard live else { return }
        request(["status"])
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, !self.editingTemperature, !self.editingBrightness, !self.editingHue, !self.editingWhiteTemperature else { return }
            self.request(["status"])
        }
    }
    func changeTemperature(to value: Double) {
        let value = min(limits.upperBound, max(limits.lowerBound, value.rounded()))
        if live {
            guard acConnected, !commandPending, value != temperature else { return }
            requestedTemperature = value
            setControl("ac", "temperature", value)
        } else { temperature = value }
    }
    private func request(_ arguments: [String]) {
        let isCommand = arguments.first != "status"
        if busy {
            guard isCommand, !commandPending else { return }
            // Reads are safe to interrupt; a user command takes priority over polling.
            if activeProcess?.isRunning == true { activeProcess?.terminate() }
        }
        if isCommand { commandPending = true }
        busy = true
        let requestID = UUID()
        activeRequest = requestID
        let process = Process()
        process.executableURL = root.appendingPathComponent("local/cloud-venv/bin/python")
        process.arguments = [root.appendingPathComponent("scripts/menu-bridge.py").path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        activeProcess = process
        var launched = false
        do { try process.run(); launched = true } catch { }
        let didLaunch = launched
        queue.async { [weak self] in
            guard let self else { return }
            var payload: [String: Any]?
            if didLaunch {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            let response = payload
            DispatchQueue.main.async {
                guard self.activeRequest == requestID else { return }
                self.activeProcess = nil
                self.busy = false
                if isCommand { self.commandPending = false; self.requestedTemperature = nil }
                // A command returns only the device it confirmed; keep the other device's state.
                self.lastResult = mergeSnapshot(self.lastResult, response)
                let result: [String: Any]? = self.lastResult
                self.acConnected = result?["ac_connected"] as? Bool ?? false
                self.lampConnected = result?["lamp_connected"] as? Bool ?? false
                let ac = result?["ac"] as? [String: Any] ?? [:]
                let lamp = result?["lamp"] as? [String: Any] ?? [:]
                self.acCapabilities = ac["capabilities"] as? [String: [String: Any]] ?? [:]
                self.lampCapabilities = lamp["capabilities"] as? [String: [String: Any]] ?? [:]
                if self.acConnected {
                    self.temperatureUnit = ac["unit"] as? String ?? "C"
                    if let value = ac["temperature"] as? Double { self.temperature = value; if !self.editingTemperature { self.draftTemperature = value } }
                    self.ambient = ac["ambient"] as? Double
                    self.acOn = ac["power"] as? Bool ?? false
                    self.mode = ac["mode"] as? String ?? ""
                    self.fan = ac["fan"] as? String ?? ""
                    self.airflow = ac["airflow"] as? String ?? "off"
                    self.eco = ac["eco"] as? Bool ?? false
                    self.sleep = ac["sleep"] as? Bool ?? false
                    self.minTemperature = self.acCapabilities["temperature"]?["min"] as? Double ?? 25
                    self.maxTemperature = self.acCapabilities["temperature"]?["max"] as? Double ?? 27
                }
                if self.lampConnected {
                    self.lightOn = lamp["power"] as? Bool ?? false
                    self.lampMode = lamp["light_mode"] as? String ?? "white"
                    if !self.editingBrightness { self.brightness = lamp["brightness"] as? Double ?? 100 }
                    if !self.editingWhiteTemperature { self.whiteTemperature = lamp["white_temperature"] as? Double ?? 1 }
                    if let color = lamp["color"] as? [String: Double], !self.editingHue {
                        self.hue = color["h"] ?? 0
                        self.lightColor = Color(nsColor: NSColor(calibratedHue: self.hue, saturation: color["s"] ?? 1, brightness: color["v"] ?? 1, alpha: 1))
                    }
                }
                if let error = result?["error"] as? String { self.message = error }
                else if self.acConnected && self.lampConnected { self.message = "Aparelhos conectados" }
                else if self.lampConnected { self.message = "Lâmpada conectada" }
                else { self.message = "Sem conexão com o ar. Confira a rede local." }
                if let result, let data = try? JSONSerialization.data(withJSONObject: result) {
                    let path = self.root.appendingPathComponent("local/menu-state.json")
                    try? data.write(to: path, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                }
                let readiness = ["ac_power": self.canControl("ac", "power"), "ac_temperature": self.canControl("ac", "temperature"),
                    "ac_mode": self.canControl("ac", "mode"), "ac_fan": self.canControl("ac", "fan"),
                    "ac_eco": self.canControl("ac", "eco"), "ac_sleep": self.canControl("ac", "sleep"),
                    "ac_airflow": self.canControl("ac", "airflow"), "lamp_power": self.canControl("lamp", "power"),
                    "lamp_brightness": self.canControl("lamp", "brightness"), "lamp_color": self.canControl("lamp", "color")]
                if let data = try? JSONSerialization.data(withJSONObject: readiness) {
                    try? data.write(to: self.root.appendingPathComponent("local/control-readiness.json"), options: .atomic)
                }
                self.onUpdate?()
            }
        }
    }

    @Published var showInfo = false
    @Published var tab = 0
    @Published var acOn = true
    @Published var lightOn = true
    @Published var temperature = 21.0
    @Published var brightness = 70.0
    @Published var hue = 0.10
    @Published var mode = "Resfriar"
    @Published var fan = "Auto"
    @Published var airflow = "Vertical"
    @Published var sleep = false
    @Published var eco = true
    @Published var lightColor = Color(red: 1, green: 0.78, blue: 0.45)
}

struct RoomPanel: View {
    @ObservedObject var state: DemoState
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "thermometer.medium").foregroundStyle(accent)
                Text(L("Meu quarto")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(state.live ? state.connectionLabel : L("Demonstração")).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accent).padding(.horizontal, 9).padding(.vertical, 6)
                    .background(accent.opacity(0.10), in: Capsule())
            }
            HStack(spacing: 6) {
                tabButton(L("Ar-condicionado"), icon: "air.conditioner.horizontal", index: 0)
                tabButton(L("Iluminação"), icon: "lightbulb", index: 1)
            }.padding(4).background(surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            if state.tab == 0 { airPanel } else { lightPanel }
            HStack(spacing: 7) {
                Circle().fill(accent.opacity(0.65)).frame(width: 5, height: 5)
                Text(state.live ? (state.commandPending ? state.requestedTemperature.map { L("Aplicando %d °C…", Int($0)) } ?? L("Aplicando alteração…") : L(state.message)) : L("Prévia visual · sem conexão com os aparelhos"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if state.tab == 0 {
                    Button { state.showInfo.toggle() } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 16))
                    }.buttonStyle(.plain).foregroundStyle(accent)
                        .accessibilityLabel(L("Informações da demonstração"))
                }
            }.padding(.top, 2)
            if state.showInfo && state.tab == 0 {
                Text(state.live ? L("Seus cliques enviam comandos pela rede local. O painel mostra o estado recebido dos aparelhos e atualiza a leitura a cada 10 segundos. Temperatura em Celsius: 16 a 32 °C.") : L("Os controles alteram apenas esta demonstração."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 420)
        .foregroundStyle(.primary)
    }

    private func tabButton(_ title: String, icon: String, index: Int) -> some View {
        Button { if state.tab != index { state.tab = index } } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(L(title)).font(.system(size: 12, weight: .medium))
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(state.tab == index ? Color.primary : Color.secondary)
                .background(state.tab == index ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private func power(_ role: String) -> some View {
        let on = role == "ac" ? state.acOn : state.lightOn
        return Button { state.setControl(role, "power", !on) } label: {
            Image(systemName: "power").font(.system(size: 22, weight: .regular))
                .foregroundStyle(on ? accent : Color.secondary)
                .frame(width: 44, height: 44)
                .background(surface, in: Circle())
                .overlay(Circle().strokeBorder(accent.opacity(on ? 0.35 : 0.08), lineWidth: 1))
        }.buttonStyle(.plain)
            .accessibilityLabel(L(on ? "Desligar %@" : "Ligar %@", role == "ac" ? L("ar-condicionado") : L("lâmpada")))
            .disabled(!state.canControl(role, "power"))
    }

    private var airPanel: some View {
        VStack(spacing: 16) {
            HStack {
                Text(state.live ? state.ambient.map { L("Ambiente %@ °%@", String(Int($0)), state.temperatureUnit) } ?? L("Ambiente — °C") : L("Ambiente — °C")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                power("ac")
            }
            VStack(spacing: 12) {
                Image(systemName: "air.conditioner.horizontal.fill")
                    .font(.system(size: 72, weight: .ultraLight))
                    .foregroundStyle(.primary)
                    .shadow(color: .white.opacity(0.08), radius: 18)
                Image(systemName: "wind").font(.system(size: 38, weight: .ultraLight))
                    .foregroundStyle(accent.opacity(state.acOn ? 0.45 : 0.08))
            }.frame(height: 100).frame(maxWidth: .infinity)
                .opacity(state.acOn ? 1 : 0.3)
                .accessibilityLabel(L("Ilustração do ar-condicionado"))
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(state.temperatureLabel).font(.system(size: 54, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("°\(state.temperatureUnit)").font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "leaf.fill").foregroundStyle(accent)
                    Text(L("Eco")).font(.system(size: 14, weight: .semibold))
                    Button { state.setControl("ac", "eco", !state.eco) } label: {
                        Capsule().fill(state.eco ? accent : Color.primary.opacity(0.15))
                            .frame(width: 40, height: 23)
                            .overlay(Circle().fill(.white).frame(width: 19, height: 19).offset(x: state.eco ? 8 : -8))
                    }.buttonStyle(.plain).disabled(!state.canControl("ac", "eco")).accessibilityLabel("\(L("Eco")): \(state.eco ? L("ligado") : L("desligado"))")
                }.padding(.horizontal, 12).padding(.vertical, 10)
                    .background(surface, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.10)))
            }
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    roundButton("minus", label: L("Diminuir temperatura")) { state.changeTemperature(to: state.temperature - 1) }
                    Slider(value: $state.draftTemperature, in: state.limits, step: 1, onEditingChanged: { editing in
                        state.editingTemperature = editing
                        if !editing { state.changeTemperature(to: state.draftTemperature) }
                    }).tint(accent)
                        .accessibilityLabel(state.live ? L("Temperatura programada no ar") : L("Temperatura de demonstração"))
                    roundButton("plus", label: L("Aumentar temperatura")) { state.changeTemperature(to: state.temperature + 1) }
                }
                HStack { Text("\(Int(state.limits.lowerBound))°"); Spacer(); Text("\(Int(state.limits.upperBound))°") }
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 52)
            }.disabled(!state.canControl("ac", "temperature"))
            HStack(spacing: 8) {
                menuCard(L("Modo"), icon: "snowflake", role: "ac", control: "mode", value: state.mode)
                menuCard(L("Ventilação"), icon: "fan", role: "ac", control: "fan", value: state.fan)
                Button { state.setControl("ac", "sleep", !state.sleep) } label: {
                    cardContent(L("Sono"), icon: "moon", value: state.sleep ? L("Ligado") : L("Desligado"))
                }.buttonStyle(.plain).disabled(!state.canControl("ac", "sleep")).accessibilityLabel("\(L("Sono")): \(state.sleep ? L("ligado") : L("desligado"))")
                menuCard(L("Oscilar"), icon: "wind", role: "ac", control: "airflow", value: state.airflow)
            }
        }
    }

    private var lightPanel: some View {
        VStack(spacing: 16) {
            HStack {
                Text(state.lampConnected ? (state.lightOn ? L("Luz ligada") : L("Luz desligada")) : state.hasLampState ? L("Último estado · reconectando…") : L("Lâmpada sem conexão"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                power("lamp")
            }
            Image(systemName: "lightbulb.fill").font(.system(size: 94, weight: .ultraLight))
                .foregroundStyle(state.lightOn ? state.lampTint : Color.secondary.opacity(0.35))
                .shadow(color: state.lightOn ? state.lampTint.opacity(0.25) : .clear, radius: 20)
                .frame(height: 120).frame(maxWidth: .infinity)
            HStack {
                Text(state.hasLampState ? "\(Int(state.brightness))" : "—").font(.system(size: 54, weight: .medium, design: .rounded)).monospacedDigit()
                Text("%").font(.system(size: 24)).foregroundStyle(.secondary)
                Spacer()
                Text(L("Brilho")).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Slider(value: $state.brightness, in: 1...100, step: 1, onEditingChanged: { editing in
                state.editingBrightness = editing
                if !editing { state.setControl("lamp", "brightness", state.brightness) }
            }).tint(accent).accessibilityLabel(L("Brilho da lâmpada")).disabled(!state.canControl("lamp", "brightness"))
            HStack(spacing: 8) {
                ForEach(state.options("lamp", "light_mode"), id: \.self) { option in
                    Button { state.setControl("lamp", "light_mode", option) } label: {
                        Text(displayLabel(option)).font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(state.lampMode == option ? accent.opacity(0.18) : surface, in: Capsule())
                    }.buttonStyle(.plain).disabled(!state.canControl("lamp", "light_mode"))
                }
            }
            VStack(spacing: 8) {
                ForEach(0..<3) { row in
                    HStack(spacing: 8) {
                        ForEach(Array(lampPalette[(row * 6)..<(row * 6 + 6)]), id: \.name) { swatch in
                            Button { state.chooseColor(swatch.color) } label: {
                                Circle().fill(swatch.color).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!state.canControl("lamp", "color"))
                                .accessibilityLabel(L(swatch.name)).help(L(swatch.name))
                        }
                    }
                }
            }.padding(12).background(surface, in: RoundedRectangle(cornerRadius: 13))
            if state.lampMode == "white" {
                HStack {
                    Text(L("Quente")).font(.system(size: 11))
                    Slider(value: $state.whiteTemperature, in: 0...1, onEditingChanged: { editing in
                        state.editingWhiteTemperature = editing
                        if !editing { state.setControl("lamp", "white_temperature", state.whiteTemperature) }
                    }).tint(accent).accessibilityLabel(L("Temperatura da luz branca"))
                    Text(L("Fria")).font(.system(size: 11))
                }.disabled(!state.canControl("lamp", "white_temperature"))
            } else {
                HStack {
                    Text(L("Cor")).font(.system(size: 12))
                    Slider(value: $state.hue, in: 0...1, onEditingChanged: { editing in
                        state.editingHue = editing
                        if !editing { state.chooseHue() }
                    }).tint(state.lightColor).accessibilityLabel(L("Tonalidade da luz"))
                }.disabled(!state.canControl("lamp", "color"))
            }
        }
    }

    private func roundButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 38, height: 38)
                .background(surface, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(L(label))
    }

    private func displayLabel(_ value: String) -> String {
        ["cold": L("Resfriar"), "hot": L("Aquecer"), "wet": L("Secar"), "wind": L("Ventilar"), "auto": L("Auto"),
         "mute": L("Silenciosa"), "low": L("Baixa"), "mid": L("Média"), "high": L("Alta"), "strength": L("Turbo"),
         "mid_low": L("Média −"), "mid_high": L("Média +"), "off": L("Parado"), "vertical": L("Vertical"),
         "horizontal": L("Horizontal"), "both": L("Ambos"), "white": L("Branca"), "colour": L("Colorida")] [value] ?? L(value)
    }

    private func menuCard(_ title: String, icon: String, role: String, control: String, value: String) -> some View {
        Button {
            let menu = NSMenu()
            for option in state.options(role, control) {
                let target = MenuChoice { state.setControl(role, control, option) }
                let item = NSMenuItem(title: displayLabel(option), action: #selector(MenuChoice.select), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                item.state = option == value ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            cardContent(title, icon: icon, value: displayLabel(value))
                .overlay(alignment: .topTrailing) { Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary).padding(10) }
        }.buttonStyle(.plain)
            .disabled(!state.canControl(role, control))
            .accessibilityLabel("\(L(title)): \(displayLabel(value))")
    }

    private func cardContent(_ title: String, icon: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 23, weight: .light)).foregroundStyle(accent)
            Text(L(title)).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value.isEmpty ? L("Indisponível") : value).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
    }
}

struct MenuOutline: Shape {
    var pointerX: CGFloat
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 24
        let top: CGFloat = 10
        let cx = min(max(pointerX, radius + 18), rect.width - radius - 18)
        var path = Path()
        path.move(to: CGPoint(x: radius, y: top))
        path.addLine(to: CGPoint(x: cx - 16, y: top))
        path.addCurve(to: CGPoint(x: cx, y: 0), control1: CGPoint(x: cx - 8, y: top), control2: CGPoint(x: cx - 7, y: 0))
        path.addCurve(to: CGPoint(x: cx + 16, y: top), control1: CGPoint(x: cx + 7, y: 0), control2: CGPoint(x: cx + 8, y: top))
        path.addLine(to: CGPoint(x: rect.width - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: top + radius), control: CGPoint(x: rect.width, y: top))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - radius))
        path.addQuadCurve(to: CGPoint(x: rect.width - radius, y: rect.height), control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: radius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.height - radius), control: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: top), control: CGPoint(x: 0, y: top))
        path.closeSubpath()
        return path
    }
}

struct NativeBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

final class PanelLayout: ObservableObject {
    @Published var width: CGFloat = 420
    @Published var height: CGFloat = 620
    @Published var pointerX: CGFloat = 210
}

struct GlassPanel: View {
    @ObservedObject var state: DemoState
    @ObservedObject var layout: PanelLayout
    var body: some View {
        let outline = MenuOutline(pointerX: layout.pointerX)
        let content = RoomPanel(state: state)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .frame(width: layout.width, height: layout.height, alignment: .top)
        if #available(macOS 26.0, *) {
            content.background(NativeBackdrop()).glassEffect(.clear, in: outline).clipShape(outline)
        } else {
            content.background(.ultraThinMaterial, in: outline).clipShape(outline)
        }
    }
}

// Compose white artwork, then let the native status button own its spacing and selection.
enum StatusArtwork {
    static func image(text: String) -> NSImage {
        let label = NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.white,
            .font: NSFont.menuBarFont(ofSize: 0)])
        let size = label.size()
        let symbolWidth: CGFloat = 18
        let gap: CGFloat = 2
        let canvas = NSSize(width: symbolWidth + gap + ceil(size.width), height: max(18, ceil(size.height)))
        let symbol = NSImage(systemSymbolName: "air.conditioner.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))?
            .withSymbolConfiguration(.init(paletteColors: [.white]))
        symbol?.isTemplate = false
        let image = NSImage(size: canvas, flipped: false) { _ in
            symbol?.draw(in: NSRect(x: 0, y: (canvas.height - 18) / 2, width: symbolWidth, height: 18))
            label.draw(in: NSRect(x: symbolWidth + gap, y: (canvas.height - size.height) / 2,
                width: size.width, height: size.height))
            return true
        }
        image.isTemplate = false
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = DemoState()
    var item: NSStatusItem!
    private var statusText = ""
    var panel: NSPanel?
    private var isPanelOpen = false
    let layout = PanelLayout()
    var hostingView: NSHostingView<GlassPanel>?
    var eventMonitor: Any?
    var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--lamp") { state.tab = 1 }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            statusText = L("Quarto")
            button.image = StatusArtwork.image(text: statusText)
            button.target = self
            button.action = #selector(togglePanel)
            button.setButtonType(.toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.state.objectWillChange.send()
                self?.updateStatusButton()
                if self?.isPanelOpen == true { self?.layoutPanel() }
            }.store(in: &subscriptions)
        state.onUpdate = { [weak self] in
            guard let self else { return }
            self.updateStatusButton()
        }
        state.$tab.combineLatest(state.$showInfo, state.$lampMode).dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { if self?.isPanelOpen == true { self?.layoutPanel() } }
        }.store(in: &subscriptions)
        if !CommandLine.arguments.contains("--interaction-check") { state.connect() }
        if CommandLine.arguments.contains("--interaction-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.checkInteractions() }
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
        }
        if CommandLine.arguments.contains("--ui-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.showPanel()
                let opened = self.panel?.isVisible == true && self.item.button?.state == .on
                self.item.button?.performClick(nil)
                let closed = self.panel?.isVisible == false && self.item.button?.state == .off
                self.item.button?.performClick(nil)
                let reopened = self.panel?.isVisible == true && self.item.button?.state == .on
                let result = ["opened": opened, "secondClickClosed": closed, "thirdClickOpened": reopened]
                let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local/panel-ui-check.json")
                if let data = try? JSONSerialization.data(withJSONObject: result) { try? data.write(to: path, options: .atomic) }
            }
        }
    }

    private func checkInteractions() {
        state.acConnected = true
        state.lampConnected = true
        state.acCapabilities = ["power": [:]]
        state.lampCapabilities = ["power": [:]]
        state.busy = true // Simulate a background read, without connecting to devices.
        showPanel()
        let cached: [String: Any] = ["lamp_connected": true, "lamp": ["connected": true, "brightness": 63, "color": ["h": 0.4], "capabilities": ["power": [:]]], "ac_connected": true]
        let failed = mergeSnapshot(cached, ["lamp_connected": false, "lamp": ["connected": false, "capabilities": [:]]])
        let retained = failed["lamp"] as? [String: Any]
        let staleRetained = retained?["brightness"] as? Int == 63 && retained?["color"] != nil && failed["lamp_connected"] as? Bool == false && failed["ac_connected"] as? Bool == true
        let recovered = mergeSnapshot(failed, ["lamp_connected": true, "lamp": ["connected": true, "brightness": 80]])
        let recoveredCorrectly = (recovered["lamp"] as? [String: Any])?["brightness"] as? Int == 80 && recovered["lamp_connected"] as? Bool == true
        let originalHost = hostingView
        let originalContent = panel?.contentView
        let readDoesNotDisableControls = state.canControl("ac", "power") && state.canControl("lamp", "power")
        var preserved = true
        var contentFits = true
        func containsScrollView(_ view: NSView) -> Bool {
            view is NSScrollView || view.subviews.contains(where: containsScrollView)
        }
        var switches = 0
        for step in 1...6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.15) { [weak self] in
                guard let self else { return }
                preserved = preserved && self.hostingView === originalHost && self.panel?.contentView === originalContent
                let requiredHeight = ceil(NSHostingView(rootView: RoomPanel(state: self.state)).fittingSize.height) + 10
                contentFits = contentFits && self.layout.height >= requiredHeight && self.panel?.frame.height == self.layout.height
                self.state.tab = step % 2
                switches += 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            let stable = preserved && self.hostingView === originalHost && self.panel?.contentView === originalContent
            self.closePanel()
            self.state.tab = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let result: [String: Any] = ["backgroundReadKeepsControlsEnabled": readDoesNotDisableControls,
                    "tabSwitchCount": switches, "hostingViewPreserved": stable,
                    "hostIdentityPreserved": self.hostingView === originalHost,
                    "bothTabsFitPanel": contentFits,
                    "panelContainsNoScrollView": self.hostingView.map { !containsScrollView($0) } ?? false,
                    "failedReadRetainsKnownValues": staleRetained, "recoveryUpdatesValues": recoveredCorrectly,
                    "contentType": String(describing: type(of: self.panel?.contentView)),
                    "closedPanelStaysClosed": self.panel?.isVisible == false]
                let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local/interaction-check.json")
                if let data = try? JSONSerialization.data(withJSONObject: result) { try? data.write(to: path, options: .atomic) }
                NSApp.terminate(nil)
            }
        }
    }

    @objc func togglePanel() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            let menu = NSMenu()
            menu.addItem(withTitle: L("Encerrar Elgin Menu Bar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            button.performClick(nil)
            item.menu = nil
        } else if panel?.isVisible == true {
            closePanel()
        } else { showPanel() }
    }

    private func showPanel() {
        isPanelOpen = true
        layoutPanel()
        panel?.orderFrontRegardless()
        updateStatusButton()
    }

    private func layoutPanel() {
        guard let button = item.button, let barWindow = button.window else { return }
        let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = barWindow.screen ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let width = min(420.0, bounds.width - 16)
        let top = min(anchor.minY - 8, bounds.maxY - 8)
        let measure = NSHostingView(rootView: RoomPanel(state: state))
        let naturalHeight = ceil(measure.fittingSize.height) + 10
        let height = min(naturalHeight, top - bounds.minY - 8)
        guard height > 0 else { return }
        let x = min(max(anchor.midX - width / 2, bounds.minX + 8), bounds.maxX - width - 8)
        let frame = NSRect(x: x, y: top - height, width: width, height: height)
        let window = panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Keep the hosting view alive: replacing it interrupts clicks and redraws glass.
        if layout.width != width { layout.width = width }
        if layout.height != height { layout.height = height }
        if layout.pointerX != anchor.midX - x { layout.pointerX = anchor.midX - x }
        if hostingView == nil {
            let host = NSHostingView(rootView: GlassPanel(state: state, layout: layout))
            host.sizingOptions = [] // AppKit owns the window size and visibility.
            hostingView = host
            window.contentView = host
        }
        // Defer drawing until SwiftUI and the window have their final sizes.
        if window.frame != frame { window.setFrame(frame, display: false) }
        panel = window
        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self else { return }
                let point = NSEvent.mouseLocation
                // O clique no ícone deve chegar ao toggle; não fechar antes do mouseUp.
                if let button = self.item.button, let bar = button.window {
                    let iconRect = bar.convertToScreen(button.convert(button.bounds, to: nil))
                    if iconRect.contains(point) { return }
                }
                if self.panel?.frame.contains(point) == true { return }
                self.closePanel()
            }
        }
        // Registra somente a geometria da nossa janela, sem capturar outras aplicações.
        let geometry: [String: Double] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
            "screenMinX": bounds.minX, "screenMaxX": bounds.maxX, "screenMinY": bounds.minY, "screenMaxY": bounds.maxY,
            "menuBarBottom": anchor.minY, "windowNumber": Double(window.windowNumber), "naturalHeight": naturalHeight]
        if let data = try? JSONSerialization.data(withJSONObject: geometry) {
            let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local/panel-geometry.json")
            try? data.write(to: path, options: .atomic)
        }
    }

    private func updateStatusButton() {
        let title = state.acConnected ? "\(Int(state.temperature))°" : L("Quarto")
        if statusText != title {
            statusText = title
            item.button?.image = StatusArtwork.image(text: title)
        }
        let opened = panel?.isVisible == true
        let buttonState: NSControl.StateValue = opened ? .on : .off
        if item.button?.state != buttonState {
            item.button?.state = buttonState
            item.button?.highlight(opened)
        }
        item.button?.toolTip = opened ? L("Recolher controles do quarto") : L("Abrir controles do quarto")
        item.button?.setAccessibilityLabel(opened ? L("Recolher controles do quarto") : L("Abrir controles do quarto"))
        item.button?.setAccessibilityValue(title)
        if let button = item.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let geometry: [String: Double] = ["windowNumber": Double(window.windowNumber),
                "x": rect.minX, "y": (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY,
                "width": rect.width, "height": rect.height,
                "artworkWidth": Double(button.image?.size.width ?? 0),
                "nativeSizing": item.length == NSStatusItem.variableLength ? 1 : 0]
            let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local/status-item-window.json")
            if let data = try? JSONSerialization.data(withJSONObject: geometry) { try? data.write(to: path, options: .atomic) }
        }
    }

    private func closePanel() {
        isPanelOpen = false
        panel?.orderOut(nil)
        updateStatusButton()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
    }
}

@main enum Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--localization-check") {
            let results = verifyLocalizations()
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
            exit(results.values.allSatisfy { $0 } ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            let state = DemoState(live: CommandLine.arguments.contains("--live"))
            if state.live {
                let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local/menu-state.json")
                if let data = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    state.acConnected = value["ac_connected"] as? Bool ?? false
                    state.lampConnected = value["lamp_connected"] as? Bool ?? false
                    state.temperature = value["temperature"] as? Double ?? 27
                    state.message = value["error"] as? String ?? L("Ar conectado · temperatura confirmada")
                }
            }
            if CommandLine.arguments.contains("--lamp") { state.tab = 1 }
            let renderer = ImageRenderer(content: RoomPanel(state: state))
            renderer.scale = 2
            if let image = renderer.cgImage {
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            } else { exit(1) }
            return
        }
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local")
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockDescriptor = Darwin.open(local.appendingPathComponent("menu-bar.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockDescriptor >= 0 else { return }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lockDescriptor); return }
        defer { Darwin.close(lockDescriptor) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
