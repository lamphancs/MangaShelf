import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import zlib
import Accelerate

/// Writes separate image objects; never builds a chapter-sized bitmap.
nonisolated enum ChapterImagePDF {
    static func write(images: [URL], to output: URL, pageWidth: Double) throws {
        guard pageWidth.isFinite, pageWidth > 0 else { throw WebsiteDownloadError("Chiều rộng PDF không hợp lệ.") }
        guard !images.isEmpty else { throw WebsiteDownloadError("Không có ảnh.") }
        struct ImageInfo { let width: Int; let height: Int }
        let info = try images.map { url -> ImageInfo in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= 30000, h <= 100000, w * h <= 32_000_000 else {
                throw WebsiteDownloadError("Ảnh không hợp lệ hoặc vượt giới hạn 32 triệu pixel.")
            }
            guard (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else {
                throw WebsiteDownloadError("EXIF orientation khác 1 chưa được hỗ trợ; ảnh không bị nén lại.")
            }
            return ImageInfo(width: w, height: h)
        }
        // Match the browser viewport width, independently of chapter length.
        // Only placement coordinates change; embedded image pixels stay untouched.
        let width = pageWidth
        let height = info.reduce(0.0) { $0 + width * Double($1.height) / Double($1.width) }
        guard height.isFinite, height > 0 else { throw WebsiteDownloadError("Chiều cao PDF không hợp lệ.") }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        var offsets: [UInt64] = [0]
        func put(_ text: String) throws { try file.write(contentsOf: Data(text.utf8)) }
        func object(_ id: Int, _ body: String, stream: Data? = nil) throws {
            while offsets.count <= id { offsets.append(0) }
            offsets[id] = try file.offset()
            try put("\(id) 0 obj\n\(body)")
            if let stream { try put("\nstream\n"); try file.write(contentsOf: stream); try put("\nendstream") }
            try put("\nendobj\n")
        }
        func number(_ n: Double) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), n) }
        try put("%PDF-1.7\n")
        try object(1, "<< /Type /Catalog /Pages 2 0 R >>")
        try object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        let resources = images.indices.map { "/Im\($0) \(5 + $0 * 2) 0 R" }.joined(separator: " ")
        try object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(number(width)) \(number(height))] /Resources << /XObject << \(resources) >> >> /Contents 4 0 R >>")
        var commands = "", top = height
        for (i, item) in info.enumerated() {
            let h = width * Double(item.height) / Double(item.width)
            top -= h
            commands += "q \(number(width)) 0 0 \(number(h)) 0 \(number(top)) cm /Im\(i) Do Q\n"
        }
        let drawing = Data(commands.utf8)
        try object(4, "<< /Length \(drawing.count) >>", stream: drawing)
        for (i, url) in images.enumerated() {
            try Task.checkCancellation()
            guard try file.offset() < 512 * 1024 * 1024 else { throw WebsiteDownloadError("PDF vượt giới hạn 512 MB.") }
            try autoreleasepool {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) == 1,
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let color = image.colorSpace else { throw WebsiteDownloadError("Không giải mã được ảnh hoặc ảnh động không được hỗ trợ.") }
                let jpeg = data.starts(with: [0xff, 0xd8])
                let bytes: Data, components: Int, profile: Data?, filter: String
                if jpeg {
                    guard image.bitsPerComponent == 8, [.rgb, .monochrome].contains(color.model) else {
                        throw WebsiteDownloadError("JPEG CMYK hoặc độ sâu màu này chưa được hỗ trợ; không chuyển đổi mất chất lượng.")
                    }
                    components = color.model == .monochrome ? 1 : 3
                    bytes = data; filter = "DCTDecode"
                    profile = color.copyICCData() as Data?
                } else {
                    guard let type = CGImageSourceGetType(source) as String?,
                          [UTType.png.identifier, UTType.webP.identifier].contains(type) else {
                        throw WebsiteDownloadError("Chỉ hỗ trợ JPEG, PNG và WebP tĩnh.")
                    }
                    guard image.bitsPerComponent == 8 else { throw WebsiteDownloadError("PNG/WebP hơn 8 bit chưa hỗ trợ; không tự giảm độ sâu màu.") }
                    components = 3; filter = "FlateDecode"
                    let space = CGColorSpace(name: CGColorSpace.sRGB)!
                    profile = space.copyICCData() as Data?
                    let w = info[i].width, h = info[i].height
                    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let memory = ctx.data else { throw WebsiteDownloadError("Không đủ bộ nhớ để giải mã ảnh.") }
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                    // SIMD channel packing avoids Swift work for every pixel of a long chapter.
                    var rgba = vImage_Buffer(data: memory, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var rgb = Data(count: w * h * 3)
                    let conversion = rgb.withUnsafeMutableBytes { raw -> vImage_Error in
                        var destination = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 3)
                        return vImageConvert_RGBA8888toRGB888(&rgba, &destination, vImage_Flags(kvImageNoFlags))
                    }
                    guard conversion == kvImageNoError else { throw WebsiteDownloadError("Không chuyển được ảnh sang RGB lossless.") }
                    var length = compressBound(uLong(rgb.count))
                    var compressed = Data(count: Int(length))
                    let result = compressed.withUnsafeMutableBytes { dst in rgb.withUnsafeBytes { src in
                        compress2(dst.bindMemory(to: Bytef.self).baseAddress, &length, src.bindMemory(to: Bytef.self).baseAddress, uLong(rgb.count), Z_DEFAULT_COMPRESSION)
                    } }
                    guard result == Z_OK else { throw WebsiteDownloadError("Lỗi nén lossless.") }
                    compressed.count = Int(length); bytes = compressed
                }
                let id = 5 + i * 2
                let cs = profile == nil ? (components == 1 ? "/DeviceGray" : "/DeviceRGB") : "[/ICCBased \(id + 1) 0 R]"
                try object(id, "<< /Type /XObject /Subtype /Image /Width \(info[i].width) /Height \(info[i].height) /BitsPerComponent 8 /ColorSpace \(cs) /Filter /\(filter) /Length \(bytes.count) >>", stream: bytes)
                if let profile { try object(id + 1, "<< /N \(components) /Length \(profile.count) >>", stream: profile) }
                else { try object(id + 1, "null") }
            }
        }
        let xref = try file.offset()
        try put("xref\n0 \(offsets.count)\n0000000000 65535 f \n")
        for offset in offsets.dropFirst() { try put(String(format: "%010llu 00000 n \n", offset)) }
        try put("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
        try file.synchronize()
    }
}
