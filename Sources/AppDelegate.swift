import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private enum Key {
        static let paused = "paused"
    }

    private let watcher = NotificationWindowWatcher()
    private let mirror = BannerMirror()
    private let bannerSignal = BannerSignal()
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var hasScreenAccess = false
    /// 창은 켜졌지만 아직 배너 신호를 기다리는 중인 알림 센터 창
    private var pendingWindow: NotificationWindowWatcher.SourceWindow?

    private var paused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set {
            defaults.set(newValue, forKey: Key.paused)
            updateWatching()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watcher.onShow = { [weak self] window in self?.notificationWindowShown(window) }
        watcher.onHide = { [weak self] in
            self?.pendingWindow = nil
            self?.mirror.hide()
        }
        bannerSignal.onBanner = { [weak self] in self?.bannerSignalReceived() }
        bannerSignal.start()

        if Diagnostics.isEnabled {
            // 진단 모드에서는 터미널에서도 테스트 알림을 보낼 수 있게 한다.
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(sendTestNotification),
                                                                name: Diagnostics.sendTestNotificationName, object: nil)
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                Log.write("진단: 알림 권한 상태 \(settings.authorizationStatus.rawValue) (0 미정, 1 거부, 2 허용)")
            }
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.write("시작 v\(version) screens=\(NSScreen.screens.count)")

        hasScreenAccess = CGPreflightScreenCaptureAccess()
        if !hasScreenAccess {
            Log.write("화면 기록 권한 없음 → 요청")
            CGRequestScreenCaptureAccess()
            // 권한을 켜면 macOS가 앱을 다시 열라고 안내하지만, 바로 반영되는 경우도 있어 주기적으로 확인한다.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkScreenAccess() }
            }
        }
        updateWatching()
    }

    private func checkScreenAccess() {
        guard CGPreflightScreenCaptureAccess() else { return }
        hasScreenAccess = true
        permissionTimer?.invalidate()
        permissionTimer = nil
        Log.write("화면 기록 권한 확인됨")
        updateWatching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        bannerSignal.stop()
    }

    // MARK: - 배너와 알림 센터 패널 구분

    /// 알림 센터 창은 배너를 띄울 때도, 사용자가 패널을 열 때도 켜진다.
    /// 배너 신호가 같이 와야만 복제하고, 0.6초 안에 안 오면 패널로 보고 무시한다.
    private func notificationWindowShown(_ window: NotificationWindowWatcher.SourceWindow) {
        guard bannerSignal.isAvailable else {
            // 신호를 못 받는 환경에서는 화면 추정(FrameOutput.looksLikeOpenPanel)에 맡긴다.
            mirror.show(window)
            return
        }
        if bannerSignal.firedRecently(within: 1.5) {
            mirror.show(window)
            return
        }
        pendingWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingWindow == window else { return }
                self.pendingWindow = nil
                Log.write("배너 신호 없이 알림 센터 창이 켜짐 → 사용자가 연 패널로 보고 복제 안 함")
            }
        }
    }

    private func bannerSignalReceived() {
        guard let window = pendingWindow else { return }
        pendingWindow = nil
        mirror.show(window)
    }

    private func updateWatching() {
        if hasScreenAccess && !paused {
            watcher.start()
        } else {
            watcher.stop()
        }
        updateStatusIcon()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusLine: String
        if !hasScreenAccess {
            statusLine = String(localized: "Screen Recording permission needed")
        } else if paused {
            statusLine = String(localized: "Paused")
        } else {
            statusLine = String(localized: "Running · \(NSScreen.screens.count) displays")
        }
        let statusMenuItem = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        if !hasScreenAccess {
            menu.addItem(item(String(localized: "Open Screen Recording Settings…"), #selector(openScreenRecordingSettings)))
        }

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Pause"), #selector(togglePaused), on: paused))
        menu.addItem(item(String(localized: "Open at Login"), #selector(toggleLoginItem),
                          on: SMAppService.mainApp.status == .enabled))

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Send Test Notification"), #selector(sendTestNotification)))
        menu.addItem(item(String(localized: "Show Log"), #selector(openLog)))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit NotiMirror"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func updateStatusIcon() {
        let symbol = !hasScreenAccess ? "exclamationmark.triangle"
            : paused ? "bell.slash"
            : "bell.and.waves.left.and.right"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NotiMirror")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: - Actions

    @objc private func togglePaused() {
        paused.toggle()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("로그인 항목 변경 실패: \(error)")
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    /// NotiMirror 이름으로 실제 시스템 알림을 보내서 감지 → 캡처 → 복제 전체 흐름을 확인한다.
    /// (macOS 27에서는 osascript로 보낸 알림이 표시되지 않는다.)
    @objc private func sendTestNotification() {
        Log.write("테스트 알림 요청")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                Log.write("알림 권한 거부됨: \(error.map { "\($0)" } ?? "-")")
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 권한 창에서 허용을 누르기까지 걸린 시간과 상관없이, 실제로 보내는 시점부터 저장을 기다린다.
                    self.mirror.armDiagnosticDump()
                    let content = UNMutableNotificationContent()
                    content.title = String(localized: "NotiMirror Test")
                    content.body = String(localized: "If this notification also appears on your other displays, everything is working.")
                    UNUserNotificationCenter.current().add(
                        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                }
            }
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 메뉴바 앱도 앞에 있는 앱으로 취급될 수 있어서, 테스트 알림이 배너로 뜨도록 명시한다.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
