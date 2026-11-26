import SwiftUI
import AppKit

/// Renders the pure Bézier vector ("plain graphics") SparkBar symbol — a horizontal capsule split by the diagonal lightning bolt
/// with filleted inner cutout corners — traced directly from the SparkBar app icon geometry.
public enum SparkBarIconRenderer {
    public static func makeImage(size: CGFloat = 18, isTemplate: Bool = true) -> NSImage {
        let imageSize = NSSize(width: size, height: size)
        if let url = Bundle.main.url(forResource: "SparkBarSymbol", withExtension: "png"),
           let source = NSImage(contentsOf: url) {
            let rendered = NSImage(size: imageSize, flipped: false) { rect in
                NSGraphicsContext.current?.imageInterpolation = .high
                source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                return true
            }
            rendered.isTemplate = isTemplate
            return rendered
        }

        let image = NSImage(size: imageSize, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawSymbol(in: ctx, size: rect.size, capsuleAlpha: isTemplate ? 0.72 : 0.75, boltAlpha: 1.0)
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    public static func buildVectorPaths(
        scale: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) -> (leftCap: CGPath, rightCap: CGPath, bolt: CGPath) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + (1.0 - y) * scale)
        }
        let rCap = 0.105 * scale
        let rFillet = 0.008 * scale

        // 1. Left Capsule Half (Pure Vector Path with filleted inner cutout corners)
        let leftPath = CGMutablePath()
        let lTopStart = pt(0.297, 0.395)
        let lTopCut   = pt(0.4565, 0.395)
        let lNotchOut = pt(0.3190, 0.560)
        let lNotchIn  = pt(0.4533, 0.560)
        let lBotCut   = pt(0.4381, 0.605)
        let lBotStart = pt(0.297, 0.605)

        leftPath.move(to: lTopStart)
        leftPath.addArc(tangent1End: lTopCut, tangent2End: lNotchOut, radius: rFillet)
        leftPath.addArc(tangent1End: lNotchOut, tangent2End: lNotchIn, radius: rFillet * 1.2)
        leftPath.addArc(tangent1End: lNotchIn, tangent2End: lBotCut, radius: rFillet)
        leftPath.addArc(tangent1End: lBotCut, tangent2End: lBotStart, radius: rFillet)
        leftPath.addLine(to: lBotStart)
        leftPath.addArc(
            center: pt(0.297, 0.500),
            radius: rCap,
            startAngle: -.pi / 2,
            endAngle: .pi / 2,
            clockwise: true
        )
        leftPath.closeSubpath()

        // 2. Right Capsule Half (Symmetric Pure Vector Path with filleted inner cutout corners)
        let rightPath = CGMutablePath()
        let rBotStart = pt(0.703, 0.605)
        let rBotCut   = pt(0.5575, 0.605)
        let rNotchOut = pt(0.6950, 0.434)
        let rNotchIn  = pt(0.5627, 0.434)
        let rTopCut   = pt(0.5779, 0.395)
        let rTopStart = pt(0.703, 0.395)

        rightPath.move(to: rBotStart)
        rightPath.addArc(tangent1End: rBotCut, tangent2End: rNotchOut, radius: rFillet)
        rightPath.addArc(tangent1End: rNotchOut, tangent2End: rNotchIn, radius: rFillet * 1.2)
        rightPath.addArc(tangent1End: rNotchIn, tangent2End: rTopCut, radius: rFillet)
        rightPath.addArc(tangent1End: rTopCut, tangent2End: rTopStart, radius: rFillet)
        rightPath.addLine(to: rTopStart)
        rightPath.addArc(
            center: pt(0.703, 0.500),
            radius: rCap,
            startAngle: .pi / 2,
            endAngle: -.pi / 2,
            clockwise: true
        )
        rightPath.closeSubpath()

        // 3. Central Lightning Bolt
        let boltPath = CGMutablePath()
        let boltPts = [
            pt(0.596, 0.262),
            pt(0.366, 0.538),
            pt(0.484, 0.538),
            pt(0.418, 0.733),
            pt(0.648, 0.456),
            pt(0.532, 0.456)
        ]
        boltPath.addLines(between: boltPts)
        boltPath.closeSubpath()

        return (leftPath, rightPath, boltPath)
    }

    public static func drawSymbol(
        in ctx: CGContext,
        size: CGSize,
        capsuleAlpha: CGFloat = 0.72,
        boltAlpha: CGFloat = 1.0
    ) {
        let minDim = min(size.width, size.height)
        let scale = minDim * 1.48
        let offsetX = (size.width - scale) / 2.0
        let offsetY = (size.height - scale) / 2.0

        let paths = buildVectorPaths(scale: scale, offsetX: offsetX, offsetY: offsetY)

        ctx.saveGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(capsuleAlpha).cgColor)
        ctx.addPath(paths.leftCap)
        ctx.fillPath()
        ctx.addPath(paths.rightCap)
        ctx.fillPath()

        ctx.setFillColor(NSColor.white.withAlphaComponent(boltAlpha).cgColor)
        ctx.addPath(paths.bolt)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// SwiftUI view for the flat vector SparkBar icon used in the "Ask anything" bar.
public struct SparkBarLogoView: View {
    public var size: CGFloat = 20
    public var isActive: Bool = false

    public init(size: CGFloat = 20, isActive: Bool = false) {
        self.size = size
        self.isActive = isActive
    }

    public var body: some View {
        Image(nsImage: SparkBarIconRenderer.makeImage(size: size, isTemplate: true))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .renderingMode(.template)
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.85))
            .frame(width: size, height: size)
    }
}
