// TPSApp.swift — menu bar приложение «TPS Counter» для macOS.
//
// Значок в строке меню показывает живой tok/s (клик — панель с деталями).
// Хаб метрик (tps-hub.mjs) лежит внутри бандла: приложение поднимает его при
// старте и перезапускает, если тот перестал отвечать. Отдельного окна нет.
//
// Сборка: macos/build.sh.

import AppKit
import Foundation
import SwiftUI

// MARK: - Параметры

struct AppOptions {
  var port = 57451
  var intervalMs = 150
  var stateDir = AppOptions.defaultStateDir
  var hubPath: String?
  var nodePath: String?
  var noWatchdog = false

  static var defaultStateDir: String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
    return base.appendingPathComponent("TPS Counter").path
  }
}

func parseAppOptions() -> AppOptions {
  var options = AppOptions()
  let args = CommandLine.arguments
  var i = 1
  func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
  while i < args.count {
    switch args[i] {
    case "--port":
      if let v = value(), let n = Int(v) { options.port = n; i += 1 }
    case "--interval-ms":
      if let v = value(), let n = Int(v), n > 0 { options.intervalMs = n; i += 1 }
    case "--state-dir":
      if let v = value() { options.stateDir = (v as NSString).expandingTildeInPath; i += 1 }
    case "--hub":
      if let v = value() { options.hubPath = (v as NSString).expandingTildeInPath; i += 1 }
    case "--node":
      if let v = value() { options.nodePath = v; i += 1 }
    case "--no-watchdog":
      options.noWatchdog = true
    default:
      break
    }
    i += 1
  }
  if let envPort = ProcessInfo.processInfo.environment["TPS_PORT"], let n = Int(envPort), options.port == 57451 {
    options.port = n
  }
  return options
}

// MARK: - Состояние хаба

func numberOf(_ value: Any?) -> Double? {
  if value is NSNull { return nil }
  if let d = value as? Double { return d }
  if let i = value as? Int { return Double(i) }
  if let n = value as? NSNumber { return n.doubleValue }
  return nil
}

struct TurnRecord: Codable, Identifiable {
  var id: String { (finishedAt ?? "") + String(tokens) }
  var model: String?
  var tokens: Double = 0
  var avgTps: Double?
  var ttftMs: Double?
  var genMs: Double?
  var finishedAt: String?
}

struct HubState {
  var reachable = false
  var active = false
  var model: String?
  var tps: Double = 0
  var avgTps: Double = 0
  var ttftMs: Double?
  var tokens: Double = 0
  var firstTokenAt: Double = 0
  var activeTurns = 0
  var turns: [TurnRecord] = []

  static func decode(_ data: Data) -> HubState? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return nil
    }
    var state = HubState()
    state.reachable = true
    state.active = object["active"] as? Bool ?? false
    if let model = object["model"] as? String, !model.isEmpty { state.model = model }
    state.tps = numberOf(object["tps"]) ?? 0
    state.avgTps = numberOf(object["avgTps"]) ?? 0
    state.ttftMs = numberOf(object["ttftMs"])
    state.tokens = numberOf(object["tokens"]) ?? 0
    state.firstTokenAt = numberOf(object["firstTokenAt"]) ?? 0
    state.activeTurns = object["activeTurns"] as? Int ?? 0
    if let list = object["turns"] as? [[String: Any]] {
      state.turns = list.map { raw in
        var turn = TurnRecord()
        turn.model = raw["model"] as? String
        turn.tokens = numberOf(raw["tokens"]) ?? 0
        turn.avgTps = numberOf(raw["avgTps"])
        turn.ttftMs = numberOf(raw["ttftMs"])
        turn.genMs = numberOf(raw["genMs"])
        turn.finishedAt = raw["finishedAt"] as? String
        return turn
      }
    }
    return state
  }
}

final class MonitorModel: ObservableObject {
  @Published var state = HubState()
}

// MARK: - Форматирование

func formatMs(_ ms: Double?) -> String {
  guard let ms else { return "—" }
  if ms < 1000 { return "\(Int(ms.rounded())) ms" }
  return String(format: "%.2f s", ms / 1000)
}

func formatOne(_ value: Double?) -> String {
  guard let value else { return "—" }
  return String(format: "%.1f", value)
}

