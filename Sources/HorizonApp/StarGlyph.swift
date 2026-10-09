import SwiftUI

struct StarGlyph: View {
    let style: SpaceNodeStyle
    let emphasized: Bool
    var body: some View {
        ZStack {
            Circle().fill(style.color.opacity(emphasized ? 0.3 : 0.1))
                .frame(width: emphasized ? 32 : 24, height: emphasized ? 32 : 24).blur(radius: 7)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = style.radius * (emphasized ? 1.3 : 1)
                var path = Path()
                for step in 0..<(style.rays * 2) {
                    let angle = Double(step) * .pi / Double(style.rays) - .pi / 2
                    let r = step % 2 == 0 ? radius : radius * style.innerRadius
                    let p = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath(); context.fill(path, with: .color(style.color))
                if style.category == .media {
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)), with: .color(style.color.opacity(0.25)), lineWidth: 0.5)
                }
            }.frame(width: 38, height: 38)
            Circle().fill(Theme.text).frame(width: emphasized ? 4 : 2.5, height: emphasized ? 4 : 2.5)
                .shadow(color: style.color.opacity(0.85), radius: emphasized ? 10 : 5)
        }.accessibilityHidden(true)
    }
}
