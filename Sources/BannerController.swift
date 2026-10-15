import AppKit
import QuartzCore
import SwiftUI

final class BannerPanel: NSPanel {
    let displayID: CGDirectDisplayID
    let recordID: Int64
    var isHovered = false
    var dismissWork: DispatchWorkItem?

    init(displayID: CGDirectDisplayID, recordID: Int64) {
        self.displayID = displayID
        self.recordID = recordID
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // 그림자는 SwiftUI glass가 그린다
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// 모니터마다 우측 상단에 배너를 쌓아서 보여준다.
@MainActor
final class BannerController {
    var displayDuration: TimeInterval = 6
    /// macOS가 원본 배너를 주 디스플레이에 띄우므로 기본값은 주 디스플레이 제외.
    var includePrimaryScreen = false

    private var stacks: [CGDirectDisplayID: [BannerPanel]] = [:]
    private var appCache: [String: AppInfo] = [:]
    private let maxPerScreen = 4
    private let edgeInset: CGFloat = 6   // BannerView의 8pt 여백과 합쳐 화면 가장자리에서 14pt
    private let overlap: CGFloat = 6     // 카드 사이 간격 = 8 + 8 - 6 = 10pt

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutAll() }
        }
    }

    var targetScreens: [NSScreen] {
        let screens = NSScreen.screens
        return includePrimaryScreen ? screens : Array(screens.dropFirst())
    }

    func show(_ record: NotificationRecord) {
        let app = appInfo(for: record.bundleID)
        for screen in targetScreens {
            present(record, app: app, on: screen)
        }
    }

    // MARK: - Presenting

    private func present(_ record: NotificationRecord, app: AppInfo, on screen: NSScreen) {
        guard let displayID = screen.displayID else { return }
        if let stack = stacks[displayID], stack.count >= maxPerScreen, let oldest = stack.last {
            dismiss(oldest)
        }

        let panel = BannerPanel(displayID: displayID, recordID: record.recordID)
        let state = BannerState()
        let view = BannerView(record: record, app: app, state: state,
                              onOpen: { [weak self] in
                                  app.activate()
                                  self?.dismissRecord(record.recordID)
                              },
                              onClose: { [weak self] in self?.dismissRecord(record.recordID) })
        let hosting = BannerHostingView(rootView: view)
        hosting.onHoverChange = { [weak self, weak panel] hovering in
            state.hovering = hovering
            guard let self, let panel else { return }
            panel.isHovered = hovering
            if !hovering { self.scheduleDismiss(panel, after: 2) }
        }
        let size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(size)

        stacks[displayID, default: []].insert(panel, at: 0)
        layout(displayID, newcomer: panel)
        scheduleDismiss(panel, after: displayDuration)
    }

    private func layout(_ displayID: CGDirectDisplayID, newcomer: BannerPanel? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            stacks[displayID]?.forEach { $0.orderOut(nil) }
            stacks[displayID] = nil
            return
        }
        let visible = screen.visibleFrame
        var top = visible.maxY - edgeInset
        for panel in stacks[displayID] ?? [] {
            let size = panel.frame.size
            let target = NSRect(x: visible.maxX - size.width - edgeInset, y: top - size.height,
                                width: size.width, height: size.height)
            top = target.minY + overlap
            if panel === newcomer {
                panel.setFrame(target.offsetBy(dx: 30, dy: 0), display: false)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                    panel.animator().alphaValue = 1
                }
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    panel.animator().setFrame(target, display: true)
                }
            }
        }
    }

    private func relayoutAll() {
        for displayID in stacks.keys {
            layout(displayID)
        }
    }

    // MARK: - Dismissing

    private func scheduleDismiss(_ panel: BannerPanel, after delay: TimeInterval) {
        panel.dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            MainActor.assumeIsolated {
                // 마우스가 올라가 있으면 유지하고, 벗어날 때 다시 예약한다.
                guard let self, let panel, !panel.isHovered else { return }
                self.dismiss(panel)
            }
        }
        panel.dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 한 화면에서 닫거나 클릭하면 다른 화면의 같은 알림도 함께 닫는다.
    private func dismissRecord(_ recordID: Int64) {
        for panel in stacks.values.joined() where panel.recordID == recordID {
            dismiss(panel)
        }
    }

    private func dismiss(_ panel: BannerPanel) {
        guard var stack = stacks[panel.displayID],
              let index = stack.firstIndex(where: { $0 === panel }) else { return }
        stack.remove(at: index)
        stacks[panel.displayID] = stack
        panel.dismissWork?.cancel()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        layout(panel.displayID)
    }

    private func appInfo(for bundleID: String) -> AppInfo {
        if let cached = appCache[bundleID] { return cached }
        let info = AppInfo.lookup(bundleID)
        appCache[bundleID] = info
        return info
    }
}
