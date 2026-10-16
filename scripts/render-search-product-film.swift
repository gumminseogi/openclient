#!/usr/bin/env swift
import AppKit

// Deterministic, silent product film. Existing app photography, native type,
// a white cyclorama, and a frame-exact white-to-white loop.
// swift scripts/render-search-product-film.swift [--stills] [--preview] [--locale=it|pt-BR]
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let args = CommandLine.arguments
let locale = args.first(where: { $0.hasPrefix("--locale=") })?.components(separatedBy: "=").last ?? "en-US"
let copy: [String: [String]] = [
    "en-US": ["Big ideas.", "Now in your hands.", "Meet OpenClient.", "Your OpenCode.", "Anywhere.", "Your server. Your projects.", "Native on iPhone and iPad."],
    "it": ["Grandi idee.", "Ora nelle tue mani.", "Scopri OpenClient.", "Il tuo OpenCode.", "Ovunque.", "Il tuo server. I tuoi progetti.", "Nativo su iPhone e iPad."],
    "pt-BR": ["Grandes ideias.", "Agora nas suas mãos.", "Conheça o OpenClient.", "Seu OpenCode.", "Onde estiver.", "Seu servidor. Seus projetos.", "Nativo no iPhone e iPad."]
]
guard let words = copy[locale] else { fatalError("Unsupported locale") }
let output = root.appendingPathComponent("fastlane/app-previews/product-film/\(locale)")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let screenURL = root.appendingPathComponent("fastlane/screenshots/en_US/iPhone-18-Pro-Max-07-sessions.png")
guard let screen = NSImage(contentsOf: screenURL) else { fatalError("Missing app capture") }
let black = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
let blue = NSColor(srgbRed: 0.02, green: 0.38, blue: 0.94, alpha: 1)
let gray = NSColor(srgbRed: 0.43, green: 0.44, blue: 0.46, alpha: 1)
let fps = 30
let duration = 16.0
let width = args.contains("--preview") ? 1920 : 3840
let height = width * 2 / 3

func ease(_ start: Double, _ end: Double, _ t: Double) -> CGFloat {
    let x = min(1, max(0, (t - start) / (end - start)))
    return x * x * x * (x * (x * 6 - 15) + 10)
}
func opacity(_ start: Double, _ end: Double, _ t: Double, fade: Double = 0.65) -> CGFloat {
    ease(start, start + fade, t) * (1 - ease(end - fade, end, t))
}
func text(_ value: String, at point: CGPoint, size: CGFloat, color: NSColor = black,
          alpha: CGFloat = 1, centered: Bool = true, tracking: CGFloat = -3, maxWidth: CGFloat = 1600) {
    guard alpha > 0 else { return }
    var fontSize = size
    func attributed() -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: size > 70 ? .bold : .medium),
            .foregroundColor: color.withAlphaComponent(alpha), .kern: tracking
        ])
    }
    var string = attributed()
    if string.size().width > maxWidth {
        fontSize *= maxWidth / string.size().width
        string = attributed()
    }
    let size = string.size()
    string.draw(at: CGPoint(x: point.x - (centered ? size.width / 2 : 0), y: point.y - size.height / 2))
}
func glow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor, alpha: CGFloat) {
    let colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func phone(_ ctx: CGContext, x: CGFloat, y: CGFloat, h: CGFloat, angle: CGFloat, alpha: CGFloat, turn: CGFloat) {
    guard alpha > 0 else { return }
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setAlpha(alpha)
    // Fade the finished device as one image. Per-draw alpha lets the metallic
    // shell and black bezel show through the screenshot during a dissolve.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    defer { ctx.endTransparencyLayer() }
    ctx.translateBy(x: x, y: y)
    ctx.rotate(by: angle)
    ctx.concatenate(CGAffineTransform(a: 1 - 0.14 * turn, b: 0.025 * turn, c: 0.035 * turn, d: 1, tx: 0, ty: 0))
    let w = h * screen.size.width / screen.size.height
    let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    let shell = rect.insetBy(dx: -12, dy: -12)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 16, height: -24), blur: 45, color: NSColor.black.withAlphaComponent(0.18).cgColor)
    NSColor(white: 0.64, alpha: 1).setFill()
    NSBezierPath(roundedRect: shell, xRadius: 58, yRadius: 58).fill()
    ctx.restoreGState()
    let rail = NSGradient(colors: [NSColor(white: 0.45, alpha: 1), .white, NSColor(white: 0.72, alpha: 1), NSColor(white: 0.30, alpha: 1)])!
    rail.draw(in: NSBezierPath(roundedRect: shell, xRadius: 58, yRadius: 58), angle: 20 + turn * 25)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: rect.insetBy(dx: -7, dy: -7), xRadius: 53, yRadius: 53).fill()
    ctx.saveGState()
    NSBezierPath(roundedRect: rect, xRadius: 47, yRadius: 47).addClip()
    screen.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    // A quiet moving studio reflection catches only the outer edge.
    ctx.restoreGState()
    NSColor.white.withAlphaComponent(0.65).setStroke()
    let edge = NSBezierPath(roundedRect: shell.insetBy(dx: 1, dy: 1), xRadius: 57, yRadius: 57)
    edge.lineWidth = 1.5
    edge.stroke()
    NSColor(white: 0.38, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: -w / 2 - 15, y: h * 0.21, width: 4, height: 50), xRadius: 2, yRadius: 2).fill()
    NSBezierPath(roundedRect: CGRect(x: w / 2 + 11, y: h * 0.15, width: 4, height: 70), xRadius: 2, yRadius: 2).fill()
}

