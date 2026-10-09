import AppKit
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func draw(_ size: Int, destination: URL) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = CGColor(red: 0.048, green: 0.056, blue: 0.076, alpha: 1)
    let shape = CGPath(roundedRect: CGRect(x: 56, y: 56, width: 912, height: 912), cornerWidth: 205, cornerHeight: 205, transform: nil)
    context.addPath(shape); context.setFillColor(background); context.fillPath()
    context.addPath(shape); context.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); context.setLineWidth(2); context.strokePath()
    context.addPath(shape); context.clip()
    context.translateBy(x: 512, y: 514)
    // An event-horizon silhouette with an asymmetric, luminous accretion flow.
    // There is no orbital ellipse: the center is an empty black aperture.
    let halo = CGRect(x: -239, y: -226, width: 478, height: 452)
    context.setLineWidth(82)
    context.setStrokeColor(CGColor(red: 0.98, green: 0.42, blue: 0.16, alpha: 0.2))
    if size >= 64 { context.setShadow(offset: .zero, blur: CGFloat(size) / 1024 * 60, color: CGColor(red: 0.95, green: 0.39, blue: 0.12, alpha: 0.55)) }
    context.strokeEllipse(in: halo)
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setLineCap(.round)
    let segments = size < 64 ? 72 : 360
    for i in 0..<segments {
        let angle = Double(i) / Double(segments) * .pi * 2
        let next = Double(i + 1) / Double(segments) * .pi * 2 + 0.006
        let brightness = 0.18 + 0.82 * pow((1 + cos(angle + .pi / 2 + 0.38)) / 2, 1.4)
        let radius = 240 + 5 * sin(angle * 3)
        let color = CGColor(red: 0.91 + brightness * 0.09, green: 0.27 + brightness * 0.49, blue: 0.08 + brightness * 0.35, alpha: 0.3 + brightness * 0.68)
        context.setStrokeColor(color)
        context.setLineWidth(42 + brightness * 32)
        if size >= 64 { context.setShadow(offset: .zero, blur: CGFloat(size) / 1024 * 14, color: color.copy(alpha: 0.26)) }
        context.beginPath()
        context.move(to: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius * 0.94))
        context.addLine(to: CGPoint(x: cos(next) * radius, y: sin(next) * radius * 0.94))
        context.strokePath()
    }
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setFillColor(CGColor(red: 0.007, green: 0.009, blue: 0.015, alpha: 1))
    context.fillEllipse(in: CGRect(x: -189, y: -178, width: 378, height: 356))
    if size >= 128 {
        // Fine inner photon rim. Stronger on the lower, approaching side.
        for i in 0..<180 {
            let angle = Double(i) / 180 * .pi * 2
            let next = Double(i + 1) / 180 * .pi * 2
            let brightness = (1 + cos(angle + .pi / 2 + 0.38)) / 2
            context.setStrokeColor(CGColor(red: 1, green: 0.69, blue: 0.37, alpha: 0.08 + brightness * 0.5))
            context.setLineWidth(2)
            context.beginPath(); context.move(to: CGPoint(x: cos(angle) * 190, y: sin(angle) * 179))
            context.addLine(to: CGPoint(x: cos(next) * 190, y: sin(next) * 179)); context.strokePath()
        }
    }
    guard let image = context.makeImage(), let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Icon generation failed") }
    CGImageDestinationAddImage(writer, image, nil); guard CGImageDestinationFinalize(writer) else { fatalError("Icon PNG write failed") }
}
for size in [16, 32, 128, 256, 512] {
    try draw(size, destination: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2, destination: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
