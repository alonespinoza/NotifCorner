// NotifCorner: moves macOS notifications to the screen corner you pick.
//
// How it works: Notification Center (com.apple.notificationcenterui) draws all
// notifications inside one big window. Single notifications cannot be moved, only
// that window. So we find the notification list inside it and move the whole
// window until the list sits where we want.
//
// Order: macOS puts the newest notification at the BOTTOM of the list. For the
// bottom positions we pin the list's bottom edge, so the newest one is always in
// the corner and older ones are pushed up.

import ApplicationServices
import Cocoa
import ServiceManagement
import SwiftUI

private let notificationCenterBundleID = "com.apple.notificationcenterui"
private let bannerSubroles: Set<String> = [
  "AXNotificationCenterBanner", "AXNotificationCenterAlert", "AXNotificationCenterAlertStack",
  "AXNotificationCenterNotification", "AXNotificationCenterBannerWindow",
]
private let listIdentifier = "AXNotificationListItems"
private let maxNodesPerWindow = 5_000

// MARK: - Settings

enum Position: String, CaseIterable, Identifiable {
  case topLeft, topCenter, topRight
  case middleLeft, center, middleRight
  case bottomLeft, bottomCenter, bottomRight
  var id: String { rawValue }

  enum Column { case left, center, right }
  enum Row { case top, middle, bottom }

  var column: Column {
    switch self {
    case .topLeft, .middleLeft, .bottomLeft: .left
    case .topCenter, .center, .bottomCenter: .center
    case .topRight, .middleRight, .bottomRight: .right
    }
  }
  var row: Row {
    switch self {
    case .topLeft, .topCenter, .topRight: .top
    case .middleLeft, .center, .middleRight: .middle
    case .bottomLeft, .bottomCenter, .bottomRight: .bottom
    }
  }
  var label: String {
    switch self {
    case .topLeft: "Top left"
    case .topCenter: "Top center"
    case .topRight: "Top right"
    case .middleLeft: "Middle left"
    case .center: "Center"
    case .middleRight: "Middle right"
    case .bottomLeft: "Bottom left"
    case .bottomCenter: "Bottom center"
    case .bottomRight: "Bottom right"
    }
  }
}

private enum Key {
  static let enabled = "enabled"
  static let position = "position"
  static let margin = "margin"
}

private enum Settings {
  static var enabled: Bool { UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true }
  static var position: Position {
    UserDefaults.standard.string(forKey: Key.position).flatMap(Position.init) ?? .bottomRight
  }
  static var margin: CGFloat {
    CGFloat(UserDefaults.standard.object(forKey: Key.margin) as? Double ?? 16)
  }
}

// MARK: - Small Accessibility helpers

extension AXUIElement {
  fileprivate func value<T>(_ name: String) -> T? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(self, name as CFString, &raw) == .success else { return nil }
    return raw as? T
  }

  fileprivate var frame: CGRect? {
    guard let posValue: AXValue = value(kAXPositionAttribute),
      let sizeValue: AXValue = value(kAXSizeAttribute)
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posValue, .cgPoint, &origin),
      AXValueGetValue(sizeValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  @discardableResult
  fileprivate func setOrigin(_ point: CGPoint) -> AXError {
    var p = point
    guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
    return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, v)
  }

  fileprivate var children: [AXUIElement] {
    let direct: [AXUIElement] = value(kAXChildrenAttribute) ?? []
    let ordered: [AXUIElement] = value("AXOrderedChildren") ?? []
    var seen = Set<AXUIElement>()
    return (direct + ordered).filter { seen.insert($0).inserted }
  }
}

/// What we found inside one Notification Center window.
private enum WindowContent {
  /// The frame (screen coordinates) of everything that is visible: the whole list.
  case notifications(CGRect)
  /// The Notification Center side panel, desktop widgets, or nothing visible.
  case skip
}

private func inspect(_ window: AXUIElement) -> WindowContent {
  var stack = [window]
  var visited = Set<AXUIElement>()
  var listFrame: CGRect?
  var itemsUnion: CGRect?
  while let el = stack.popLast() {
    guard visited.insert(el).inserted, visited.count <= maxNodesPerWindow else { continue }
    if let id: String = el.value(kAXIdentifierAttribute) {
      if id == "widget-editor-button" || id.hasPrefix("widget-local:") { return .skip }
      if id == listIdentifier, let f = el.frame, f.height > 0 { listFrame = f }
    }
    if let sub: String = el.value(kAXSubroleAttribute), bannerSubroles.contains(sub),
      let f = el.frame
    {
      itemsUnion = itemsUnion.map { $0.union(f) } ?? f
      continue  // no need to look inside a notification
    }
    stack.append(contentsOf: el.children)
  }
  guard let items = itemsUnion else { return .skip }
  // Prefer the list container; fall back to the union of the items we found.
  return .notifications(listFrame.map { $0.union(items) } ?? items)
}

