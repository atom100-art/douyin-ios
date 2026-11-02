import Foundation
import Photos
import UniformTypeIdentifiers

enum SaveError: LocalizedError {
    case badURL
    case denied
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "下载地址无效。"
        case .denied: return "没有相册权限。请到「设置 → 抖音去水印 → 照片」里允许添加。"
        case .writeFailed(let m): return "保存失败：\(m)"
        }
    }
}

enum MediaSaver {

    @discardableResult
    static func requestPermission() async -> Bool {
        let cur = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if cur == .authorized || cur == .limited { return true }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// 下载单个媒体并写入相册，返回文件字节数
    static func save(_ item: MediaItem) async throws -> Int {
        guard let u = URL(string: item.url) else { throw SaveError.badURL }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        let session = URLSession(configuration: cfg)

        var req = URLRequest(url: u)
        req.setValue(Net.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        req.setValue("*/*", forHTTPHeaderField: "Accept")

        let (tmp, resp) = try await session.download(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw SaveError.writeFailed("服务器返回 \(http.statusCode)")
        }

        let ext = item.isVideo ? "mp4" : (item.name.lowercased().hasSuffix(".png") ? "png" : "jpg")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try FileManager.default.copyItem(at: tmp, to: dest)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        guard await requestPermission() else {
            try? FileManager.default.removeItem(at: dest)
            throw SaveError.denied
        }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let create = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = true
                if item.isVideo {
                    opts.uniformTypeIdentifier = UTType.mpeg4Movie.identifier
                    create.addResource(with: .video, fileURL: dest, options: opts)
                } else {
                    opts.uniformTypeIdentifier = (ext == "png") ? UTType.png.identifier : UTType.jpeg.identifier
                    create.addResource(with: .photo, fileURL: dest, options: opts)
                }
            } completionHandler: { success, err in
                if success {
                    c.resume()
                } else {
                    c.resume(throwing: SaveError.writeFailed(err?.localizedDescription ?? "未知错误"))
                }
            }
        }

        try? FileManager.default.removeItem(at: dest)
        return size
    }
}
