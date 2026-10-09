import SwiftUI
import UniformTypeIdentifiers

struct SpaceNodeStyle: Equatable {
    enum Category: String { case image, document, note, media, other, galaxy }
    let category: Category
    var hex: UInt32 {
        switch category {
        case .image: 0xA9CCD8
        case .document: 0xF3F1EC
        case .note, .galaxy: 0xE6B57B
        case .media: 0xB6AACF
        case .other: 0xB1B6C2
        }
    }
    var color: Color { Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
    var rays: Int { switch category { case .image, .media: 6; case .note: 8; default: 4 } }
    var innerRadius: Double { category == .image ? 0.32 : category == .other ? 0.27 : 0.17 }
    var radius: Double { category == .other ? 7 : category == .image ? 8 : 9 }
    static func resolve(kind: String, name: String) -> SpaceNodeStyle {
        if kind == "folder" { return .init(category: .galaxy) }
        if kind == "note" { return .init(category: .note) }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "csv"].contains(ext) { return .init(category: .document) }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .init(category: .image) }
            if type.conforms(to: .audio) || type.conforms(to: .movie) { return .init(category: .media) }
            if type.conforms(to: .text) || type.conforms(to: .pdf) { return .init(category: .document) }
        }
        // Launch Services can return dynamic UTIs in restricted command-line environments.
        // Keep common formats recognizable even when the system registry is unavailable.
        if ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "svg", "avif"].contains(ext) { return .init(category: .image) }
        if ["mp3", "wav", "m4a", "aac", "aif", "aiff", "flac", "ogg", "mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(ext) { return .init(category: .media) }
        if ["txt", "md", "log", "json", "yaml", "yml", "xml", "html", "css", "js", "swift", "py", "sh", "pages", "numbers", "key"].contains(ext) { return .init(category: .document) }
        return .init(category: .other)
    }
}
