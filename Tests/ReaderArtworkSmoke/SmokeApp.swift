import SwiftUI

@main
struct ReaderArtworkSmokeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Reader artwork smoke checks")
                .task {
                    let result: String
                    do { result = try await runReaderArtworkChecks() }
                    catch { result = "FAIL: \(error)" }
                    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("result.txt")
                    try? result.write(to: file, atomically: true, encoding: .utf8)
                }
        }
    }
}
