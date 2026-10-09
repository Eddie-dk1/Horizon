import Foundation

public struct SpacePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && abs(x) <= 1_000_000 && abs(y) <= 1_000_000 }
    public static func automatic(_ slot: Int) -> SpacePoint {
        let angle = Double(slot) * 2.399963229728653 - 0.85
        let radius = 166 + sqrt(Double(slot)) * 48
        return SpacePoint(x: cos(angle) * radius, y: sin(angle) * radius * 0.78)
    }
    static func available(near: SpacePoint?, spacing: Double, occupied: [SpacePoint]) throws -> SpacePoint {
        guard near?.isValid != false, spacing.isFinite, spacing >= 1, spacing <= 100_000 else {
            throw HorizonError.message("Недопустимое расположение на карте.")
        }
        for slot in 0..<100_100 {
            let point: SpacePoint
            if let near {
                let radius = slot == 0 ? 0 : spacing * sqrt(Double(slot))
                let angle = Double(slot) * 2.399963229728653
                point = SpacePoint(x: near.x + cos(angle) * radius, y: near.y + sin(angle) * radius)
            } else { point = automatic(occupied.count + slot) }
            if point.isValid, pow(point.x / 150, 2) + pow(point.y / 130, 2) >= 1,
               !occupied.contains(where: { hypot($0.x - point.x, $0.y - point.y) < spacing }) { return point }
        }
        throw HorizonError.message("Не удалось найти свободное место на карте.")
    }
}

public struct ImportPlacement: Sendable {
    public let point: SpacePoint
    public let spacing: Double
    public init(point: SpacePoint, spacing: Double = 56) { self.point = point; self.spacing = spacing }
}
