import SwiftUI
import SwiftData
import WebKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

@main struct WebsiteSmokeApp: App {
    @State private var downloader = WebsiteDownloadModel(url: URL(string:"https://damconuong.cool/truyen/story")!, isPrivate:true)
    private var browser: WebPageCaptureModel { downloader.browser }
    var body: some Scene {
        WindowGroup { CaptureWebView(webView: browser.webView).task {
            let result: String
            do { result = try await checks() } catch { result = "FAIL: \(error)" }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
            try? result.write(to: url, atomically: true, encoding: .utf8)
        } }
    }
    @MainActor func checks() async throws -> String {
        func check(_ value: Bool, _ message: String) throws { if !value { throw WebsiteDownloadError(message) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (input, expected) in [("Hồi 600 thuộc Tập 78", "600"), ("Chương 12,5", "12.5"), ("Chapter 001", "1"), ("Ch. 2", "2")] {
            try check(WebsiteProvider.number(input).map { NSDecimalNumber(decimal: $0).stringValue } == expected, "Chapter numbering: \(input)")
        }
        let cases: [(WebsiteProvider,String)] = [(.toonGod,"https://www.toongod.org/webtoon/story"),(.omega,"https://omegascans.org/series/story"),(.damconuong,"https://damconuong.cool/truyen/story"),(.truyenQQ,"https://truyenqqko.com/truyen-tranh/story-123.html")]
        for (provider, base) in cases {
            let url = URL(string: base)!
            func link(_ n: String) -> String { provider == .truyenQQ ? base.replacingOccurrences(of: ".html", with: "-chap-\(n).html") : base + "/chapter-\(n)" }
            let list = provider.chapters([
                ["url":link("10"),"title":"Chapter 10"], ["url":link("2"),"title":"Chapter 2"],
                ["url":link("12.5"),"title":"Chương 12,5"], ["url":link("2")+"?tracking=1#x","title":"duplicate"],
                ["url":"https://example.com/chapter-3","title":"Chapter 3"],
                ["url":base.replacingOccurrences(of:"story",with:"other")+"/chapter-5","title":"Chapter 5"]], series: url)
            try check(list.map(\.filename) == ["Chapter 2.pdf","Chapter 10.pdf","Chapter 12.5.pdf"], "Scope, dedup, numeric ordering \(provider)")
        }
        browser.webView.navigationDelegate = nil
        browser.webView.loadHTMLString("""
        <div id="chapter-content"><picture><source data-original="/one.png"><img src="placeholder.png"></picture>
        <img data-src="/two.jpg"><div class="ads"><img src="/ad.jpg"></div></div>
        <script>setTimeout(()=>{let i=document.createElement('img');i.dataset.original='/three.webp';document.querySelector('#chapter-content').append(i)},300)</script>
        """, baseURL: URL(string:"https://damconuong.cool/truyen/story/chapter-1"))
        for _ in 0..<40 {
            if (try? await browser.webView.evaluateJavaScript("document.querySelectorAll('#chapter-content img').length")) as? Int == 4 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let result = try await browser.webView.evaluateJavaScript(WebsiteProvider.damconuong.imagesScript) as! [String:Any]
        try check((result["urls"] as? [String]) == ["https://damconuong.cool/one.png","https://damconuong.cool/two.jpg","https://damconuong.cool/three.webp"], "Dynamic DOM, lazy, picture, advertisement filtering: \(result)")
        let beforeURL = browser.webView.url
        let beforeScroll = try await browser.webView.evaluateJavaScript("scrollY") as? Double
        let inertHTML = "<div class='reading-content' data-total-pages='2'><img data-src='/1.jpg'><picture><source data-original='2.webp'><img src='placeholder.png'></picture></div><script>window.UNEXPECTED_SCRIPT = true</script>"
        let directScript = try WebsiteProvider.toonGod.staticImagesScript(html: inertHTML, url: URL(string:"https://toongod.org/webtoon/fixture/chapter-1/")!)
        let direct = try await browser.webView.callAsyncJavaScript(directScript, arguments: [:], in: nil, contentWorld: .page) as? [String:Any]
        try check(direct?["urls"] as? [String] == ["https://toongod.org/1.jpg","https://toongod.org/webtoon/fixture/chapter-1/2.webp"], "Inert HTML resolves lazy URLs without chapter navigation")
        try check(direct?["total"] as? Int == 2 && direct?["pending"] as? Int == 0, "Inert HTML preserves completeness metadata")
        let scriptExecuted = try await browser.webView.evaluateJavaScript("window.UNEXPECTED_SCRIPT === true") as? Bool
        let afterScroll = try await browser.webView.evaluateJavaScript("scrollY") as? Double
        try check(scriptExecuted == false && beforeURL == browser.webView.url && beforeScroll == afterScroll, "No script execution/navigation/scroll for direct HTML")
        let blobURL = try await browser.webView.evaluateJavaScript("URL.createObjectURL(new Blob([new Uint8Array(200000).fill(42)], {type:'application/octet-stream'}))") as! String
        let blobFile = root.appendingPathComponent("blob")
        let blobCount = try await downloader.fetchPageImage(URL(string:blobURL)!,to:blobFile)
        try check(blobCount == 200000 && (try Data(contentsOf:blobFile)) == Data(repeating:42,count:200000), "Blob transfer in multiple chunks retains bytes")
        let inlineFile = root.appendingPathComponent("inline")
        let inlineCount = try await downloader.fetchPageImage(URL(string:"data:application/octet-stream;base64,AQIDBA==")!,to:inlineFile)
        try check(inlineCount == 4 && (try Data(contentsOf:inlineFile)) == Data([1,2,3,4]), "Data URL transfer retains bytes")
        _ = try await browser.webView.evaluateJavaScript(#"""
        self.__next_f = [[1, '1:{"id":77,"series_slug":"story"}\n']];
        window.apiPages = [];
        window.fetch = async function(url) {
          const page = Number(new URL(url).searchParams.get('page')); apiPages.push(page);
          return {ok:true,json:async()=>({meta:{total:2,current_page:page,last_page:2},data:[{chapter_name:'Chapter '+page,chapter_slug:'chapter-'+page,series:{id:77,series_slug:'story'}}]})};
        }; true;
        """#)
        let rawAPI = try await browser.webView.callAsyncJavaScript(WebsiteProvider.omegaListScript, arguments: [:], in: nil, contentWorld: .page)
        let api = rawAPI as? [[String:String]]
        try check(api?.count == 2, "Omega complete pagination from matched Next.js series: \(String(describing: rawAPI))")
        let pages = try await browser.webView.evaluateJavaScript("apiPages") as? [Int]
        try check(pages == [1,2], "Omega fetched both pages")
        _ = try await browser.webView.evaluateJavaScript(#"""
        const script = document.createElement('script'); script.type='application/octet-stream';
        script.textContent = 'self.__next_f.push(' + JSON.stringify(self.__next_f[0]) + ')';
        document.head.append(script); self.__next_f = []; true;
        """#)
        let drained = try await browser.webView.callAsyncJavaScript(WebsiteProvider.omegaListScript, arguments:[:], in:nil, contentWorld:.page) as? [[String:String]]
        try check(drained?.count == 2, "Omega state survives drained hydration queue")
        _ = try await browser.webView.evaluateJavaScript("fetch = async()=>({ok:true,json:async()=>({meta:{total:3,current_page:1,last_page:1},data:[]})}); true")
        do {
            _ = try await browser.webView.callAsyncJavaScript(WebsiteProvider.omegaListScript, arguments: [:], in: nil, contentWorld: .page)
            throw WebsiteDownloadError("Incomplete API response accepted")
        } catch let error as WebsiteDownloadError { throw error } catch { }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageProtocol.self]
        let session = URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url:URL(string:"https://images.example/image")!)
        let downloaded = root.appendingPathComponent("download")
        ImageProtocol.requests = 0
        do {
            _ = try await WebsiteDownloadModel.fetch(req,session:session,to:downloaded)
            throw WebsiteDownloadError("403 accepted")
        } catch let error as WebsiteDownloadError { try check(error.message.contains("403"), "Expected HTTP 403") }
        try check(ImageProtocol.requests == 1 && !FileManager.default.fileExists(atPath:downloaded.path), "403 not retried, no partial image")
        req.setValue("https://reader.example/chapter-1",forHTTPHeaderField:"Referer")
        let count = try await WebsiteDownloadModel.fetch(req,session:session,to:downloaded)
        try check(count == 4 && (try Data(contentsOf:downloaded)) == Data([1,2,3,4]), "Referer forwarded and response bytes retained")
        let cancelled = Task { try Task.checkCancellation(); return try await WebsiteDownloadModel.fetch(req,session:session,to:root.appendingPathComponent("cancelled")) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw WebsiteDownloadError("Cancellation ignored") }
        catch is CancellationError {} catch let error as URLError where error.code == .cancelled {}
        var benchmark = ""
        if let base = ProcessInfo.processInfo.environment["WEBSITE_TRANSFER_URL"] {
            let network = URLSession(configuration:.ephemeral)
            defer { network.invalidateAndCancel() }
            let requests = (0..<6).map { URLRequest(url: URL(string: "\(base)/image/\($0)")!) }
            let sequentialStart = ContinuousClock.now
            for (i, request) in requests.enumerated() {
                _ = try await WebsiteImageTransfer.fetch(request, session:network, to:root.appendingPathComponent("serial-\(i)"))
            }
            let sequential = sequentialStart.duration(to:.now)
            let parallelStart = ContinuousClock.now
            let outputs = try await WebsiteImageTransfer.fetchAll(requests, session:network, folder:root) { _ in }
            let parallel = parallelStart.duration(to:.now)
            for (i, file) in outputs.enumerated() {
                try check(try Data(contentsOf:file) == Data(repeating:UInt8(i),count:256*1024), "Parallel downloads retain byte content and page order")
            }
            let (stats, _) = try await network.data(from:URL(string:base+"/stats")!)
            let counts = try JSONSerialization.jsonObject(with:stats) as! [String:Int]
            try check(counts["peak"] == 3, "Exactly 3 active transfers maximum")
            let cancelledFolder = root.appendingPathComponent("cancelled-batch")
            try FileManager.default.createDirectory(at:cancelledFolder,withIntermediateDirectories:true)
            let batch = Task { try await WebsiteImageTransfer.fetchAll(requests,session:network,folder:cancelledFolder) { _ in } }
            try await Task.sleep(for:.milliseconds(50)); batch.cancel()
            do { _ = try await batch.value; throw WebsiteDownloadError("Batch ignored cancellation") }
            catch is CancellationError {} catch let error as URLError where error.code == .cancelled {}
            try check(try FileManager.default.contentsOfDirectory(atPath:cancelledFolder.path).isEmpty, "Cancelled batch installs no partial image")
            do {
                _ = try await WebsiteImageTransfer.fetch(URLRequest(url:URL(string:base+"/oversize")!), session:network,to:root.appendingPathComponent("oversize"))
                throw WebsiteDownloadError("Oversize image accepted")
            } catch let error as WebsiteDownloadError { try check(error.message.contains("40 MB"), "Image size guard cancels native transfer") }
            benchmark = "\nLocal fixture (6 × 256 KiB, staggered server delays): sequential \(sequential), 3 parallel \(parallel). This is not a live chapter benchmark."
        }
        var files: [URL] = []
        var originalJPEG = Data()
        for (index, type) in [UTType.jpeg, UTType.png].enumerated() {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data:nil,width:20,height:30,bitsPerComponent:8,bytesPerRow:80,space:space,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(index == 0 ? UIColor.red.cgColor : UIColor.blue.cgColor); ctx.fill(CGRect(x:0,y:0,width:20,height:30))
            let data = NSMutableData()
            let dest = CGImageDestinationCreateWithData(data,type.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(dest,ctx.makeImage()!,nil); CGImageDestinationFinalize(dest)
            let url = root.appendingPathComponent("image\(index)"); try (data as Data).write(to:url); files.append(url)
            if index == 0 { originalJPEG = data as Data }
        }
        let pdf = root.appendingPathComponent("out.pdf")
        try ChapterImagePDF.write(images:files,to:pdf,pageWidth:20)
        let data = try Data(contentsOf:pdf)
        let doc = CGPDFDocument(CGDataProvider(data:data as CFData)!)!
        try check(doc.numberOfPages == 1, "One page")
        let page = doc.page(at:1)!
        try check(page.getBoxRect(.mediaBox) == CGRect(x:0,y:0,width:20,height:60), "Continuous page geometry")
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        CGPDFDictionaryGetDictionary(page.dictionary!,"Resources",&resources)
        CGPDFDictionaryGetDictionary(resources!,"XObject",&objects)
        CGPDFDictionaryGetStream(objects!,"Im0",&stream)
        var format = CGPDFDataFormat.raw
        let jpeg = CGPDFStreamCopyData(stream!,&format)! as Data
        try check(format == .jpegEncoded && jpeg == originalJPEG, "JPEG exact stream bytes")
        CGPDFDictionaryGetStream(objects!,"Im1",&stream)
        let pngSamples = CGPDFStreamCopyData(stream!,&format)! as Data
        try check(format == .raw && pngSamples == Data((0..<(20*30)).flatMap { _ in [UInt8(0),0,255] }), "PNG lossless exact RGB samples after SIMD conversion")
        let render = CGContext(data:nil,width:20,height:60,bitsPerComponent:8,bytesPerRow:80,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        render.drawPDFPage(page)
        let samples = render.data!.assumingMemoryBound(to:UInt8.self)
        for row in 0..<60 {
            let p = row * 80 + 10 * 4
            try check(max(samples[p],samples[p+2]) > 220 && samples[p+1] < 30, "No black/white seam at row \(row)")
        }
        try check(String(decoding:data,as:UTF8.self).contains("/ICCBased"), "ICC profile retained")
        let tallPDF = root.appendingPathComponent("tall.pdf")
        try ChapterImagePDF.write(images:Array(repeating:files[0],count:600),to:tallPDF,pageWidth:20)
        let tallDoc = PDFDocument(url:tallPDF)!
        try check(tallDoc.pageCount == 1 && tallDoc.page(at:0)!.bounds(for:.mediaBox).width == 20 && abs(tallDoc.page(at:0)!.bounds(for:.mediaBox).height - 18000) < 0.01, "Long chapter preserves fixed width beyond 14400 points")
        let reader = PDFContentView(frame:.zero)
        reader.configure(document:tallDoc,width:390,viewportHeight:800,artwork:[],includesTopInset:false)
        try check(reader.frame.height > 300000 && reader.frame.width == 390, "Reader fits width without fitting whole long page")
        // EXIF orientations are rejected explicitly, never silently flattened/recompressed.
        let jpegSource = CGImageSourceCreateWithData(originalJPEG as CFData,nil)!
        let oriented = NSMutableData()
        let orientationDestination = CGImageDestinationCreateWithData(oriented,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(orientationDestination,CGImageSourceCreateImageAtIndex(jpegSource,0,nil)!,[kCGImagePropertyOrientation:6] as CFDictionary)
        CGImageDestinationFinalize(orientationDestination)
        let orientationFile = root.appendingPathComponent("rotated.jpg")
        try (oriented as Data).write(to:orientationFile)
        do {
            try ChapterImagePDF.write(images:[orientationFile],to:root.appendingPathComponent("rotated.pdf"),pageWidth:20)
            throw WebsiteDownloadError("EXIF silently accepted")
        } catch let error as WebsiteDownloadError { try check(error.message.contains("EXIF orientation"), "Explicit EXIF rejection") }
        let container = try ModelContainer(for:Book.self,Chapter.self,Bookmark.self,configurations:ModelConfiguration(isStoredInMemoryOnly:true))
        let service = ImportService()
        let book = try service.addSeries(NewSeriesDraft(title:"Fixture",folderName:"Fixture",note:"",url:""),isSecret:true,rootURL:root,modelContext:container.mainContext)
        let folder = root.appendingPathComponent("Fixture")
        let first = try await service.saveCapturedChapter(data,for:book,filename:"Chapter 12.5.pdf",seriesFolderURL:folder,isEnglish:true,modelContext:container.mainContext)
        let second = try await service.saveCapturedChapter(data,for:book,filename:"Chapter 12.5.pdf",seriesFolderURL:folder,isEnglish:true,modelContext:container.mainContext)
        try check(first != second && first.deletingLastPathComponent().lastPathComponent == "EN" && book.sortedChapters.count == 2, "Import language and no overwrite")
        try check(PDFDocument(url:first)?.pageCount == 1, "PDFKit opens generated PDF")
        return "PASS: chapter scope/dedup/order/numbers (4 providers), dynamic DOM/lazy/picture/ads, one-page geometry, JPEG byte identity, PNG lossless, seam pixels, EN import, no overwrite, PDFKit open, Omega pagination/incomplete response, HTTP403/Referer/no retry, cancellation, blob/data chunk transfer, ICC, EXIF rejection, fixed-width long pages and reader width fitting; inert HTML/no navigation, 3-way download ordering, cancellation and size cap." + benchmark
    }
}

final class ImageProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "images.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let success = request.value(forHTTPHeaderField: "Referer") == "https://reader.example/chapter-1"
        let response = HTTPURLResponse(url:request.url!,statusCode:success ? 200 : 403,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if success { client?.urlProtocol(self,didLoad:Data([1,2,3,4])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
