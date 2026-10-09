import Foundation
import UniformTypeIdentifiers

@MainActor enum DropFiles {
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var result: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let candidate: URL?
                    if let url = item as? URL { candidate = url }
                    else if let data = item as? Data { candidate = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let string = item as? String { candidate = URL(string: string) }
                    else { candidate = nil }
                    continuation.resume(returning: candidate?.isFileURL == true ? candidate : nil)
                }
            }
            if let url { result.append(url) }
        }
        return result
    }
}