func formatCount(_ value: Double) -> String {
  if value >= 1000 { return String(format: "%.1fk", value / 1000) }
  return "\(Int(value.rounded()))"
}

let clockFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "HH:mm:ss"
  return formatter
}()

let isoFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

func clockText(_ iso: String?) -> String {
  guard let iso, let date = isoFormatter.date(from: iso) else { return "—" }
  return clockFormatter.string(from: date)
}

// MARK: - Вид панели

struct StatView: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.6)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct TurnRow: View {
  let turn: TurnRecord

  var body: some View {
    HStack(spacing: 6) {
      Text(clockText(turn.finishedAt))
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
      Text(turn.model ?? "—")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      Text("\(formatOne(turn.avgTps)) tok/s")
        .font(.system(size: 10, weight: .medium, design: .monospaced))
      Text("TTFT \(formatMs(turn.ttftMs))")
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
    }
  }
}

/// Убирает оранжевую рамку фокуса у кнопок в панели.
struct NoFocusRing: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content.focusEffectDisabled()
    } else {
      content
    }
  }
}

struct CounterView: View {
  @ObservedObject var model: MonitorModel
  let port: Int
  let openDashboard: () -> Void
  let quit: () -> Void

  private var state: HubState { model.state }

  private var accent: Color {
    if !state.reachable { return Color(nsColor: .secondaryLabelColor) }
    guard state.active else { return Color(nsColor: .secondaryLabelColor) }
    if state.tps >= 45 { return .cyan }
    if state.tps >= 30 { return .green }
    if state.tps >= 15 { return .orange }
    return .red
  }

  private var scoreText: String {
    state.reachable ? formatOne(state.active ? state.tps : state.lastAvg) : "—"
  }

  private var statusText: String {
    if !state.reachable { return "хаб не отвечает" }
    return state.active ? "генерация" : "idle"
  }

  private var lastTurn: TurnRecord? { state.turns.first }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 8) {
        Text("TPS COUNTER")
          .font(.system(size: 9, weight: .semibold))
          .tracking(1.1)
          .foregroundStyle(.secondary)
        Spacer()
        Circle()
          .fill(state.reachable ? (state.active ? accent : Color(nsColor: .tertiaryLabelColor)) : .red)
          .frame(width: 6, height: 6)
        Text(statusText)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(state.reachable ? Color.secondary : .red)
      }

      Text(state.model ?? lastTurn?.model ?? "—")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.top, 3)

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(scoreText)
          .font(.system(size: 50, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(accent)
        Text("tok/s")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      .padding(.top, 4)

      ProgressView(value: min(max(state.active ? state.tps : 0, 0), 60), total: 60)
        .progressViewStyle(.linear)
        .tint(accent)
        .frame(height: 4)
        .padding(.top, 2)

      HStack(spacing: 10) {
        StatView(title: "avg", value: formatOne(state.active ? state.avgTps : lastTurn?.avgTps))
        StatView(title: "ttft", value: formatMs(state.active ? state.ttftMs : lastTurn?.ttftMs))
        StatView(title: "tokens", value: formatCount(state.active ? state.tokens : (lastTurn?.tokens ?? 0)))
      }
      .padding(.top, 10)

      Divider().padding(.vertical, 9)

      Text("ПОСЛЕДНИЕ ОТВЕТЫ")
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.6)
        .foregroundStyle(.secondary)

      if state.turns.isEmpty {
        Text(state.reachable ? "Пока пусто — отправьте сообщение в новом чате." : "Запустите хаб: ./start.sh")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .padding(.top, 6)
      } else {
        VStack(spacing: 5) {
          ForEach(state.turns.prefix(4)) { turn in
            TurnRow(turn: turn)
          }
        }
        .padding(.top, 6)
      }

      HStack(spacing: 8) {
        Button(action: openDashboard) {
          Text("Дашборд")
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.09)),
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .modifier(NoFocusRing())

        Spacer()

        Text("127.0.0.1:\(port)")
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.tertiary)

        Button(action: quit) {
          Text("Выход")
            .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .modifier(NoFocusRing())
        .keyboardShortcut("q")
      }
    }
    .padding(14)
    .padding(.top, 10)
    .frame(width: 326)
  }
}

