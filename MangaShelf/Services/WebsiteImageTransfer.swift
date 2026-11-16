import Foundation

/// URLSession writes network buffers directly to disk, without a Swift await per byte.
nonisolated enum WebsiteImageTransfer {
    static let imageLimit: Int64 = 40 * 1024 * 1024
    static let chapterLimit = 250 * 1024 * 1024

    static func fetch(_ request: URLRequest, session: URLSession, to target: URL) async throws -> Int {
        for attempt in 0..<3 {
            let limit = SizeLimit()
            do {
                let (temporary, response) = try await session.download(for: request, delegate: limit)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw WebsiteDownloadError("Phản hồi ảnh không hợp lệ.") }
                guard (200..<300).contains(http.statusCode) else {
                    throw WebsiteDownloadError("Ảnh HTTP \(http.statusCode). Kiểm tra quyền đọc/phiên đăng nhập; không lưu PDF thiếu ảnh.")
                }
                let count = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard count > 0 else { throw WebsiteDownloadError("Ảnh rỗng.") }
                guard count <= imageLimit else { throw WebsiteDownloadError("Ảnh vượt 40 MB.") }
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: temporary, to: target)
                return count
            } catch {
                if limit.exceeded { throw WebsiteDownloadError("Ảnh vượt 40 MB.") }
                guard let network = error as? URLError, attempt < 2,
                      [.timedOut, .networkConnectionLost].contains(network.code), !Task.isCancelled else { throw error }
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw WebsiteDownloadError("Không tải được ảnh sau 3 lần thử.")
    }

    /// Keep output positions independent of completion order. Cancelling/failing one
    /// child cancels its siblings, and task-group scope awaits cleanup before returning.
    static func fetchAll(_ requests: [URLRequest], session: URLSession, folder: URL,
                         progress: @escaping @Sendable (Int) async -> Void) async throws -> [URL] {
        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            let files = requests.indices.map { folder.appendingPathComponent("image-\($0)") }
            func enqueue(_ index: Int) {
                group.addTask { (index, try await fetch(requests[index], session: session, to: files[index])) }
            }
            var next = 0, completed = 0, bytes = 0
            while next < min(3, requests.count) { enqueue(next); next += 1 }
            while let (_, count) = try await group.next() {
                try Task.checkCancellation()
                bytes += count; completed += 1
                guard bytes <= chapterLimit else { throw WebsiteDownloadError("Chapter vượt giới hạn 250 MB.") }
                await progress(completed)
                if next < requests.count { enqueue(next); next += 1 }
            }
            return files
        }
    }

    private final class SizeLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var overLimit = false
        var exceeded: Bool { lock.withLock { overLimit } }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if max(totalBytesWritten, totalBytesExpectedToWrite) > WebsiteImageTransfer.imageLimit {
                lock.withLock { overLimit = true }
                downloadTask.cancel()
            }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
