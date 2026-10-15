#!/usr/bin/env swift
import AppKit
import SceneKit
import Metal

// Offline, deterministic creative-asset renderer. No simulator or live server.
// Uses the capsule geometry, inset 3D lettering, emissive sphere and lighting
// approach from Views/Chat/GlassThinkingPill.swift's SceneKit surface.
// Background palette and motion follow RootView.ConnectionSheetBackdrop.
// Requires ffmpeg. Run: swift scripts/render-app-store-loop.swift [--preview]
let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("fastlane/app-previews/harness-loop/en-US")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let preview = CommandLine.arguments.contains("--preview")
let fps = 30
let duration = 12.0
let cyan = NSColor(srgbRed: 0.22, green: 0.86, blue: 1, alpha: 1)
func smooth(_ a: Double, _ b: Double, _ t: Double) -> CGFloat {
    let x = min(1, max(0, (t - a) / (b - a)))
    return x * x * (3 - 2 * x)
}

final class Pill {
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    let scene = SCNScene()
    let toy = SCNNode()
    let sphere = SCNNode(geometry: SCNSphere(radius: 0.145))
    let localLight = SCNNode()
    init() {
        renderer.scene = scene
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(toy)
        let shell = SCNBox(width: 2.8, height: 0.88, length: 0.88, chamferRadius: 0.44)
        shell.chamferSegmentCount = 48
        let glass = SCNMaterial()
        glass.lightingModel = .physicallyBased
        glass.diffuse.contents = NSColor(white: 0.13, alpha: 0.26)
        glass.metalness.contents = 0.35
        glass.roughness.contents = 0.06
        glass.transparencyMode = .aOne
        glass.blendMode = .alpha
        glass.writesToDepthBuffer = false
        shell.materials = [glass]
        let shellNode = SCNNode(geometry: shell)
        shellNode.renderingOrder = 10
        toy.addChildNode(shellNode)
        sphere.position = SCNVector3(-0.9, 0, 0)
        sphere.renderingOrder = 20
        let sphereMaterial = SCNMaterial()
        sphereMaterial.lightingModel = .physicallyBased
        sphereMaterial.diffuse.contents = cyan
        sphereMaterial.emission.contents = cyan
        sphereMaterial.roughness.contents = 0.16
        sphere.geometry?.materials = [sphereMaterial]
        toy.addChildNode(sphere)

        let mesh = SCNText(string: "Thinking", extrusionDepth: 0.12)
        mesh.font = .systemFont(ofSize: 0.32, weight: .medium)
        mesh.flatness = 0.005
        mesh.chamferRadius = 0.008
        let text = SCNNode(geometry: mesh)
        let ink = SCNMaterial()
        ink.lightingModel = .physicallyBased
        ink.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        ink.emission.contents = NSColor.white
        ink.emission.intensity = 0.18
        ink.roughness.contents = 0.3
        ink.metalness.contents = 0.25
        mesh.materials = [ink]
        let (low, high) = text.boundingBox
        text.position = SCNVector3(0.22 - (low.x + high.x) / 2, -(low.y + high.y) / 2, -(low.z + high.z) / 2)
        text.renderingOrder = 20
        toy.addChildNode(text)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 0.70
        camera.camera?.wantsHDR = true
        camera.camera?.bloomIntensity = 0.18
        camera.position.z = 7.4
        scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera
        for (position, intensity) in [(SCNVector3(-2, 3, 4), CGFloat(800)), (SCNVector3(3, -2, 2), CGFloat(400))] {
            let light = SCNNode()
            light.light = SCNLight()
            light.light?.type = .omni
            light.light?.intensity = intensity
            light.position = position
            scene.rootNode.addChildNode(light)
        }
        localLight.light = SCNLight()
        localLight.light?.type = .omni
        localLight.light?.color = cyan
        localLight.light?.attenuationEndDistance = 1.4
        localLight.position = SCNVector3(-0.9, 0.15, 0.3)
        toy.addChildNode(localLight)
        scene.lightingEnvironment.contents = NSColor(white: 0.45, alpha: 1)
    }
    func frame(_ time: Double) -> NSImage {
        let pulse = 0.5 - 0.5 * cos(time * .pi * 2 / 2.4)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        toy.eulerAngles = SCNVector3(0.06 * sin(time * .pi / 3), 0.10 * sin(time * .pi / 6), 0)
        let scale = Float(0.90 + 0.24 * pulse)
        sphere.scale = SCNVector3(scale, scale, scale)
        sphere.geometry?.firstMaterial?.emission.intensity = 0.25 + pulse
        localLight.light?.intensity = 60 + 160 * pulse
        SCNTransaction.commit()
        return renderer.snapshot(atTime: time, with: NSSize(width: 1600, height: 640), antialiasingMode: .multisampling4X)
    }
}

