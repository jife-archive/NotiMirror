// 앱 아이콘과 README 대표 이미지를 SwiftUI로 그려 PNG로 저장한다.
// 사용법: scripts/make-assets.sh (이 파일을 직접 실행하지 않아도 됨)
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

let ink = Color(hex: 0x1E2140)

// MARK: - 알림 카드 (아이콘과 대표 이미지에서 함께 사용)

struct BannerCard: View {
    var width: CGFloat
    var symbol = "bell.fill"
    var accent: [Color] = [Color(hex: 0xFFA24C), Color(hex: 0xFF5C7A)]

    var body: some View {
        let height = width * 0.3
        HStack(spacing: width * 0.055) {
            RoundedRectangle(cornerRadius: height * 0.2, style: .continuous)
                .fill(LinearGradient(colors: accent, startPoint: .top, endPoint: .bottom))
                .frame(width: height * 0.62, height: height * 0.62)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: height * 0.32, weight: .bold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: height * 0.13) {
                Capsule().fill(ink.opacity(0.82)).frame(width: width * 0.38, height: height * 0.12)
                Capsule().fill(ink.opacity(0.28)).frame(width: width * 0.52, height: height * 0.1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, width * 0.065)
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: height * 0.32, style: .continuous)
                .fill(Color.white.opacity(0.97))
        )
    }
}

// MARK: - 앱 아이콘 (1024 × 1024, macOS 아이콘 그리드: 824 squircle + 그림자 여백)

struct AppIconView: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(colors: [Color(hex: 0x4C8DFF), Color(hex: 0x6A4BF2)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                                   startPoint: .top, endPoint: .center)))
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)

            // 같은 알림이 양옆 화면으로 퍼지는 모습
            BannerCard(width: 320).opacity(0.5).offset(x: -175, y: -100)
            BannerCard(width: 320).opacity(0.5).offset(x: 175, y: -100)
            BannerCard(width: 560)
                .shadow(color: .black.opacity(0.22), radius: 26, y: 14)
                .offset(y: 95)
        }
        .frame(width: 1024, height: 1024)
    }
}

// MARK: - README 대표 이미지: 맥북 + 외장 모니터 2대에 같은 알림

struct Screen: View {
    var width: CGFloat
    var height: CGFloat
    var wallpaper: [Color]
    var bannerWidthRatio: CGFloat = 0.42

    var body: some View {
        let menuBar = height * 0.06
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.18)).frame(width: width * 0.7).blur(radius: 40)
                .offset(x: -width * 0.45, y: height * 0.35)
            // 메뉴 막대
            HStack(spacing: width * 0.02) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(ink.opacity(i == 0 ? 0.7 : 0.35))
                        .frame(width: width * (i == 0 ? 0.035 : 0.06), height: menuBar * 0.32)
                }
                Spacer()
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(ink.opacity(0.35)).frame(width: width * 0.03, height: menuBar * 0.32)
                }
            }
            .padding(.horizontal, width * 0.025)
            .frame(width: width, height: menuBar)
            .background(.white.opacity(0.55))

            BannerCard(width: width * bannerWidthRatio,
                       symbol: "bubble.left.fill",
                       accent: [Color(hex: 0x34C759), Color(hex: 0x1FA64A)])
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.top, menuBar + height * 0.03)
                .padding(.trailing, width * 0.025)
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

struct Monitor: View {
    var wallpaper: [Color]

    var body: some View {
        VStack(spacing: 0) {
            Screen(width: 500, height: 290, wallpaper: wallpaper)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0x1B1C22)))
            Rectangle()
                .fill(LinearGradient(colors: [Color(hex: 0xC9CDD6), Color(hex: 0xAEB3BF)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 64, height: 62)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xD9DCE3), Color(hex: 0xB4B9C4)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 210, height: 14)
        }
    }
}

struct MacBook: View {
    var wallpaper: [Color]

