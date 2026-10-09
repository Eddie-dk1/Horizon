import Foundation
import CoreGraphics

/// Rendered positions come from the encrypted catalogue. New stars never move existing ones.
struct SpaceLayout {
    private(set) var positions: [UUID: CGPoint] = [:]
    private var nextSlot = 0
    mutating func update(_ ids: [UUID], saved: [UUID: CGPoint] = [:]) {
        let retained = Set(ids)
        positions = positions.filter { retained.contains($0.key) }
        for (id, point) in saved where retained.contains(id) { positions[id] = point }
        for id in ids where positions[id] == nil {
            let slot = Double(nextSlot)
            let angle = slot * 2.399963229728653 - 0.85
            let radius = 166 + sqrt(slot) * 48
            positions[id] = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius * 0.78)
            nextSlot += 1
        }
    }
    mutating func set(_ changes: [UUID: CGPoint]) { positions.merge(changes) { _, new in new } }
    static func group(_ id: UUID, parents: [UUID: UUID]) -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for (child, parent) in parents { children[parent, default: []].append(child) }
        var result: Set<UUID> = [id]; var queue = [id]; var index = 0
        while index < queue.count {
            for child in children[queue[index], default: []] where result.insert(child).inserted { queue.append(child) }
            index += 1
        }
        return result
    }
    func fitZoom(ids: [UUID], size: CGSize) -> Double {
        let points = ids.compactMap { positions[$0] }
        let x = max(160, points.map { abs($0.x) + 55 }.max() ?? 160)
        let y = max(140, points.map { abs($0.y) + 65 }.max() ?? 140)
        return max(0.0001, min(1.4, min(max(1, size.width - 80) / (x * 2), max(1, size.height - 110) / (y * 2))))
    }
    static func flightPoint(to target: CGPoint, progress: Double) -> CGPoint {
        let t = min(1, max(0, progress)); let length = max(1, hypot(target.x, target.y))
        let bend = min(65, length * 0.2)
        let control = CGPoint(x: target.x * 0.45 - target.y / length * bend, y: target.y * 0.45 + target.x / length * bend)
        return CGPoint(x: 2 * (1 - t) * t * control.x + t * t * target.x, y: 2 * (1 - t) * t * control.y + t * t * target.y)
    }
    static func centeringOffset(_ point: CGPoint, zoom: Double) -> CGSize {
        CGSize(width: -point.x * zoom, height: -point.y * zoom)
    }
    static func zoomOffset(at anchor: CGPoint, size: CGSize, oldZoom: Double, newZoom: Double, offset: CGSize) -> CGSize {
        let world = worldPoint(anchor, size: size, zoom: oldZoom, offset: offset)
        return CGSize(width: anchor.x - size.width / 2 - world.x * newZoom,
                      height: anchor.y - size.height / 2 - world.y * newZoom)
    }
    static func screenPoint(_ point: CGPoint, size: CGSize, zoom: Double, offset: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + point.x * zoom + offset.width, y: size.height / 2 + point.y * zoom + offset.height)
    }
    static func worldPoint(_ point: CGPoint, size: CGSize, zoom: Double, offset: CGSize) -> CGPoint {
        CGPoint(x: (point.x - size.width / 2 - offset.width) / zoom, y: (point.y - size.height / 2 - offset.height) / zoom)
    }
}

struct SpacePointerInteraction {
    enum Result { case open, move, cancel }
    private(set) var moved = false
    private(set) var cancelled = false
    mutating func update(_ translation: CGSize) {
        if !cancelled && hypot(translation.width, translation.height) >= 6 { moved = true }
    }
    mutating func cancel() { if moved { cancelled = true } }
    mutating func finish() -> Result {
        let result: Result = cancelled ? .cancel : moved ? .move : .open
        moved = false; cancelled = false; return result
    }
}
