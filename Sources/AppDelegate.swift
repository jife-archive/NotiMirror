import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Status: Equatable {
        case starting
        case running
        case needsAccess(String)
        case failed(String)
    }

    private enum Key {
        static let paused = "paused"
        static let includePrimary = "includePrimaryScreen"
        static let duration = "displayDuration"
    }

    private let store = NotificationStore()
    private let banners = BannerController()
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var reconnectCountdown = 0
    private var didPromptForAccess = false
    private var previewCounter: Int64 = 0
    private var status: Status = .starting {
        didSet { if status != oldValue { updateStatusIcon() } }
    }

    private var paused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set { defaults.set(newValue, forKey: Key.paused); updateStatusIcon() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [Key.paused: false, Key.includePrimary: false, Key.duration: 6.0])
        banners.includePrimaryScreen = defaults.bool(forKey: Key.includePrimary)
        banners.displayDuration = defaults.double(forKey: Key.duration)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.write("시작 v\(version) screens=\(NSScreen.screens.count)")
        connect()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - Polling

    private func connect() {
        do {
            try store.open()
            status = .running
            Log.write("DB 연결 성공 \(store.schemaSummary)")
        } catch {
            let message = "\(error)"
            let newStatus: Status = message.contains("authorization") || message.contains("unable to open")
                || message.contains("(14)") || message.contains("(23)")
                ? .needsAccess(message) : .failed(message)
            if newStatus != status { Log.write("DB 연결 실패: \(message)") }
            status = newStatus
            if case .needsAccess = newStatus, !didPromptForAccess {
                didPromptForAccess = true
                promptForAccess()
            }
        }
    }

    private func tick() {
        guard store.isOpen else {
            // 권한을 방금 받았을 수도 있으니 3초마다 다시 시도한다.
            reconnectCountdown -= 1
            if reconnectCountdown <= 0 {
                reconnectCountdown = 4
                connect()
            }
            return
        }
        do {
            let records = try store.fetchNew()
            guard !paused else { return }
            records.forEach(banners.show)
        } catch {
            Log.write("조회 실패: \(error)")
            store.close()
            status = .failed("\(error)")
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusLine: String
        switch status {
        case .starting: statusLine = "시작하는 중…"
        case .running:
            let all = NSScreen.screens.count
            statusLine = paused ? "일시 정지됨" : "작동 중 · 모니터 \(all)대 중 \(banners.targetScreens.count)대에 복제"
        case .needsAccess: statusLine = "전체 디스크 접근 권한 필요"
        case .failed(let message): statusLine = "오류: \(message.prefix(60))"
        }
        let statusMenuItem = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        if status != .running {
            menu.addItem(item("전체 디스크 접근 권한 설정 열기…", #selector(openFullDiskAccess)))
        }

        menu.addItem(.separator())
        menu.addItem(item("일시 정지", #selector(togglePaused), on: paused))
        menu.addItem(item("주 디스플레이에도 표시", #selector(togglePrimary), on: banners.includePrimaryScreen))
        let durationItem = NSMenuItem(title: "표시 시간", action: nil, keyEquivalent: "")
        let durations = NSMenu()
        for seconds in [4, 6, 10, 20] {
            let option = item("\(seconds)초", #selector(setDuration(_:)), on: Int(banners.displayDuration) == seconds)
            option.tag = seconds
            durations.addItem(option)
        }
        durationItem.submenu = durations
        menu.addItem(durationItem)
        menu.addItem(item("로그인 시 자동 실행", #selector(toggleLoginItem),
                          on: SMAppService.mainApp.status == .enabled))

        menu.addItem(.separator())
        menu.addItem(item("배너 미리보기", #selector(showPreview)))
        menu.addItem(item("테스트 알림 보내기", #selector(sendTestNotification)))
        menu.addItem(item("로그 보기", #selector(openLog)))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "NotiMirror 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let symbol: String
        switch status {
        case .starting: symbol = "bell"
        case .running: symbol = paused ? "bell.slash" : "bell.and.waves.left.and.right"
        case .needsAccess, .failed: symbol = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NotiMirror")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: - Actions

    @objc private func togglePaused() {
        paused.toggle()
    }

    @objc private func togglePrimary() {
        banners.includePrimaryScreen.toggle()
        defaults.set(banners.includePrimaryScreen, forKey: Key.includePrimary)
    }

    @objc private func setDuration(_ sender: NSMenuItem) {
        banners.displayDuration = TimeInterval(sender.tag)
        defaults.set(banners.displayDuration, forKey: Key.duration)
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

    @objc private func showPreview() {
        previewCounter -= 1
        banners.show(NotificationRecord(recordID: previewCounter, bundleID: "com.apple.finder",
                                        title: "NotiMirror 미리보기",
                                        subtitle: "",
                                        body: "다른 모니터에도 알림이 이렇게 표시됩니다. 클릭하면 앱이 열리고, 마우스를 올리면 사라지지 않아요."))
    }

    /// 실제 시스템 알림을 하나 보내서 DB 감시 → 복제까지 전체 경로를 확인한다.
    @objc private func sendTestNotification() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", #"display notification "다른 모니터에도 이 알림이 보이면 정상이에요." with title "NotiMirror 테스트""#]
        do {
            try process.run()
        } catch {
            Log.write("테스트 알림 실패: \(error)")
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        // 목록에 앱이 없으면 Finder에서 끌어다 놓을 수 있게 위치를 보여준다.
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func promptForAccess() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "전체 디스크 접근 권한이 필요해요"
        alert.informativeText = """
            NotiMirror는 macOS 알림 기록을 읽어서 다른 모니터에 같은 알림을 띄웁니다.

            시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근 권한에서 NotiMirror를 켜 주세요. \
            목록에 없으면 + 버튼을 누르거나, 함께 열리는 Finder 창에서 NotiMirror를 목록으로 끌어다 놓으면 됩니다.

            권한을 켜면 몇 초 안에 자동으로 연결됩니다.
            """
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "나중에")
        if alert.runModal() == .alertFirstButtonReturn {
            openFullDiskAccess()
        }
    }
}
