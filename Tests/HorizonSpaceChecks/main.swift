import Foundation
import CoreGraphics

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let ids = (0..<250).map { _ in UUID() }
var layout = SpaceLayout()
layout.update(Array(ids.prefix(7)))
check(layout.positions.count == 7, "The seventh record must have a star")
let first = layout.positions
layout.update(ids)
check(layout.positions.count == 250, "No records may be truncated")
for (id, point) in first { check(layout.positions[id] == point, "Adding stars must preserve existing positions") }
let viewport = CGSize(width: 960, height: 450)
let zoom = layout.fitZoom(ids: ids, size: viewport)
for id in ids {
    let point = SpaceLayout.screenPoint(layout.positions[id]!, size: viewport, zoom: zoom, offset: .zero)
    check(point.x >= 20 && point.x <= viewport.width - 20 && point.y >= 20 && point.y <= viewport.height - 20, "Fit must show every star in a small viewport")
    let back = SpaceLayout.worldPoint(point, size: viewport, zoom: zoom, offset: .zero)
    let original = layout.positions[id]!
    check(abs(back.x - original.x) < 0.000001 && abs(back.y - original.y) < 0.000001, "Camera coordinates must round trip")
}
let positions = layout.positions
layout.update(Array(ids.dropFirst(10)))
check(layout.positions.count == 240, "Deleted stars must leave the graph")
for id in ids.dropFirst(10) { check(layout.positions[id] == positions[id], "Deleting stars must not move their neighbors") }
// Zooming into a folder must land its galaxy at the exact viewport center,
// regardless of its former position or the chosen zoom.
for z in [0.1, 1.0, 1.8, 4.0] {
    for id in ids.prefix(12) {
        let world = positions[id]!
        let focused = SpaceLayout.screenPoint(world, size: viewport, zoom: z, offset: SpaceLayout.centeringOffset(world, zoom: z))
        check(abs(focused.x - viewport.width / 2) < 0.000001 && abs(focused.y - viewport.height / 2) < 0.000001, "Folder travel must center the selected galaxy")
    }
}
var children = SpaceLayout()
children.update(Array(ids.prefix(3)))
let childZoom = children.fitZoom(ids: Array(ids.prefix(3)), size: viewport)
for id in ids.prefix(3) {
    let p = SpaceLayout.screenPoint(children.positions[id]!, size: viewport, zoom: childZoom, offset: .zero)
    check(p.x > 20 && p.x < viewport.width - 20 && p.y > 20 && p.y < viewport.height - 20, "Folder children must fit around their local galaxy")
}
print("Space: seventh entry, 250 entries, stable positions, viewport fit, camera coordinates and folder focus — PASS")

let rootFolder = UUID(), nestedFolder = UUID(), nestedFile = UUID(), sibling = UUID()
let group = SpaceLayout.group(rootFolder, parents: [nestedFolder: rootFolder, nestedFile: nestedFolder, sibling: UUID()])
check(group == Set([rootFolder, nestedFolder, nestedFile]), "Galaxy movement must include all descendants and exclude siblings")
var persisted = SpaceLayout()
let custom = CGPoint(x: 950, y: -370)
persisted.update([rootFolder, nestedFile], saved: [rootFolder: custom])
check(persisted.positions[rootFolder] == custom, "Saved coordinates must override generated positions")
persisted.update([rootFolder, nestedFile, sibling], saved: [rootFolder: custom])
check(persisted.positions[rootFolder] == custom, "New records must not move saved coordinates")
let farZoom = persisted.fitZoom(ids: [rootFolder], size: viewport)
let farPoint = SpaceLayout.screenPoint(custom, size: viewport, zoom: farZoom, offset: .zero)
check(farPoint.x > 20 && farPoint.x < viewport.width - 20 && farPoint.y > 20 && farPoint.y < viewport.height - 20, "Fit must include manually moved records")
let target = CGPoint(x: -260, y: 180)
check(SpaceLayout.flightPoint(to: target, progress: 0) == .zero, "Flight must start at the central object")
check(SpaceLayout.flightPoint(to: target, progress: 1) == target, "Flight must end at the saved position")
for t in stride(from: 0.0, through: 1.0, by: 0.05) {
    let p = SpaceLayout.flightPoint(to: target, progress: t)
    check(p.x.isFinite && p.y.isFinite, "Flight coordinates must remain finite")
}
check(SpaceNodeStyle.resolve(kind: "note", name: "note.png").category == .note, "Notes take precedence over filename extensions")
check(SpaceNodeStyle.resolve(kind: "folder", name: "folder.pdf").category == .galaxy, "Folders remain galaxies")
for ext in ["png", "jpg", "heic"] { check(SpaceNodeStyle.resolve(kind: "file", name: "image.\(ext)").category == .image, "Image type must use image style") }
for ext in ["pdf", "docx", "pptx", "txt", "md"] { check(SpaceNodeStyle.resolve(kind: "file", name: "doc.\(ext)").category == .document, "Document type must use document style") }
for ext in ["mp3", "mp4", "mov"] { check(SpaceNodeStyle.resolve(kind: "file", name: "media.\(ext)").category == .media, "Media type must use media style") }
check(SpaceNodeStyle.resolve(kind: "file", name: "unknown.horizonunknown").category == .other, "Unknown types have a neutral style")
print("Space: persisted positions, galaxy groups, flight endpoints and file type styles — PASS")

var pointer = SpacePointerInteraction()
pointer.update(CGSize(width: 5.9, height: 0))
check(pointer.finish() == .open, "Small mouse jitter must still open a record")
pointer.update(CGSize(width: 6, height: 0)); pointer.update(.zero)
check(pointer.finish() == .move, "Returning to the start after dragging must never open the record")
pointer.update(CGSize(width: 20, height: 10)); pointer.cancel(); pointer.update(CGSize(width: 40, height: 30))
check(pointer.finish() == .cancel, "Escape must cancel and keep subsequent held motion cancelled")
check(pointer.finish() == .open, "A cancelled gesture must not swallow the next click")
print("Space: click threshold, drag completion, Escape and next-click recovery — PASS")

for oldZoom in [0.05, 0.5, 1.0, 4.0] {
    for newZoom in [0.0001, 0.4, 2.0, 4.0] {
        let anchor = CGPoint(x: 180, y: 125), camera = CGSize(width: 33, height: -41)
        let world = SpaceLayout.worldPoint(anchor, size: viewport, zoom: oldZoom, offset: camera)
        let offset = SpaceLayout.zoomOffset(at: anchor, size: viewport, oldZoom: oldZoom, newZoom: newZoom, offset: camera)
        let result = SpaceLayout.screenPoint(world, size: viewport, zoom: newZoom, offset: offset)
        check(hypot(result.x - anchor.x, result.y - anchor.y) < 0.000001, "Pinch zoom must keep the point under the pointer fixed")
    }
}
print("Space: anchored trackpad zoom at minimum, normal and maximum scales — PASS")
