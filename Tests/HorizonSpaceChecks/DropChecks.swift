import Foundation
import UniformTypeIdentifiers

@main enum DropChecks {
    @MainActor static func main() async {
        let url = URL(fileURLWithPath: "/tmp/Horizon-drop-test.txt")
        let providers = [
            NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: Data(url.absoluteString.utf8) as NSData, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: url.absoluteString as NSString, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: "https://example.invalid/file" as NSString, typeIdentifier: UTType.fileURL.identifier)
        ]
        let urls = await DropFiles.urls(from: providers)
        guard urls.count == 3, urls.allSatisfy({ $0.standardizedFileURL == url.standardizedFileURL }) else {
            fatalError("Local URL, data and string representations must load; remote URLs must be rejected: \(urls)")
        }
        print("Drop: NSURL, NSData, NSString and non-file rejection — PASS")
    }
}
