import Foundation
import CoreGraphics
import zlib

/// Rewrites Quartz-generated PDFs with stronger Flate compression. Image dimensions,
/// decoded samples, JPEG/JPX streams, text, and the PDF object graph stay intact.
/// This is intentionally internal to web export, not a general PDF editing API.
nonisolated enum PDFLosslessWriter {
    struct Patch {
        let rect: CGRect
        let width: Int
        let height: Int
        let rgb: Data
    }

    static func compact(_ data: Data, patches: [Patch] = []) throws -> Data {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), !document.isEncrypted,
              let catalog = document.catalog else { throw Failure.unsupported }
        let writer = Writer()
        defer { writer.clear() }
        let root = try writer.dictionary(catalog)
        let info = try document.info.map { try writer.dictionary($0) }
        if !patches.isEmpty {
            guard document.numberOfPages == 1, let page = document.page(at: 1) else { throw Failure.unsupported }
            try writer.add(patches: patches, to: page)
        }
        return try withExtendedLifetime(document) { try writer.finish(root: root, info: info) }
    }

    private enum Failure: Error { case unsupported, compression }
    private final class Entries {
        var values: [(Data, CGPDFObjectRef)] = []
    }
    private final class Writer {
        private struct Key: Hashable { let pointer: UInt; let type: Int }
        private var identifiers: [Key: Int] = [:]
        private var objects: [() throws -> Data] = []
        func clear() { objects.removeAll() }
        private var pageOverride: (pointer: UInt, resources: String, contents: String)?

        private func append(_ body: @escaping () throws -> Data) -> String {
            let id = objects.count + 1
            objects.append(body)
            return "\(id) 0 R"
        }

        func add(patches: [Patch], to page: CGPDFPage) throws {
            guard let pageDictionary = page.dictionary else { throw Failure.unsupported }
            var resources: CGPDFDictionaryRef?
            var ancestor = pageDictionary
            for _ in 0..<100 {
                if CGPDFDictionaryGetDictionary(ancestor, "Resources", &resources) { break }
                var parent: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(ancestor, "Parent", &parent), let parent else { break }
                ancestor = parent
            }
            guard let resources else { throw Failure.unsupported }
            var xobjects: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects)
            let existingNames = Set(xobjects.map { entries($0).map { $0.0 } } ?? [])
            var names = existingNames
            var additions = ""
            var commands = Data("Q\nq\n".utf8)
            for (index, patch) in patches.enumerated() {
                var key = "MangaShelfSeam\(index)"
                while names.contains(Data(key.utf8)) { key += "_" }
                names.insert(Data(key.utf8))
                let image = append {
                    let compressed = try self.deflate(patch.rgb)
                    var output = Data(("<< /Type /XObject /Subtype /Image /Width \(patch.width) /Height \(patch.height) " +
                        "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate true /Filter /FlateDecode " +
                        "/Length \(compressed.count) >>\nstream\n").utf8)
                    output.append(compressed)
                    output.append(contentsOf: "\nendstream".utf8)
                    return output
                }
                additions += "/\(key) \(image)\n"
                commands.append(contentsOf: ("q \(number(patch.rect.width)) 0 0 \(number(patch.rect.height)) " +
                    "\(number(patch.rect.minX)) \(number(patch.rect.minY)) cm /\(key) Do Q\n").utf8)
            }
            commands.append(contentsOf: "Q\n".utf8)
            let imageEntries = additions
            let mergedImages = append {
                if let xobjects { return try self.dictionaryBody(xobjects, extra: imageEntries) }
                return Data(("<<\n" + imageEntries + ">>").utf8)
            }
            let mergedResources = append {
                try self.dictionaryBody(resources, excluding: [Data("XObject".utf8)],
                                        extra: "/XObject \(mergedImages)\n")
            }
            let drawing = commands
            let addedContent = append {
                let compressed = try self.deflate(drawing)
                var result = Data("<< /Filter /FlateDecode /Length \(compressed.count) >>\nstream\n".utf8)
                result.append(compressed)
                result.append(contentsOf: "\nendstream".utf8)
                return result
            }
            var content: CGPDFObjectRef?
            let isolate = append { Data("<< /Length 2 >>\nstream\nq\n\nendstream".utf8) }
            var contents: [String] = [isolate]
            if CGPDFDictionaryGetObject(pageDictionary, "Contents", &content), let content {
                if CGPDFObjectGetType(content) == .array {
                    var array: CGPDFArrayRef?
                    guard CGPDFObjectGetValue(content, .array, &array), let array else { throw Failure.unsupported }
                    for index in 0..<CGPDFArrayGetCount(array) {
                        var child: CGPDFObjectRef?
                        guard CGPDFArrayGetObject(array, index, &child), let child else { throw Failure.unsupported }
                        contents.append(try object(child))
                    }
                } else { contents.append(try object(content)) }
            }
            contents.append(addedContent)
            pageOverride = (UInt(bitPattern: pageDictionary.rawValue), mergedResources,
                            "[" + contents.joined(separator: " ") + "]")
        }

        private func number(_ value: CGFloat) -> String {
            let source = String(Double(value))
            let parts = source.lowercased().split(separator: "e")
            guard parts.count == 2, let exponent = Int(parts[1]) else { return source }
            let sign = parts[0].hasPrefix("-") ? "-" : ""
            let mantissa = parts[0].replacingOccurrences(of: "-", with: "")
            let digits = mantissa.replacingOccurrences(of: ".", with: "")
            let point = (mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count) + exponent
            if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
            if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
            let split = digits.index(digits.startIndex, offsetBy: point)
            return sign + digits[..<split] + "." + digits[split...]
        }

        private func reference(_ pointer: OpaquePointer, type: Int,
                               body: @escaping () throws -> Data) throws -> String {
            let key = Key(pointer: UInt(bitPattern: pointer), type: type)
            if let id = identifiers[key] { return "\(id) 0 R" }
            guard objects.count < 100_000 else { throw Failure.unsupported }
            let id = objects.count + 1
            identifiers[key] = id
            objects.append(body)
            return "\(id) 0 R"
        }

        func dictionary(_ value: CGPDFDictionaryRef) throws -> String {
            try reference(value.rawValue, type: 0) { try self.dictionaryBody(value) }
        }

        private func entries(_ dictionary: CGPDFDictionaryRef) -> [(Data, CGPDFObjectRef)] {
            let entries = Entries()
            CGPDFDictionaryApplyFunction(dictionary, { key, value, context in
                let entries = Unmanaged<Entries>.fromOpaque(context!).takeUnretainedValue()
                entries.values.append((Data(bytes: key, count: strlen(key)), value))
            }, Unmanaged.passUnretained(entries).toOpaque())
            return entries.values.sorted { $0.0.lexicographicallyPrecedes($1.0) }
        }

        private func dictionaryBody(_ dictionary: CGPDFDictionaryRef,
                                    excluding: Set<Data> = [], extra: String = "") throws -> Data {
            var excluding = excluding
            var extra = extra
            if let override = pageOverride, override.pointer == UInt(bitPattern: dictionary.rawValue) {
                excluding.formUnion([Data("Resources".utf8), Data("Contents".utf8)])
                extra += "/Resources \(override.resources)\n/Contents \(override.contents)\n"
            }
            var result = Data("<<".utf8)
            for (key, value) in entries(dictionary) where !excluding.contains(key) {
                result.append(contentsOf: "\n\(name(key)) \(try object(value))".utf8)
            }
            result.append(contentsOf: "\n\(extra)>>".utf8)
            return result
        }

        private func name(_ bytes: Data) -> String {
            "/" + bytes.map { byte in
                if (33...126).contains(byte) && !Data("#%()/<>[]{}".utf8).contains(byte) {
                    return String(UnicodeScalar(byte))
                }
                return String(format: "#%02X", byte)
            }.joined()
        }

        private func object(_ object: CGPDFObjectRef) throws -> String {
            switch CGPDFObjectGetType(object) {
            case .null: return "null"
            case .boolean:
                var value: CGPDFBoolean = 0
                guard CGPDFObjectGetValue(object, .boolean, &value) else { throw Failure.unsupported }
                return value == 0 ? "false" : "true"
            case .integer:
                var value: CGPDFInteger = 0
                guard CGPDFObjectGetValue(object, .integer, &value) else { throw Failure.unsupported }
                return String(value)
            case .real:
                var value: CGPDFReal = 0
                guard CGPDFObjectGetValue(object, .real, &value), value.isFinite else { throw Failure.unsupported }
                // PDF numbers do not support scientific notation.
                return number(value)
            case .name:
                var value: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(object, .name, &value), let value else { throw Failure.unsupported }
                return name(Data(bytes: value, count: strlen(value)))
            case .string:
                var value: CGPDFStringRef?
                guard CGPDFObjectGetValue(object, .string, &value), let value,
                      let bytes = CGPDFStringGetBytePtr(value) else { throw Failure.unsupported }
                return "<" + Data(bytes: bytes, count: CGPDFStringGetLength(value))
                    .map { String(format: "%02X", $0) }.joined() + ">"
            case .array:
                var value: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &value), let value else { throw Failure.unsupported }
                return try reference(value.rawValue, type: 1) {
                    var values: [String] = []
                    for index in 0..<CGPDFArrayGetCount(value) {
                        var child: CGPDFObjectRef?
                        guard CGPDFArrayGetObject(value, index, &child), let child else { throw Failure.unsupported }
                        values.append(try self.object(child))
                    }
                    return Data(("[" + values.joined(separator: " ") + "]").utf8)
                }
            case .dictionary:
                var value: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { throw Failure.unsupported }
                return try dictionary(value)
            case .stream:
                var value: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &value), let value else { throw Failure.unsupported }
                return try reference(value.rawValue, type: 2) { try self.stream(value) }
            @unknown default: throw Failure.unsupported
            }
        }

        private func stream(_ stream: CGPDFStreamRef) throws -> Data {
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { throw Failure.unsupported }
            var format = CGPDFDataFormat.raw
            guard let source = CGPDFStreamCopyData(stream, &format) else { throw Failure.unsupported }
            var data = source as Data
            let filter: String
            var excluded = Set(["Length", "Filter"].map { Data($0.utf8) })
            switch format {
            case .raw:
                data = try deflate(data)
                filter = "/FlateDecode"
                // CopyData has already decoded filters and predictors.
                excluded.insert(Data("DecodeParms".utf8))
            case .jpegEncoded, .JPEG2000:
                // Preserve compressed image bytes. Reject filter chains whose
                // DecodeParms might no longer correspond to the returned stream.
                var originalFilter: UnsafePointer<CChar>?
                let expected = format == .jpegEncoded ? "DCTDecode" : "JPXDecode"
                guard CGPDFDictionaryGetName(dictionary, "Filter", &originalFilter),
                      let originalFilter, String(cString: originalFilter) == expected else {
                    throw Failure.unsupported
                }
                filter = "/" + expected
            @unknown default: throw Failure.unsupported
            }
            var result = try dictionaryBody(dictionary, excluding: excluded,
                extra: "/Length \(data.count)\n/Filter \(filter)\n")
            result.append(contentsOf: "\nstream\n".utf8)
            result.append(data)
            result.append(contentsOf: "\nendstream".utf8)
            return result
        }

        private func deflate(_ data: Data) throws -> Data {
            var length = compressBound(uLong(data.count))
            var result = Data(count: Int(length))
            let status = result.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    compress2(destination.bindMemory(to: Bytef.self).baseAddress!, &length,
                              source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_BEST_COMPRESSION)
                }
            }
            guard status == Z_OK else { throw Failure.compression }
            result.count = Int(length)
            return result
        }

        func finish(root: String, info: String?) throws -> Data {
            defer { objects.removeAll() }
            var output = Data("%PDF-1.7\n%\u{00e2}\u{00e3}\u{00cf}\u{00d3}\n".utf8)
            var offsets = [0]
            var index = 0
            // Bodies can discover further objects; the queue also handles cycles
            // such as Page -> Parent -> Kids -> Page without recursive expansion.
            while index < objects.count {
                try Task.checkCancellation()
                offsets.append(output.count)
                output.append(contentsOf: "\(index + 1) 0 obj\n".utf8)
                let body = try autoreleasepool { try objects[index]() }
                output.append(body)
                output.append(contentsOf: "\nendobj\n".utf8)
                index += 1
            }
            let xref = output.count
            output.append(contentsOf: "xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8)
            for offset in offsets.dropFirst() {
                guard offset < 10_000_000_000 else { throw Failure.unsupported }
                output.append(contentsOf: String(format: "%010lld 00000 n \n", Int64(offset)).utf8)
            }
            output.append(contentsOf: "trailer\n<< /Size \(offsets.count) /Root \(root)".utf8)
            if let info { output.append(contentsOf: " /Info \(info)".utf8) }
            output.append(contentsOf: " >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
            return output
        }
    }
}