func draw(_ ctx: CGContext, time t: Double) {
    ctx.scaleBy(x: CGFloat(width) / 1920, y: CGFloat(height) / 1280)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1920, height: 1280).fill()

    // Act I: typography has the scale and weight of the product itself.
    let first = opacity(0.35, 3.45, t)
    let firstIn = ease(0.35, 1.6, t)
    text(words[0], at: CGPoint(x: 960, y: 660 - 60 * (1 - firstIn) + 35 * ease(2.75, 3.45, t)),
         size: 210 - 10 * firstIn, alpha: first, tracking: -7 + 12 * (1 - firstIn))
    let second = opacity(3.15, 6.2, t)
    let secondIn = ease(3.15, 4.4, t)
    text(words[1], at: CGPoint(x: 960, y: 660 - 45 * (1 - secondIn)), size: 139,
         alpha: second, tracking: -5 + 6 * (1 - secondIn))

    // Act II: a single physical object arrives, then makes room for the promise.
    let arrival = ease(6.0, 7.65, t)
    let settle = ease(8.25, 10.25, t)
    let exit = 1 - ease(14.35, 15.65, t)
    let departure = ease(14.0, 15.65, t)
    let productAlpha = ease(6.0, 7.3, t) * (1 - departure)
    let x = 960 + settle * 420
    let y = 535 + settle * 110 - (1 - arrival) * 65 + departure * 18
    let h = (775 + arrival * 25 + settle * 135) * (1 - departure * 0.035)
    if productAlpha > 0 {
        // Light is attached to the product, never a full-screen gradient.
        glow(ctx, center: CGPoint(x: x, y: 390), radius: 390, color: .systemCyan, alpha: productAlpha * 0.065)
        glow(ctx, center: CGPoint(x: x + 110, y: 580), radius: 310, color: .systemIndigo, alpha: productAlpha * 0.035)
        phone(ctx, x: x, y: y, h: h, angle: -0.055 * (1 - arrival) + 0.025 * settle,
              alpha: productAlpha, turn: 0.45 * (1 - arrival) + 0.32 * settle)
    }
    text(words[2], at: CGPoint(x: 960, y: 1100), size: 74,
         alpha: opacity(5.8, 9.0, t), tracking: -2)

    // Act III: a calm, legible end card. All copy remains live vector type.
    let copyIn = ease(8.8, 10.1, t)
    let a = copyIn * exit
    let left: CGFloat = 190
    text(words[3], at: CGPoint(x: left, y: 800 - (1 - copyIn) * 35), size: 96, alpha: a, centered: false, tracking: -4, maxWidth: 910)
    text(words[4], at: CGPoint(x: left, y: 690 - (1 - copyIn) * 35), size: 113, color: blue, alpha: a, centered: false, tracking: -5, maxWidth: 910)
    let detail = ease(9.55, 10.65, t) * exit
    text(words[5], at: CGPoint(x: left + 3, y: 555), size: 34, color: gray, alpha: detail, centered: false, tracking: -0.5, maxWidth: 880)
    text(words[6], at: CGPoint(x: left + 3, y: 507), size: 34, color: gray, alpha: detail, centered: false, tracking: -0.5, maxWidth: 880)
    text("OpenClient", at: CGPoint(x: left + 3, y: 250), size: 38, alpha: detail, centered: false, tracking: -1)
}

func frame(at time: Double) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(ctx, time: time)
    return ctx
}

if args.contains("--stills") {
    for t in [1.8, 4.5, 6.65, 7.6, 11.8, 14.85] {
        let image = NSBitmapImageRep(cgImage: frame(at: t).makeImage()!)
        try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("storyboard-\(t).png"))
    }
} else {
    let url = output.appendingPathComponent("search-results\(args.contains("--preview") ? "-preview" : "").mp4")
    let encoder = Process()
    let pipe = Pipe()
    encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    encoder.arguments = ["-v", "error", "-y", "-f", "rawvideo", "-pixel_format", "rgb0", "-video_size", "\(width)x\(height)",
                         "-framerate", "\(fps)", "-i", "pipe:0", "-an", "-c:v", "libx264", "-preset", "fast", "-crf", "18",
                         "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                         "-movflags", "+faststart", url.path]
    encoder.standardInput = pipe
    try encoder.run()
    for index in 0..<Int(duration * Double(fps)) {
        try autoreleasepool {
            let ctx = frame(at: Double(index) / Double(fps))
            try pipe.fileHandleForWriting.write(contentsOf: Data(bytes: ctx.data!, count: width * height * 4))
        }
        if index % 90 == 0 { print("Rendered \(index)/\(Int(duration * Double(fps))) frames") }
    }
    try pipe.fileHandleForWriting.close()
    encoder.waitUntilExit()
    precondition(encoder.terminationStatus == 0, "Encoder failed")
    print("Created \(url.path)")
}
