import SwiftUI
import HorizonCore

enum Theme {
    static let background = Color(hex: 0x08090D)
    static let surface = Color(hex: 0x14161C)
    static let text = Color(hex: 0xF3F1EC)
    static let muted = Color(hex: 0x969AA5)
    static let amber = Color(hex: 0xE6B57B)
    static let line = Color.white.opacity(0.075)
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
struct HorizonButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).padding(.horizontal, 17).padding(.vertical, 11)
            .foregroundStyle(primary ? Theme.background : Theme.text)
            .background(primary ? Theme.amber.opacity(configuration.isPressed ? 0.7 : 1) : Color.white.opacity(configuration.isPressed ? 0.1 : 0.045), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(primary ? Color.clear : Theme.line))
    }
}
struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.textFieldStyle(.plain).padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line)) }
}
func itemSymbol(_ item: VaultItem) -> String {
    if item.isFolder { return "folder" }
    if item.isNote { return "note.text" }
    switch (item.name as NSString).pathExtension.lowercased() {
    case "pdf": return "doc.richtext"
    case "png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "webp": return "photo"
    case "mp4", "mov", "mkv": return "film"
    case "mp3", "wav", "m4a": return "waveform"
    case "zip", "7z", "rar": return "doc.zipper"
    default: return "doc"
    }
}
func sizeLabel(_ item: VaultItem) -> String { item.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file) }
func typeLabel(_ item: VaultItem) -> String {
    if item.isFolder { return "Папка" }; if item.isNote { return "Заметка" }
    let ext = (item.name as NSString).pathExtension
    return ext.isEmpty ? "Файл" : ext.uppercased()
}
func spaceCountText(stars: Int, galaxies: Int) -> String {
    func counted(_ count: Int, one: String, few: String, many: String) -> String {
        let word: String
        if (11...14).contains(count % 100) { word = many }
        else { switch count % 10 { case 1: word = one; case 2...4: word = few; default: word = many } }
        return "\(count) \(word)"
    }
    return counted(stars, one: "звезда", few: "звезды", many: "звёзд") + " и "
        + counted(galaxies, one: "галактика", few: "галактики", many: "галактик")
}

struct BlackHole: View {
    var lit = true
    var active = true
    var stars = true
    var radiusScale = 1.0
    var absorption = 0
    @State private var flight = 0.0
    @State private var flying = false
    @State private var flightID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var moving: Bool { active && !reduceMotion && scenePhase == .active }
    var body: some View {
        ZStack {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { timeline in
            Canvas { context, size in
                let t = moving ? timeline.date.timeIntervalSinceReferenceDate : 0
                if stars {
                    for i in 0..<60 {
                        let x = CGFloat((i * 173 + 31) % 997) / 997 * size.width
                        let y = CGFloat((i * 227 + 71) % 991) / 991 * size.height
                        let radius = i % 7 == 0 ? 1.2 : 0.65
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(i % 5 == 0 ? 0.35 : 0.13)))
                    }
                }
                let scale = min(size.width / 560, size.height / 440)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var c = context
                c.translateBy(x: center.x, y: center.y)
                c.scaleBy(x: scale * radiusScale, y: scale * radiusScale)
                let strength = lit ? 1.0 : 0.19
                let halo = Path(ellipseIn: CGRect(x: -142, y: -134, width: 284, height: 268))
                for (width, alpha) in [(65.0, 0.02), (46, 0.035), (32, 0.08)] {
                    c.stroke(halo, with: .color(Theme.amber.opacity(alpha * strength * (1.2 + sin(t * 1.1) * 0.25))), lineWidth: width)
                }
                // The asymmetric accretion flow surrounds a black aperture.
                // Visible circulation stays in the accretion flow; stars remain clickable.
                for i in 0..<180 {
                    let angle = Double(i) / 180 * .pi * 2
                    let next = Double(i + 1) / 180 * .pi * 2
                    let brightness = 0.12 + 0.88 * pow((1 + sin(angle - t * 0.55)) / 2, 2)
                    let radius = 142 + 4 * sin(angle * 3 - t * 0.7)
                    let segment = Path { path in
                        path.move(to: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius * 0.94))
                        path.addLine(to: CGPoint(x: cos(next) * radius, y: sin(next) * radius * 0.94))
                    }
                    let color = Color(red: 0.91 + brightness * 0.09, green: 0.27 + brightness * 0.49, blue: 0.08 + brightness * 0.35)
                    c.stroke(segment, with: .color(color.opacity((0.3 + brightness * 0.68) * strength)), style: StrokeStyle(lineWidth: 18 + brightness * 15, lineCap: .round))
                }
                let aperture = Path(ellipseIn: CGRect(x: -111, y: -104, width: 222, height: 208))
                c.fill(aperture, with: .color(Color(hex: 0x020307)))
                c.stroke(aperture, with: .color(Theme.amber.opacity(0.22 * strength)), lineWidth: 0.8)
                for i in 0..<24 {
                    let phase = Double(i) * 2.399963
                    let radius = 160 + Double(i % 5) * 5
                    let angle = phase + t * (0.65 + Double(i % 3) * 0.15)
                    var trail = Path()
                    for step in 0..<9 {
                        let a = angle - Double(step) * 0.018
                        let point = CGPoint(x: cos(a) * radius, y: sin(a) * radius * 0.94)
                        if step == 0 { trail.move(to: point) } else { trail.addLine(to: point) }
                    }
                    c.stroke(trail, with: .color(Theme.amber.opacity((i % 3 == 0 ? 0.6 : 0.25) * strength)), style: StrokeStyle(lineWidth: i % 3 == 0 ? 1.6 : 0.8, lineCap: .round))
                }
            }
        }
        if flying {
            GeometryReader { geometry in
                Image(systemName: "sparkle").font(.system(size: 23)).foregroundStyle(Theme.amber)
                    .scaleEffect(1 - flight * 0.96).opacity(1 - flight * 0.2)
                    .position(x: geometry.size.width / 2 - geometry.size.width * 0.25 * (1 - flight), y: geometry.size.height / 2 + geometry.size.height * 0.15 * (1 - flight))
            }
        }
        }.accessibilityHidden(true).onChange(of: absorption) { _, _ in
            guard active, !reduceMotion else { return }
            let id = UUID(); flightID = id; flight = 0; flying = true
            withAnimation(.easeIn(duration: 0.65)) { flight = 1 }
            Task { try? await Task.sleep(for: .milliseconds(700)); if flightID == id { flying = false } }
        }
    }
}
