// overlay.swift — macOS-окно «токены/сек»: маленькая всегда-сверху панель,
// читает http://127.0.0.1:<port>/__tps/state у tps-hub.mjs.
// Перетаскивание — левой кнопкой, закрыть — двойной клик (как в Windows-версии).
//
// Сборка: scripts/build-overlay.sh (swiftc -O -parse-as-library).

import AppKit
import Foundation

// MARK: - Параметры

struct OverlayOptions {
  var port = 57451
  var intervalMs = 150
  var repoRoot = ""
  var nodePath: String?
  var noWatchdog = false
}

func parseOverlayOptions() -> OverlayOptions {
  var options = OverlayOptions()
  let args = CommandLine.arguments
  var i = 1
  func valueAfter(_ flag: String) -> String? {
    if i + 1 < args.count { return args[i + 1] }
    return nil
  }
  while i < args.count {
    switch args[i] {
    case "--port":
      if let v = valueAfter("--port"), let n = Int(v) { options.port = n; i += 1 }
    case "--interval-ms":
      if let v = valueAfter("--interval-ms"), let n = Int(v), n > 0 { options.intervalMs = n; i += 1 }
    case "--repo-root":
      if let v = valueAfter("--repo-root") { options.repoRoot = v; i += 1 }
    case "--node":
      if let v = valueAfter("--node") { options.nodePath = v; i += 1 }
    case "--no-watchdog":
      options.noWatchdog = true
    default:
      break
    }
    i += 1
  }
  if options.repoRoot.isEmpty {
    // build/tps-overlay -> корень репозитория
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    options.repoRoot = exe.deletingLastPathComponent().deletingLastPathComponent().path
  }
  if let envPort = ProcessInfo.processInfo.environment["TPS_PORT"], let n = Int(envPort), options.port == 57451 {
    options.port = n
  }
  return options
}

func numberOf(_ value: Any?) -> Double? {
  if value is NSNull { return nil }
  if let d = value as? Double { return d }
  if let i = value as? Int { return Double(i) }
  if let n = value as? NSNumber { return n.doubleValue }
  return nil
}

// MARK: - Состояние хаба

struct TurnRecord {
  var model: String?
  var tokens: Double = 0
  var avgTps: Double?
  var ttftMs: Double?
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
  var lastTurn: TurnRecord?

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
    if let turns = object["turns"] as? [[String: Any]], let first = turns.first {
      var turn = TurnRecord()
      turn.model = first["model"] as? String
      turn.tokens = numberOf(first["tokens"]) ?? 0
      turn.avgTps = numberOf(first["avgTps"])
      turn.ttftMs = numberOf(first["ttftMs"])
      state.lastTurn = turn
    }
    return state
  }
}

// MARK: - Отрисовка

func tpsColor(_ value: Double) -> NSColor {
  if value >= 45 { return NSColor(srgbRed: 0x44 / 255, green: 0xDD / 255, blue: 0xFF / 255, alpha: 1) }
  if value >= 30 { return NSColor(srgbRed: 0x00 / 255, green: 0xFF / 255, blue: 0x88 / 255, alpha: 1) }
  if value >= 15 { return NSColor(srgbRed: 0xFF / 255, green: 0xAA / 255, blue: 0x00 / 255, alpha: 1) }
  if value > 0 { return NSColor(srgbRed: 0xFF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1) }
  return NSColor(srgbRed: 0x3A / 255, green: 0x40 / 255, blue: 0x50 / 255, alpha: 1)
}

func formatMs(_ ms: Double?) -> String {
  guard let ms else { return "—" }
  if ms < 1000 { return "\(Int(ms.rounded())) ms" }
  return String(format: "%.2f s", ms / 1000)
}

func formatOne(_ value: Double?) -> String {
  guard let value else { return "—" }
  return String(format: "%.1f", value)
}

func truncate(_ text: String, toWidth width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
  if (text as NSString).size(withAttributes: attributes).width <= width { return text }
  var result = text
  while result.count > 1 {
    result.removeLast()
    let candidate = result + "…"
    if (candidate as NSString).size(withAttributes: attributes).width <= width { return candidate }
  }
  return "…"
}

final class OverlayView: NSView {
  var state = HubState()
  var onQuit: (() -> Void)?
  var onMoveEnd: (() -> Void)?

  private var dragStartScreen = NSPoint.zero
  private var dragStartOrigin = NSPoint.zero
  private var dragging = false

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  private let padX: CGFloat = 12
  private let padTop: CGFloat = 8

  private lazy var modelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
  private lazy var stateFont = NSFont.systemFont(ofSize: 10, weight: .regular)
  private lazy var bigFont = NSFont.monospacedDigitSystemFont(ofSize: 36, weight: .bold)
  private lazy var unitFont = NSFont.systemFont(ofSize: 11, weight: .regular)
  private lazy var metaFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

