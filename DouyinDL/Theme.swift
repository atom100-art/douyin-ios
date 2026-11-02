import SwiftUI
import UIKit

enum Palette {
    static let bg = Color(red: 8 / 255, green: 8 / 255, blue: 11 / 255)
    static let red = Color(red: 254 / 255, green: 44 / 255, blue: 85 / 255)
    static let redDeep = Color(red: 196 / 255, green: 16 / 255, blue: 58 / 255)
    static let purple = Color(red: 0.42, green: 0.35, blue: 1.0)
    static let cyan = Color(red: 0.0, green: 0.72, blue: 0.78)
    static let amber = Color(red: 1.0, green: 0.55, blue: 0.24)
    static let dim = Color(white: 0.68)
    static let faint = Color(white: 0.46)
}

struct AuroraBackground: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            ZStack {
                Palette.bg
                ZStack {
                    blob(Palette.red, w * 1.10, -w * 0.30, -h * 0.32, 0.60)
                    blob(Palette.purple, w * 0.95, w * 0.40, -h * 0.06, 0.38)
                    blob(Palette.cyan, w * 1.00, -w * 0.36, h * 0.20, 0.30)
                    blob(Palette.amber, w * 0.80, w * 0.36, h * 0.36, 0.24)
                }
                .blur(radius: 72)

                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.08), location: 0),
                        .init(color: Color.black.opacity(0.42), location: 0.55),
                        .init(color: Color.black.opacity(0.82), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .background(Palette.bg)
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ alpha: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(colors: [color.opacity(alpha), color.opacity(0)],
                               center: .center, startRadius: 0, endRadius: size / 2)
            )
            .frame(width: size, height: size)
            .offset(x: x, y: y)
    }
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Color.white.opacity(0.10), .clear],
                                           startPoint: .top, endPoint: .center)
                        )
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.38),
                                         Color.white.opacity(0.05),
                                         Color.white.opacity(0.16)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                }
            }
            .shadow(color: Color.black.opacity(0.35), radius: 22, y: 10)
    }
}

extension View {
    func glass(radius: CGFloat = 22) -> some View {
        modifier(GlassCard(radius: radius))
    }
}

/// 主按钮：红渐变胶囊 + 外发光
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background {
                Capsule().fill(
                    LinearGradient(colors: enabled
                                   ? [Color(red: 255 / 255, green: 92 / 255, blue: 126 / 255), Palette.red, Palette.redDeep]
                                   : [Color(white: 0.30), Color(white: 0.24)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            }
            .shadow(color: Palette.red.opacity(enabled ? 0.42 : 0), radius: 18, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.dim)
            .frame(height: 50)
            .padding(.horizontal, 20)
            .background {
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.075))
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 带 Referer 的图片加载（抖音 CDN 有防盗链，AsyncImage 会 403）
@MainActor
final class RemoteImage: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private static let cache = NSCache<NSString, UIImage>()
    private var task: Task<Void, Never>?

    nonisolated init() {}

    static func warmCache() {
        cache.countLimit = 120
    }

    func load(_ urlStr: String) {
        if image != nil { return }
        let key = urlStr as NSString
        if let hit = RemoteImage.cache.object(forKey: key) {
            image = hit
            return
        }
        task?.cancel()
        task = Task { [weak self] in
            guard let u = URL(string: urlStr) else {
                self?.failed = true
                return
            }
            var req = URLRequest(url: u)
            req.setValue(Net.mobileUA, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
            req.timeoutInterval = 25
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let img = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                RemoteImage.cache.setObject(img, forKey: key)
                if !Task.isCancelled { self?.image = img }
            } catch {
                if !Task.isCancelled { self?.failed = true }
            }
        }
    }
}

struct RemoteImageView: View {
    let url: String
    var contentMode: ContentMode = .fill

    @StateObject private var loader = RemoteImage()

    var body: some View {
        GeometryReader { g in
            ZStack {
                Rectangle().fill(Color.white.opacity(0.05))
                if let img = loader.image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                } else if loader.failed {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.system(size: 22))
                        Text("加载失败").font(.system(size: 12))
                    }
                    .foregroundStyle(Palette.faint)
                } else {
                    ProgressView().tint(Palette.dim)
                }
            }
        }
        .onAppear { loader.load(url) }
    }
}