    var body: some View {
        VStack(spacing: 0) {
            Screen(width: 420, height: 272, wallpaper: wallpaper, bannerWidthRatio: 0.44)
                .overlay(alignment: .top) {
                    // 노치
                    UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6, style: .continuous)
                        .fill(Color(hex: 0x1B1C22))
                        .frame(width: 54, height: 12)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous)
                    .fill(Color(hex: 0x1B1C22)))
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xDDE0E7), Color(hex: 0xADB2BE)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 540, height: 20)
                UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5, style: .continuous)
                    .fill(Color(hex: 0x9EA3AF))
                    .frame(width: 90, height: 6)
            }
        }
    }
}

struct HeroView: View {
    // 각 화면의 알림 카드 위쪽 가운데 좌표 (아래 배치에서 계산한 값)
    let leftBanner = CGPoint(x: 462, y: 168)
    let centerBanner = CGPoint(x: 957, y: 272)
    let rightBanner = CGPoint(x: 1502, y: 168)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xEDF1FF), Color(hex: 0xF6F1FF)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            // 책상 그림자
            ForEach([CGPoint(x: 330, y: 524), CGPoint(x: 1370, y: 524), CGPoint(x: 850, y: 556)], id: \.x) { p in
                Ellipse().fill(ink.opacity(0.10)).frame(width: p.x == 850 ? 560 : 260, height: 22)
                    .blur(radius: 8).position(p)
            }

            Monitor(wallpaper: [Color(hex: 0x5AA8FF), Color(hex: 0x8C7BFF)])
                .position(x: 330, y: 130 + 390 / 2)
            Monitor(wallpaper: [Color(hex: 0x3DDCC4), Color(hex: 0x3A8DFF)])
                .position(x: 1370, y: 130 + 390 / 2)
            MacBook(wallpaper: [Color(hex: 0xFFA48C), Color(hex: 0xFF6F91)])
                .position(x: 850, y: 238 + 314 / 2)

            // 맥북의 원본 알림에서 양쪽 모니터로 복제되는 화살표
            MirrorArrow(from: centerBanner, to: leftBanner)
            MirrorArrow(from: centerBanner, to: rightBanner)
        }
        .frame(width: 1700, height: 610)
    }
}

struct MirrorArrow: View {
    var from: CGPoint
    var to: CGPoint

    var body: some View {
        let color = Color(hex: 0x5B4BE0)
        let start = CGPoint(x: from.x, y: from.y - 10)
        let end = CGPoint(x: to.x, y: to.y - 12)
        // 원본에서 위로 올라갔다가 복제본 위에서 수직으로 내려꽂히는 곡선
        let control1 = CGPoint(x: start.x + (end.x > start.x ? 60 : -60), y: 70)
        let control2 = CGPoint(x: end.x, y: 40)
        let angle = atan2(end.y - control2.y, end.x - control2.x)
        let size: CGFloat = 16
        ZStack {
            Path { p in
                p.move(to: start)
                p.addCurve(to: end, control1: control1, control2: control2)
            }
            .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 12]))
            Path { p in
                p.move(to: CGPoint(x: end.x - size * cos(angle - .pi / 6), y: end.y - size * sin(angle - .pi / 6)))
                p.addLine(to: end)
                p.addLine(to: CGPoint(x: end.x - size * cos(angle + .pi / 6), y: end.y - size * sin(angle + .pi / 6)))
            }
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - 렌더링

@MainActor
func save<V: View>(_ view: V, scale: CGFloat, to path: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.cgImage else { fatalError("렌더링 실패: \(path)") }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("파일 생성 실패: \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("저장: \(path) (\(image.width)×\(image.height))")
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
MainActor.assumeIsolated {
    save(AppIconView(), scale: 1, to: "\(outputDir)/icon-1024.png")
    save(HeroView(), scale: 1.2, to: "\(outputDir)/hero.png")
}