  private func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: color]
  }

  override func draw(_ dirtyRect: NSRect) {
    let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    NSColor(srgbRed: 0x10 / 255, green: 0x12 / 255, blue: 0x16 / 255, alpha: 0.92).setFill()
    card.fill()
    NSColor(srgbRed: 0x2A / 255, green: 0x30 / 255, blue: 0x40 / 255, alpha: 0.9).setStroke()
    card.lineWidth = 1
    card.stroke()

    let muted = NSColor(srgbRed: 0x7C / 255, green: 0x86 / 255, blue: 0x9B / 255, alpha: 1)

    // верхняя строка: модель слева, состояние справа
    let stateText = statusText()
    let stateAttrs = attributes(stateFont, muted)
    let stateWidth = (stateText as NSString).size(withAttributes: stateAttrs).width
    (stateText as NSString).draw(
      at: NSPoint(x: bounds.width - padX - stateWidth, y: padTop),
      withAttributes: stateAttrs,
    )

    let modelWidth = max(0, bounds.width - padX * 2 - stateWidth - 10)
    let modelAttrs = attributes(modelFont, muted)
    let modelText = truncate(state.model ?? "—", toWidth: modelWidth, attributes: modelAttrs)
    (modelText as NSString).draw(at: NSPoint(x: padX, y: padTop), withAttributes: modelAttrs)

    // крупное значение
    let tps = state.reachable && state.active ? state.tps : 0
    let color = state.reachable ? tpsColor(tps) : tpsColor(0)
    let scoreText = state.reachable ? String(format: "%.1f", tps) : "—"
    let scoreAttrs = attributes(bigFont, color)
    let scoreSize = (scoreText as NSString).size(withAttributes: scoreAttrs)
    let scoreY = padTop + 18
    (scoreText as NSString).draw(at: NSPoint(x: padX, y: scoreY), withAttributes: scoreAttrs)

    let unitAttrs = attributes(unitFont, muted)
    ("tok/s" as NSString).draw(
      at: NSPoint(x: padX + scoreSize.width + 6, y: scoreY + scoreSize.height - 18),
      withAttributes: unitAttrs,
    )

    // средняя скорость и TTFT
    let metaAttrs = attributes(metaFont, NSColor(srgbRed: 0xC9 / 255, green: 0xD1 / 255, blue: 0xE1 / 255, alpha: 1))
    for (index, line) in metaLines().enumerated() {
      let width = (line as NSString).size(withAttributes: metaAttrs).width
      (line as NSString).draw(
        at: NSPoint(x: bounds.width - padX - width, y: scoreY + 2 + CGFloat(index) * 17),
        withAttributes: metaAttrs,
      )
    }

    // полоса прогресса
    let barRect = NSRect(x: padX, y: bounds.height - 14, width: bounds.width - padX * 2, height: 4)
    NSColor(srgbRed: 0x20 / 255, green: 0x24 / 255, blue: 0x2E / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()
    let ratio = min(1, max(0, tps / 60))
    if ratio > 0 {
      let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: max(2, barRect.width * ratio), height: barRect.height)
      color.setFill()
      NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
    }
  }

  private func statusText() -> String {
    if !state.reachable { return "hub off" }
    if state.active {
      let gen = state.firstTokenAt > 0
        ? formatMs(Date().timeIntervalSince1970 * 1000 - state.firstTokenAt)
        : "—"
      let tokens = Int(state.tokens.rounded())
      return "tok \(tokens) | \(gen)"
    }
    return state.activeTurns > 1 ? "idle · \(state.activeTurns)" : "idle"
  }

  private func metaLines() -> [String] {
    if state.active {
      return ["avg  \(formatOne(state.avgTps))", "ttft \(formatMs(state.ttftMs))"]
    }
    if let last = state.lastTurn {
      return ["last \(formatOne(last.avgTps))", "ttft \(formatMs(last.ttftMs))"]
    }
    return ["avg  —", "ttft —"]
  }

  // MARK: мышь

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      onQuit?()
      return
    }
    guard let window else { return }
    dragging = true
    dragStartScreen = NSEvent.mouseLocation
    dragStartOrigin = window.frame.origin
  }

  override func mouseDragged(with event: NSEvent) {
    guard dragging, let window else { return }
    let now = NSEvent.mouseLocation
    window.setFrameOrigin(NSPoint(
      x: dragStartOrigin.x + (now.x - dragStartScreen.x),
      y: dragStartOrigin.y + (now.y - dragStartScreen.y),
    ))
  }

  override func mouseUp(with event: NSEvent) {
    guard dragging else { return }
    dragging = false
    onMoveEnd?()
  }
}