extension HubState {
  var lastAvg: Double? { turns.first?.avgTps }
}

// MARK: - Приложение

/// Плавающая панель без активации приложения: обычный поповер требует
/// активации, а приложение-аксессуар, ставшее активным без окон, заставляет
/// macOS держать строку меню поверх полноэкранных приложений.
final class CounterPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

final class AppController: NSObject, NSApplicationDelegate {
  private let options: AppOptions
  private let model = MonitorModel()
  private let session: URLSession

  private var statusItem: NSStatusItem!
  private var panel: CounterPanel?
  private var hosting: NSHostingController<AnyView>?
  private var outsideClickMonitor: Any?
  private var escapeMonitor: Any?
  private var ignoreActivationUntil = Date.distantPast
  private var timer: Timer?
  private var failures = 0
  private var inFlight = false
  private var lastRestart = Date.distantPast
  private var lastLabel = "\u{0}"
  private var lastLabelColor: NSColor = .secondaryLabelColor

  private var startedHubPID: Int32?
  private var nodePath: String?
  private var hubPath: String?

  private var stateDir: String { options.stateDir }
  private var logsDir: String { stateDir + "/logs" }

  init(options: AppOptions) {
    self.options = options
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 0.8
    configuration.timeoutIntervalForResource = 1.5
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: configuration)
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    _ = NSApp.setActivationPolicy(.accessory)
    prepareStateDirectory()
    nodePath = resolveNode(options.nodePath)
    hubPath = resolveHub()
    buildStatusItem()
    _ = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "TPS Counter",
    )
    updateStatusItem()
    tick()
    let interval = TimeInterval(options.intervalMs) / 1000
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(workspaceAppActivated),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil,
    )
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
    timer.tolerance = interval * 0.2
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    // Приложение живёт в строке меню и не должно забирать фокус при старте.
    if NSApp.isActive { NSApp.hide(nil) }
  }

  func applicationWillTerminate(_ notification: Notification) {
    timer?.invalidate()
    stopHubIfOwned()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showPanel()
    return false
  }

  // MARK: menu bar

  private func buildStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let button = statusItem.button else { return }
    let image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "TPS")
    image?.isTemplate = true
    button.image = image
    button.imagePosition = .imageLeading
    button.target = self
    button.action = #selector(statusItemClicked)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button.toolTip = "TPS Counter"
  }

  @objc private func statusItemClicked() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showContextMenu()
    } else {
      togglePanel()
    }
  }

  /// ПКМ по значку — короткое меню: дашборд и выход (на случай, если панель
  /// не открывается или нужно закрыть приложение одной командой).
  private func showContextMenu() {
    guard let button = statusItem.button else { return }
    closePanel()
    let menu = NSMenu()
    let dashboard = NSMenuItem(title: "Открыть дашборд", action: #selector(openDashboard), keyEquivalent: "")
    dashboard.target = self
    menu.addItem(dashboard)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Выход", action: #selector(quitApp), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  private func buildPanelIfNeeded() {
    guard panel == nil else { return }
    let controller = NSHostingController(
      rootView: AnyView(
        CounterView(
          model: model,
          port: options.port,
          openDashboard: { [weak self] in self?.openDashboard() },
          quit: { NSApp.terminate(nil) },
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1),
        ),
      ),
    )
    let panel = CounterPanel(
      contentRect: NSRect(x: 0, y: 0, width: 326, height: 320),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
    )
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.contentViewController = controller
    self.panel = panel
    self.hosting = controller
    resizePanelToFit()
  }

  /// Высота панели = идеальная высота содержимого, чтобы не было ни пустоты,
  /// ни обрезанных строк в списке последних ответов.
  private func resizePanelToFit() {
    guard let hosting, let panel else { return }
    hosting.view.layoutSubtreeIfNeeded()
    let fitting = hosting.view.fittingSize
    guard fitting.height > 40 else { return }
    let size = NSSize(width: 326, height: ceil(fitting.height))
    guard abs(panel.frame.height - size.height) > 0.5 else { return }
    let top = panel.isVisible ? panel.frame.maxY : nil
    panel.setContentSize(size)
    if let top { positionPanel(size: size, top: top) }
  }

  /// Точка привязки — значок в строке меню, панель висит под ним.
  private func panelOrigin(size: NSSize, top: CGFloat? = nil) -> NSPoint {
    guard let button = statusItem.button, let window = button.window else { return .zero }
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    let screen = (window.screen ?? NSScreen.main)?.frame ?? .zero
    var x = anchor.midX - size.width / 2
    x = min(max(x, screen.minX + 6), screen.maxX - size.width - 6)
    return NSPoint(x: x, y: (top ?? (anchor.minY - 6)) - size.height)
  }

  private func positionPanel(size: NSSize, top: CGFloat) {
    guard let panel else { return }
    panel.setFrame(NSRect(origin: panelOrigin(size: size, top: top), size: size), display: true)
  }

  private func togglePanel() {
    if panel?.isVisible == true {
      closePanel()
    } else {
      showPanel()
    }
  }

  private func showPanel() {
    buildPanelIfNeeded()
    guard let panel else { return }
    resizePanelToFit()
    let size = panel.frame.size
    panel.setFrame(NSRect(origin: panelOrigin(size: size), size: size), display: true)
    panel.makeKeyAndOrderFront(nil)
    // Панель неактивирующая: если приложение всё же активировали (open -a),
    // возвращаем фокус, чтобы строка меню в полноэкранном режиме не залипла.
    // LaunchServices активирует приложение уже после показа, поэтому проверяем
    // ещё раз с небольшой задержкой.
    deactivateIfActive()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self, self.panel?.isVisible == true else { return }
      self.deactivateIfActive()
    }
    installMonitors()
  }

  private func deactivateIfActive() {
    guard NSApp.isActive else { return }
    ignoreActivationUntil = Date().addingTimeInterval(0.8)
    // hide() гарантированно отдаёт фокус предыдущему приложению; панель
    // неактивирующая, поэтому сразу показываем её снова.
    NSApp.hide(nil)
    panel?.orderFront(nil)
    panel?.makeKey()
  }

  /// Панель закрывается, когда пользователь уходит в другое приложение (⌘Tab, Dock).
  @objc private func workspaceAppActivated(_ notification: Notification) {
    guard Date() >= ignoreActivationUntil else { return }
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    if app.bundleIdentifier != Bundle.main.bundleIdentifier { closePanel() }
  }

  private func closePanel() {
    removeMonitors()
    panel?.orderOut(nil)
  }

  private func installMonitors() {
    removeMonitors()
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      DispatchQueue.main.async { self?.closePanel() }
    }
    if outsideClickMonitor == nil {
      logLine("не удалось установить монитор внешних кликов")
    }
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return event }
      self?.closePanel()
      return nil
    }
  }

  private func removeMonitors() {
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
      outsideClickMonitor = nil
    }
    if let monitor = escapeMonitor {
      NSEvent.removeMonitor(monitor)
      escapeMonitor = nil
    }
  }

  @objc private func openDashboard() {
    guard let url = URL(string: "http://127.0.0.1:\(options.port)/__tps/") else { return }
    NSWorkspace.shared.open(url)
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else { return }
    let state = model.state
    let active = state.reachable && state.active
    let value = active ? state.tps : (state.lastAvg ?? 0)

    let label: String
    if !state.reachable {
      label = "—"
    } else if active || value > 0 {
      label = "\(Int(value.rounded()))"
    } else {
      label = "0"
    }

    let color: NSColor
    if !state.reachable {
      color = .systemRed
    } else if !active {
      color = .secondaryLabelColor
    } else if state.tps >= 45 {
      color = .systemTeal
    } else if state.tps >= 30 {
      color = .systemGreen
    } else if state.tps >= 15 {
      color = .systemOrange
    } else {
      color = .systemRed
    }

    if label != lastLabel || color != lastLabelColor {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: color,
      ]
      button.attributedTitle = NSAttributedString(string: " " + label, attributes: attributes)
      lastLabel = label
      lastLabelColor = color
    }

    let tooltip: String
    if state.reachable {
      let mode = state.active ? "генерация" : "idle"
      let name = state.model ?? state.turns.first?.model ?? "—"
      let avg = formatOne(state.active ? state.avgTps : state.turns.first?.avgTps)
      let ttft = formatMs(state.active ? state.ttftMs : state.turns.first?.ttftMs)
      tooltip = "TPS Counter — \(mode)\n\(name)\ntok/s: \(formatOne(value)) · avg: \(avg) · ttft: \(ttft)"
    } else {
      tooltip = "TPS Counter — хаб не отвечает на 127.0.0.1:\(options.port)"
    }
    if button.toolTip != tooltip { button.toolTip = tooltip }
  }

  // MARK: опрос хаба

  private func tick() {
    guard !inFlight else { return }
    guard let url = URL(string: "http://127.0.0.1:\(options.port)/__tps/state") else { return }
    inFlight = true
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    session.dataTask(with: request) { [weak self] data, _, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.inFlight = false
        self.apply(data: data)
      }
    }.resume()
  }

  private func apply(data: Data?) {
    if let data, let decoded = HubState.decode(data) {
      failures = 0
      let turnsChanged = decoded.turns.count != model.state.turns.count
      model.state = decoded
      if turnsChanged, panel != nil {
        DispatchQueue.main.async { [weak self] in self?.resizePanelToFit() }
      }
    } else {
      failures += 1
      model.state = HubState()
      if failures >= 8 { restartHubIfNeeded() }
    }
    updateStatusItem()
  }

  // MARK: хаб внутри бандла

  private func prepareStateDirectory() {
    for path in [stateDir, logsDir] {
      try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
  }

  private func resolveNode(_ explicit: String?) -> String? {
    if let explicit, !explicit.isEmpty, FileManager.default.isExecutableFile(atPath: explicit) {
      return explicit
    }
    if let env = ProcessInfo.processInfo.environment["TPS_NODE"],
       FileManager.default.isExecutableFile(atPath: env) {
      return env
    }
    let candidates = [
      "/opt/homebrew/bin/node",
      "/usr/local/bin/node",
      "/usr/bin/node",
      (NSHomeDirectory() + "/.volta/bin/node"),
      (NSHomeDirectory() + "/.nvm/current/bin/node"),
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
      let candidate = String(directory) + "/node"
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  private func resolveHub() -> String? {
    if let explicit = options.hubPath, FileManager.default.fileExists(atPath: explicit) {
      return explicit
    }
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("tps-hub.mjs").path,
       FileManager.default.fileExists(atPath: bundled) {
      return bundled
    }
    let fallback = stateDir + "/tps-hub.mjs"
    if FileManager.default.fileExists(atPath: fallback) { return fallback }
    return nil
  }

  private func restartHubIfNeeded() {
    guard !options.noWatchdog else { return }
    let now = Date()
    if now.timeIntervalSince(lastRestart) < 20 { return }
    lastRestart = now
    guard portOpen(options.port) == false else { return }
    startHub()
  }

  @discardableResult
  private func startHub() -> Bool {
    guard let node = nodePath else {
      logLine("node не найден: хаб не запущен")
      return false
    }
    guard let hub = hubPath else {
      logLine("tps-hub.mjs не найден в бандле")
      return false
    }
    if portOpen(options.port) { return true }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [hub, "--port", String(options.port)]
    process.currentDirectoryURL = URL(fileURLWithPath: stateDir)
    if let out = appendHandle(logsDir + "/hub.log") { process.standardOutput = out }
    if let err = appendHandle(logsDir + "/hub.log.err") { process.standardError = err }
    do {
      try process.run()
      startedHubPID = process.processIdentifier
      return true
    } catch {
      logLine("не удалось запустить хаб: \(error.localizedDescription)")
      return false
    }
  }

  private func stopHubIfOwned() {
    guard let pid = startedHubPID else { return }
    kill(pid, SIGTERM)
    startedHubPID = nil
  }

  private func portOpen(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let result = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
        connect(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0
  }

  private func appendHandle(_ path: String) -> FileHandle? {
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
    handle.seekToEndOfFile()
    return handle
  }

  private func logLine(_ text: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let handle = appendHandle(logsDir + "/app.log"),
          let data = "[\(stamp)] \(text)\n".data(using: .utf8) else { return }
    handle.write(data)
    try? handle.close()
  }
}

// MARK: - Точка входа

@main
enum TPSTool {
  static func main() {
    let options = parseAppOptions()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = AppController(options: options)
    app.delegate = controller
    app.run()
  }
}