func draw(_ ctx: CGContext, width: Int, height: Int, time: Double, pill: Pill) {
    let w = CGFloat(1920), h = CGFloat(height) * w / CGFloat(width)
    ctx.scaleBy(x: CGFloat(width) / w, y: CGFloat(width) / w)
    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.setFillColor(NSColor(srgbRed: 0.035, green: 0.04, blue: 0.085, alpha: 1).cgColor)
    ctx.fill(bounds)
    let phase = time * 2 * .pi / duration
    let colors: [(NSColor, CGFloat, CGFloat, CGFloat)] = [
        (.systemIndigo, 0.25 + 0.12 * cos(phase), 0.70 + 0.12 * sin(phase), 800),
        (.systemPurple, 0.55 + 0.18 * sin(phase), 0.70 + 0.16 * cos(phase), 760),
        (.systemCyan, 0.28 + 0.17 * cos(phase + 2), 0.22 + 0.16 * sin(phase + 2), 690),
        (.systemOrange, 0.77 + 0.10 * sin(phase + 1), 0.22 + 0.12 * cos(phase), 600)
    ]
    ctx.setBlendMode(.plusLighter)
    for (color, x, y, radius) in colors {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [color.withAlphaComponent(0.26).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1])!
        let center = CGPoint(x: w * x, y: h * y)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsBeforeStartLocation])
    }
    ctx.setBlendMode(.normal)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let entry = smooth(0.25, 1.05, time)
    let scroll = smooth(3.5, 5.5, time)
    let bubbleAlpha = entry * (1 - smooth(4.8, 5.8, time))
    if bubbleAlpha > 0 {
        ctx.saveGState()
        ctx.setAlpha(bubbleAlpha)
        let scale = 0.92 + 0.08 * entry
        ctx.translateBy(x: w / 2, y: h / 2 + scroll * h * 0.52 - (1 - entry) * 90)
        ctx.scaleBy(x: scale, y: scale)
        let bubble = CGRect(x: -460, y: -135, width: 920, height: 270)
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 42, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        NSColor(srgbRed: 0.02, green: 0.48, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 70, yRadius: 70).fill()
        let tail = NSBezierPath()
        tail.move(to: CGPoint(x: 414, y: -90))
        tail.curve(to: CGPoint(x: 484, y: -132), controlPoint1: CGPoint(x: 450, y: -100), controlPoint2: CGPoint(x: 448, y: -117))
        tail.curve(to: CGPoint(x: 397, y: -116), controlPoint1: CGPoint(x: 447, y: -142), controlPoint2: CGPoint(x: 413, y: -131))
        tail.close(); tail.fill()
        ctx.setShadow(offset: .zero, blur: 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 6
        let text = NSAttributedString(string: "What if iOS had\nan AI Harness?", attributes: [.font: NSFont.systemFont(ofSize: 66, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        text.draw(in: CGRect(x: -420, y: -84, width: 840, height: 170))
        ctx.restoreGState()
    }
    let thinkingAlpha = smooth(4.5, 5.5, time) * (1 - smooth(10.1, 11.5, time))
    if thinkingAlpha > 0 {
        ctx.saveGState()
        ctx.setAlpha(thinkingAlpha)
        let arrival = smooth(4.5, 5.7, time)
        let image = pill.frame(time)
        let width = 980 * (0.90 + 0.10 * arrival)
        let height = width * 0.4
        let y = h / 2 - (1 - arrival) * 100
        image.draw(in: CGRect(x: (w - width) / 2, y: y - height / 2, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()
    }
}

let pill = Pill()
for (name, fullHeight) in [("header", 1646), ("search-results", 2560)] {
    let width = preview ? 1920 : 3840
    // Even dimensions are required by H.264/yuv420p.
    let height = preview ? (fullHeight / 4) * 2 : fullHeight
    let url = output.appendingPathComponent("\(name)\(preview ? "-preview" : "")-loop.mp4")
    let pipe = Pipe()
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    encoder.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pixel_format", "rgb0", "-video_size", "\(width)x\(height)", "-framerate", "\(fps)", "-i", "pipe:0", "-an", "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-movflags", "+faststart", url.path]
    encoder.standardInput = pipe
    try encoder.run()
    for frame in 0..<Int(duration * Double(fps)) {
        try autoreleasepool {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            draw(ctx, width: width, height: height, time: Double(frame) / Double(fps), pill: pill)
            // The bitmap memory is already top-down, despite Quartz's drawing coordinates.
            try pipe.fileHandleForWriting.write(contentsOf: Data(bytes: ctx.data!, count: width * height * 4))
            if frame % 90 == 0 { print("\(name): \(frame)/360") }
        }
    }
    try pipe.fileHandleForWriting.close()
    encoder.waitUntilExit()
    precondition(encoder.terminationStatus == 0, "Video encoding failed")
    print("Rendered \(url.path)")
}