// MARK: - Панель и контроллер

final class OverlayPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

final class OverlayController: NSObject, NSApplicationDelegate {
  private let options: OverlayOptions
  private let panel: OverlayPanel
  private let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 292, height: 132))
  private let session: URLSession
  private var timer: Timer?
  private var failures = 0
  private var inFlight = false
  private var lastRestart = Date.distantPast
  private var state = HubState()

  init(options: OverlayOptions) {
    self.options = options
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 0.8
    configuration.timeoutIntervalForResource = 1.5
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: configuration)
    self.panel = OverlayPanel(
      contentRect: NSRect(x: 0, y: 0, width: 292, height: 132),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
    )
    super.init()
  }

  func start() {
    _ = NSApp.setActivationPolicy(.accessory)
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.isMovableByWindowBackground = false
    panel.isReleasedWhenClosed = false
    panel.contentView = view
    view.onQuit = { NSApp.terminate(nil) }
    view.onMoveEnd = { [weak self] in self?.savePosition() }
    placeWindow()
    panel.orderFrontRegardless()
    _ = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "DeepAI Code TPS overlay",
    )
    tick()
    let interval = TimeInterval(options.intervalMs) / 1000
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
    timer.tolerance = interval * 0.2
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func applicationWillTerminate(_ notification: Notification) {
    savePosition()
  }

  // MARK: опрос

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
      state = decoded
    } else {
      failures += 1
      state = HubState()
      if failures >= 8 { restartHubIfNeeded() }
    }
    view.state = state
    view.needsDisplay = true
  }

  private func restartHubIfNeeded() {
    guard !options.noWatchdog, !options.repoRoot.isEmpty else { return }
    let now = Date()
    if now.timeIntervalSince(lastRestart) < 20 { return }
    lastRestart = now
    let hubPath = options.repoRoot + "/tps-hub.mjs"
    guard FileManager.default.fileExists(atPath: hubPath) else { return }
    let logs = options.repoRoot + "/logs"
    try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
    let process = Process()
    if let node = options.nodePath, !node.isEmpty {
      process.executableURL = URL(fileURLWithPath: node)
      process.arguments = [hubPath, "--port", String(options.port)]
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["node", hubPath, "--port", String(options.port)]
    }
    if let out = Self.appendHandle(logs + "/hub.log") { process.standardOutput = out }
    if let err = Self.appendHandle(logs + "/hub.log.err") { process.standardError = err }
    do { try process.run() } catch {
      appendNote(logs + "/overlay.log.err", "hub restart failed: \(error)\n")
    }
  }

  private static func appendHandle(_ path: String) -> FileHandle? {
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
    handle.seekToEndOfFile()
    return handle
  }

  private func appendNote(_ path: String, _ text: String) {
    guard let handle = Self.appendHandle(path), let data = text.data(using: .utf8) else { return }
    handle.write(data)
    try? handle.close()
  }

  // MARK: позиция окна

  private var positionPath: String {
    options.repoRoot.isEmpty ? "" : options.repoRoot + "/overlay-pos.txt"
  }

  private func placeWindow() {
    let size = panel.frame.size
    if let saved = loadPosition(), isOnScreen(saved, size: size) {
      panel.setFrameOrigin(saved)
      return
    }
    panel.setFrameOrigin(defaultOrigin(for: size))
  }

  private func defaultOrigin(for size: NSSize) -> NSPoint {
    let screen = NSScreen.main ?? NSScreen.screens.first
    guard let frame = screen?.visibleFrame else { return NSPoint(x: 120, y: 120) }
    return NSPoint(x: frame.maxX - size.width - 24, y: frame.maxY - size.height - 80)
  }

  private func isOnScreen(_ origin: NSPoint, size: NSSize) -> Bool {
    let rect = NSRect(origin: origin, size: size).insetBy(dx: 40, dy: 40)
    return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
  }

  private func loadPosition() -> NSPoint? {
    guard !positionPath.isEmpty,
          let data = FileManager.default.contents(atPath: positionPath),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    let left = numberOf(object["left"]) ?? numberOf(object["Left"])
    let top = numberOf(object["top"]) ?? numberOf(object["Top"])
    guard let left, let top else { return nil }
    return NSPoint(x: left, y: top)
  }

  private func savePosition() {
    guard !positionPath.isEmpty else { return }
    let origin = panel.frame.origin
    let payload: [String: Any] = ["left": Double(origin.x), "top": Double(origin.y)]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    try? data.write(to: URL(fileURLWithPath: positionPath), options: .atomic)
  }
}

// MARK: - Точка входа

@main
enum TPSTool {
  static func main() {
    let options = parseOverlayOptions()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = OverlayController(options: options)
    app.delegate = controller
    controller.start()
    app.run()
  }
}
