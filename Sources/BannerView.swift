import AppKit
import SwiftUI

struct AppInfo {
    let name: String
    let icon: NSImage
    let url: URL?

    static func lookup(_ bundleID: String) -> AppInfo {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            return AppInfo(name: name, icon: NSWorkspace.shared.icon(forFile: url.path), url: url)
        }
        let fallback = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil) ?? NSImage()
        return AppInfo(name: bundleID, icon: fallback, url: nil)
    }

    func activate() {
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

final class BannerState: ObservableObject {
    @Published var hovering = false
}

/// macOS 알림 배너와 비슷한 모양의 카드. 바깥 8pt 여백은 그림자와 닫기 버튼 자리.
struct BannerView: View {
    let record: NotificationRecord
    let app: AppInfo
    @ObservedObject var state: BannerState
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.title.isEmpty ? app.name : record.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(app.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !record.subtitle.isEmpty {
                    Text(record.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                if !record.body.isEmpty {
                    Text(record.body)
                        .font(.system(size: 13))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 344, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .contentShape(.rect(cornerRadius: 22))
        .onTapGesture(perform: onOpen)
        .overlay(alignment: .topLeading) {
            if state.hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .offset(x: -6, y: -6)
            }
        }
        .padding(8)
    }
}

/// 비활성 패널에서도 첫 클릭을 받고, 마우스가 올라가 있는지 추적한다.
final class BannerHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["banner"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: ["banner": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}
