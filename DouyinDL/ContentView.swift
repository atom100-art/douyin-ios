import SwiftUI
import UIKit

// MARK: - ViewModel

@MainActor
final class DLViewModel: ObservableObject {
    @Published var input = ""
    @Published var loading = false
    @Published var work: ParsedWork?
    @Published var error: String?
    @Published var toast: String?
    @Published var saving: Set<UUID> = []
    @Published var saved: Set<UUID> = []
    @Published var batchProgress: (done: Int, total: Int)?

    private var toastTask: Task<Void, Never>?

    nonisolated init() {}

    func say(_ s: String) {
        toast = s
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if !Task.isCancelled { await MainActor.run { self?.toast = nil } }
        }
    }

    func paste() {
        if let s = UIPasteboard.general.string, !s.isEmpty {
            input = s
            say("已粘贴")
        } else {
            say("剪贴板是空的")
        }
    }

    func parse() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            say("先粘贴一条抖音链接")
            return
        }
        loading = true
        error = nil
        work = nil
        saved = []
        batchProgress = nil
        do {
            let w = try await DouyinParser.parse(text)
            work = w
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        loading = false
    }

    func save(_ item: MediaItem) async {
        guard !saving.contains(item.id), !saved.contains(item.id) else { return }
        saving.insert(item.id)
        do {
            let bytes = try await MediaSaver.save(item)
            saved.insert(item.id)
            say(String(format: "已存入相册 · %.1f MB", Double(bytes) / 1_048_576))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            say(error.localizedDescription)
        }
        saving.remove(item.id)
    }

    func saveAll() async {
        guard let w = work else { return }
        let pending = w.items.filter { !saved.contains($0.id) }
        guard !pending.isEmpty else {
            say("都已经存过了")
            return
        }
        var ok = 0
        for (i, it) in pending.enumerated() {
            batchProgress = (i, pending.count)
            do {
                _ = try await MediaSaver.save(it)
                saved.insert(it.id)
                ok += 1
            } catch {
                batchProgress = nil
                say(error.localizedDescription)
                return
            }
        }
        batchProgress = nil
        say("已保存 \(ok) 个到相册")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - 界面

struct ContentView: View {
    @StateObject private var vm = DLViewModel()
    @FocusState private var focused: Bool

    private var canParse: Bool {
        !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.loading
    }

    var body: some View {
        ZStack(alignment: .top) {
            AuroraBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                    inputCard
                    if vm.loading { loadingCard }
                    if let e = vm.error { errorCard(e) }
                    if let w = vm.work { resultSection(w) }
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 2)
                .padding(.bottom, 52)
            }
            .scrollDismissesKeyboard(.interactively)

            if let t = vm.toast {
                toastView(t)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(9)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: vm.toast)
        .onAppear { RemoteImage.warmCache() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 1.0, green: 0.36, blue: 0.50), Palette.red, Palette.redDeep],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 60, height: 60)
                    .overlay {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                    }
                    .shadow(color: Palette.red.opacity(0.45), radius: 20, y: 9)

                Image(systemName: "music.note")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Color.white)
            }

            Text("抖音去水印")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Color.white)

            Text("视频 · 图集 · 高清原画")
                .font(.system(size: 13))
                .foregroundStyle(Palette.faint)
        }
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    // MARK: 输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "link").font(.system(size: 12, weight: .semibold))
                Text("粘贴分享链接").font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Palette.faint)

            ZStack(alignment: .topTrailing) {
                TextField("粘贴抖音链接，或整段分享口令", text: $vm.input, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white)
                    .tint(Palette.red)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(14)
                    .padding(.trailing, 24)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)
                    }

                if !vm.input.isEmpty {
                    Button {
                        vm.input = ""
                        focused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.white.opacity(0.32))
                    }
                    .padding(11)
                }
            }

            HStack(spacing: 10) {
                Button {
                    vm.paste()
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(GhostButtonStyle())

                Button {
                    focused = false
                    Task { await vm.parse() }
                } label: {
                    if vm.loading {
                        HStack(spacing: 9) {
                            ProgressView().tint(Color.white)
                            Text("解析中")
                        }
                    } else {
                        Text("解析")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: canParse))
                .disabled(!canParse)
            }
        }
        .padding(16)
        .glass()
    }

    // MARK: 状态

    private var loadingCard: some View {
        HStack(spacing: 11) {
            ProgressView().tint(Palette.red)
            Text("正在解析，通常 1～3 秒")
                .font(.system(size: 13))
                .foregroundStyle(Palette.dim)
            Spacer()
        }
        .padding(15)
        .glass(radius: 16)
    }

    private func errorCard(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
            Text(msg)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(red: 1.0, green: 0.56, blue: 0.52))
        .padding(15)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 1.0, green: 0.35, blue: 0.32).opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(red: 1.0, green: 0.35, blue: 0.32).opacity(0.28), lineWidth: 0.7)
        }
    }

    // MARK: 结果

    private func resultSection(_ w: ParsedWork) -> some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Palette.red.opacity(0.16))
                    Image(systemName: w.type == "video" ? "play.rectangle.fill" : "photo.stack.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.red)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(w.author.isEmpty ? "抖音作品" : w.author)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text(w.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .glass(radius: 18)

            if !w.title.isEmpty {
                Text(w.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            if w.type == "video" {
                ForEach(w.items) { it in
                    videoCard(it, cover: w.cover)
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10),
                              GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(w.items) { it in
                        imageCard(it)
                    }
                }
            }

            if !w.note.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle.fill").font(.system(size: 14))
                    Text(w.note)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color(red: 0.96, green: 0.79, blue: 0.38))
                .padding(13)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(red: 0.96, green: 0.79, blue: 0.38).opacity(0.10))
                }
            }

            if w.items.count > 1 {
                Button {
                    Task { await vm.saveAll() }
                } label: {
                    if let p = vm.batchProgress {
                        Text("保存中 \(p.done + 1)/\(p.total)")
                    } else {
                        Text("全部保存（\(w.items.count) 个）")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(vm.batchProgress != nil)
                .padding(.top, 2)
            }
        }
    }

    private func imageCard(_ it: MediaItem) -> some View {
        ZStack(alignment: .topTrailing) {
            RemoteImageView(url: it.url)
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
                }

            if it.kind == .live {
                VStack {
                    Spacer()
                    HStack {
                        Text("动图")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                        Spacer()
                    }
                    .padding(8)
                }
            }

            saveButton(it)
        }
    }

    private func videoCard(_ it: MediaItem, cover: String?) -> some View {
        ZStack(alignment: .topTrailing) {
            RemoteImageView(url: cover ?? it.url)
                .frame(height: 232)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
                }
                .overlay {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.34))
                            .frame(width: 54, height: 54)
                        Image(systemName: "play.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .offset(x: 1.5)
                    }
                }

            VStack {
                Spacer()
                HStack {
                    if it.width > 0 && it.height > 0 {
                        Text("\(it.width)×\(it.height)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                    }
                    Spacer()
                }
                .padding(9)
            }

            saveButton(it)
        }
    }

    private func saveButton(_ it: MediaItem) -> some View {
        Button {
            Task { await vm.save(it) }
        } label: {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
                if vm.saving.contains(it.id) {
                    ProgressView().scaleEffect(0.62).tint(Color.white)
                } else if vm.saved.contains(it.id) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.32, green: 0.86, blue: 0.52))
                } else {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: 36, height: 36)
        }
        .padding(8)
        .disabled(vm.saving.contains(it.id) || vm.saved.contains(it.id))
    }

    // MARK: 底部

    private var footer: some View {
        VStack(spacing: 5) {
            Text("点右上角按钮存入相册")
            Text("仅用于保存自己需要的内容，请尊重原作者版权")
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.faint.opacity(0.8))
        .padding(.top, 12)
    }

    private func toastView(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background {
                Capsule().fill(.ultraThinMaterial)
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