private func axCallback(
  _: AXObserver, _: AXUIElement, _: CFString, _ refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue().refresh()
}

// MARK: - Mover

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var observer: AXObserver?
  private var ncPID: pid_t = 0
  private var statusItem: NSStatusItem?
  private var settingsWindow: NSWindow?
  private var watchedWindows = Set<AXUIElement>()
  /// Original window origin, saved the first time we move a window, so we can put it back.
  private var originalOrigin = [AXUIElement: CGPoint]()
  /// The list changes size when notifications come and go; a short timer keeps it pinned.
  private var followTimer: Timer?

  func applicationDidFinishLaunching(_: Notification) {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(opts) {
      start()
    } else {
      // macOS shows its own prompt. Start as soon as access is granted.
      Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
        guard AXIsProcessTrusted() else { return }
        t.invalidate()
        self?.start()
      }
      showSettings()
    }
    setupMenu()

    // If Notification Center restarts (new process ID), attach again.
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      if app?.bundleIdentifier == notificationCenterBundleID { self?.start() }
    }
    // Settings changed in the window: apply right away.
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.refresh() }
    // Screen layout or Dock size changed.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.refresh() }
  }

  private func start() {
    guard
      let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == notificationCenterBundleID
      })
    else { return }
    if let old = observer {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(old), .defaultMode)
    }
    observer = nil
    watchedWindows.removeAll()
    originalOrigin.removeAll()
    ncPID = app.processIdentifier

    var obs: AXObserver?
    guard AXObserverCreate(ncPID, axCallback, &obs) == .success, let obs else { return }
    observer = obs
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

    watch(AXUIElementCreateApplication(ncPID), [kAXWindowCreatedNotification, "AXChildrenChanged"])
    refresh()
  }

  private func watch(_ el: AXUIElement, _ names: [String]) {
    guard let observer else { return }
    let me = Unmanaged.passUnretained(self).toOpaque()
    for n in names { AXObserverAddNotification(observer, el, n as CFString, me) }
  }

  private var windows: [AXUIElement] {
    guard ncPID != 0 else { return [] }
    return AXUIElementCreateApplication(ncPID).value(kAXWindowsAttribute) ?? []
  }

  /// Called on every Notification Center change. Moves windows into place.
  func refresh() {
    let current = Set(windows)
    watchedWindows.formIntersection(current)
    originalOrigin = originalOrigin.filter { current.contains($0.key) }
    for w in current where watchedWindows.insert(w).inserted {
      watch(w, ["AXChildrenChanged", kAXCreatedNotification, kAXUIElementDestroyedNotification])
    }
    for w in current { place(w) }

    // While something is on screen, re-check often so the list stays pinned as it resizes.
    if originalOrigin.isEmpty {
      followTimer?.invalidate()
      followTimer = nil
    } else if followTimer == nil {
      followTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        self?.refresh()
      }
    }
  }

  private func place(_ window: AXUIElement) {
    guard Settings.enabled, case .notifications(let list) = inspect(window),
      let winFrame = window.frame
    else {
      restore(window)
      return
    }
    // Work out which screen the notifications belong to from the ORIGINAL window spot.
    let original = originalOrigin[window] ?? winFrame.origin
    guard let area = visibleArea(near: CGRect(origin: original, size: winFrame.size)) else { return }

    let m = Settings.margin
    let pos = Settings.position
    let x: CGFloat =
      switch pos.column {
      case .left: area.minX + m
      case .center: area.midX - list.width / 2
      case .right: area.maxX - m - list.width
      }
    let y: CGFloat =
      switch pos.row {
      case .top: area.minY + m  // list grows down from the top
      case .middle: area.midY - list.height / 2
      case .bottom: area.maxY - m - list.height  // list grows up; newest stays in the corner
      }

    // Move the window by the same amount the list needs to move.
    let target = CGPoint(
      x: winFrame.minX + (x - list.minX),
      y: winFrame.minY + (y - list.minY))
    guard abs(target.x - winFrame.minX) > 0.5 || abs(target.y - winFrame.minY) > 0.5 else {
      originalOrigin[window] = original
      return
    }
    if window.setOrigin(target) == .success { originalOrigin[window] = original }
  }

  private func restore(_ window: AXUIElement) {
    guard let origin = originalOrigin.removeValue(forKey: window) else { return }
    window.setOrigin(origin)
  }

  /// The screen's usable area (without menu bar and Dock), in Accessibility
  /// coordinates (origin at the top-left of the main screen, y grows down).
  private func visibleArea(near axRect: CGRect) -> CGRect? {
    guard let mainTop = NSScreen.screens.first?.frame.maxY else { return nil }
    let center = CGPoint(x: axRect.midX, y: mainTop - axRect.minY - 1)
    let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    guard let v = screen?.visibleFrame else { return nil }
    return CGRect(x: v.minX, y: mainTop - v.maxY, width: v.width, height: v.height)
  }

  // MARK: Menu bar

  private func setupMenu() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem?.button?.image = NSImage(
      systemSymbolName: "bell.badge", accessibilityDescription: "NotifCorner")
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit NotifCorner", action: #selector(quit), keyEquivalent: "q"))
    menu.items.forEach { $0.target = self }
    statusItem?.menu = menu
  }

  @objc func showSettings() {
    if settingsWindow == nil {
      let w = NSWindow(
        contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      w.title = "NotifCorner"
      w.contentViewController = NSHostingController(rootView: SettingsView())
      w.isReleasedWhenClosed = false
      w.center()
      settingsWindow = w
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  /// Put Notification Center back where it was, however the app is quit.
  func applicationWillTerminate(_: Notification) {
    windows.forEach(restore)
  }
}

// MARK: - Settings window

struct SettingsView: View {
  @AppStorage(Key.enabled) private var enabled = true
  @AppStorage(Key.position) private var position = Position.bottomRight.rawValue
  @AppStorage(Key.margin) private var margin = 16.0
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var hasAccess = AXIsProcessTrusted()
  private let accessTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    Form {
      if !hasAccess {
        Section {
          Label(
            "Give NotifCorner access in System Settings → Privacy & Security → Accessibility.",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.orange)
          Button("Open Accessibility settings") {
            NSWorkspace.shared.open(
              URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
          }
        }
      }

      Section {
        Toggle("Move notifications", isOn: $enabled)
      }

      Section("Position") {
        PositionGrid(selection: $position)
          .disabled(!enabled)
        Text(orderHint)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section("Distance from screen edge") {
        HStack {
          Slider(value: $margin, in: 0...120, step: 2)
          Text("\(Int(margin)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
        }
        .disabled(!enabled)
      }

      Section {
        Toggle("Launch at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, on in
            do {
              if on { try SMAppService.mainApp.register() } else {
                try SMAppService.mainApp.unregister()
              }
            } catch {
              launchAtLogin = SMAppService.mainApp.status == .enabled
            }
          }
        Button("Send a test notification") {
          let p = Process()
          p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
          p.arguments = [
            "-e", "display notification \"This is where notifications will appear.\" with title \"NotifCorner test\"",
          ]
          try? p.run()
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 380)
    .fixedSize(horizontal: false, vertical: true)
    .onReceive(accessTimer) { _ in hasAccess = AXIsProcessTrusted() }
  }

  private var orderHint: String {
    switch Position(rawValue: position)?.row ?? .bottom {
    case .bottom: "Newest at the bottom, in the corner. Older ones move up."
    case .top: "Newest at the bottom of the list. The list grows down from the top."
    case .middle: "Newest at the bottom. The list stays centered as it grows."
    }
  }
}

/// A 3×3 grid that looks like a small screen. Click a cell to pick the position.
struct PositionGrid: View {
  @Binding var selection: String

  var body: some View {
    let rows: [[Position]] = [
      [.topLeft, .topCenter, .topRight],
      [.middleLeft, .center, .middleRight],
      [.bottomLeft, .bottomCenter, .bottomRight],
    ]
    VStack(spacing: 8) {
      Grid(horizontalSpacing: 6, verticalSpacing: 6) {
        ForEach(rows, id: \.first!.id) { row in
          GridRow {
            ForEach(row) { pos in
              let selected = pos.rawValue == selection
              Button {
                selection = pos.rawValue
              } label: {
                RoundedRectangle(cornerRadius: 4)
                  .fill(selected ? Color.accentColor : Color.secondary.opacity(0.18))
                  .frame(width: 70, height: 36)
                  .overlay(
                    Image(systemName: "bell.fill")
                      .font(.caption)
                      .foregroundStyle(selected ? .white : .secondary)
                  )
              }
              .buttonStyle(.plain)
              .help(pos.label)
            }
          }
        }
      }
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.4)))
      Text(Position(rawValue: selection)?.label ?? "")
        .font(.headline)
    }
    .frame(maxWidth: .infinity)
  }
}

@main
enum Main {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
    app.run()
  }
}
