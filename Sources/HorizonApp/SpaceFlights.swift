import SwiftUI

struct SpaceFlight: Identifiable {
    let id: UUID
    let itemID: UUID
    let target: CGPoint
    let style: SpaceNodeStyle
    var start: Date?
}

struct SpaceFlights: View, Animatable {
    let flights: [SpaceFlight]
    var zoom: Double
    var offset: CGSize
    let active: Bool
    let connectionOpacity: Double
    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { .init(zoom, .init(offset.width, offset.height)) }
        set { zoom = newValue.first; offset = CGSize(width: newValue.second.first, height: newValue.second.second) }
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: flights.isEmpty || !active)) { timeline in
            Canvas { context, size in
                for flight in flights {
                    guard let start = flight.start else { continue }
                    let elapsed = max(0, timeline.date.timeIntervalSince(start))
                    let t = min(1, max(0, (elapsed - 0.12) / 0.7))
                    let world = SpaceLayout.flightPoint(to: flight.target, progress: t)
                    let point = SpaceLayout.screenPoint(world, size: size, zoom: zoom, offset: offset)
                    let color = flight.style.color
                    if elapsed < 0.12 {
                        let center = SpaceLayout.screenPoint(.zero, size: size, zoom: zoom, offset: offset)
                        let radius = 70 * zoom
                        var glow = context; glow.addFilter(.blur(radius: 18))
                        glow.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(Theme.amber.opacity(0.35 * sin(elapsed / 0.12 * .pi))), lineWidth: 13)
                    }
                    if elapsed < 0.82 {
                        var trail = Path()
                        for step in 0..<12 {
                            let trailing = SpaceLayout.flightPoint(to: flight.target, progress: max(0, t - Double(step) * 0.012))
                            let p = SpaceLayout.screenPoint(trailing, size: size, zoom: zoom, offset: offset)
                            if step == 0 { trail.move(to: p) } else { trail.addLine(to: p) }
                        }
                        context.stroke(trail, with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        var glow = context; glow.addFilter(.blur(radius: 6))
                        glow.fill(Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)), with: .color(color.opacity(0.65)))
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(Theme.text))
                    } else {
                        let settle = min(1, (elapsed - 0.82) / 0.18)
                        var link = Path(); link.move(to: SpaceLayout.screenPoint(.zero, size: size, zoom: zoom, offset: offset)); link.addLine(to: point)
                        context.stroke(link, with: .color(Theme.amber.opacity(settle * connectionOpacity)), lineWidth: 0.65)
                        let radius = flight.style.radius * (0.4 + 0.6 * settle)
                        var star = Path()
                        for step in 0..<(flight.style.rays * 2) {
                            let angle = Double(step) * .pi / Double(flight.style.rays) - .pi / 2
                            let r = step % 2 == 0 ? radius : radius * flight.style.innerRadius
                            let p = CGPoint(x: point.x + cos(angle) * r, y: point.y + sin(angle) * r)
                            if step == 0 { star.move(to: p) } else { star.addLine(to: p) }
                        }
                        star.closeSubpath(); context.fill(star, with: .color(color))
                    }
                }
            }
        }.accessibilityHidden(true)
    }
}
