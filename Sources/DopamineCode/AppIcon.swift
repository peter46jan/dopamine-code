import AppKit

/// The app's own icon, drawn as vectors rather than loaded from an asset.
///
/// A menu bar icon is a *template*: macOS discards the colour and reuses the shape and
/// opacity, inverting it between light and dark menu bars. Drawing it in code means it is
/// crisp at every scale factor, needs no asset catalogue, and — the reason that matters
/// most here — it can shed detail as it gets smaller. The same artwork that reads well at
/// 1024 px turns into a grey smudge at 16.
///
/// The design: a hexagon (dopamine's ring) broken open at the bottom, a laptop inside it,
/// and a state marker sitting in the break.
enum AppIcon {

    enum State {
        /// Sleep is allowed. The ring is whole: nothing is running, nothing is held open.
        case off
        /// Staying awake. An infinity loop: it keeps running.
        case on
        /// The kernel flag does not match what was asked. A bolt — a different silhouette,
        /// not a variation on the calm one.
        case error
    }

    // MARK: - Public

    /// A template image for the menu bar, sized in points.
    static func menuBar(_ state: State, pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            draw(state, in: rect)
            return true
        }
        // Without this the icon keeps its literal black and vanishes on a dark menu bar.
        image.isTemplate = true
        return image
    }

    /// A flat image for exporting, at whatever pixel size is asked for.
    static func flat(_ state: State, pixels: CGFloat, onDark: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
            (onDark ? NSColor.black : NSColor.white).setFill()
            rect.fill()
            (onDark ? NSColor.white : NSColor.black).setFill()
            (onDark ? NSColor.white : NSColor.black).setStroke()
            draw(state, in: rect, colourAlreadySet: true)
            return true
        }
    }

    // MARK: - The Finder / Dock icon

    /// The full-colour app icon: the same mark, on the rounded plate macOS expects.
    ///
    /// This is a different job from the menu bar glyph and needs a different drawing. A
    /// menu bar icon is a template — pure silhouette, one colour, sized for 16 pt. An app
    /// icon sits in Finder and the Dock next to Apple's own, and anything that does not
    /// use their plate shape and their proportions reads as a foreign object there.
    ///
    /// Until now the bundle shipped no icon at all, so macOS drew its generic placeholder.
    static func dock(_ state: State, pixels: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { _ in
            let s = pixels

            // Apple's grid: on a 1024 canvas the plate is 824 across, centred, and the
            // margin that is left over is what the shadow lives in. Lifted a touch so the
            // shadow falls below the plate rather than around it.
            let plateSide = s * 824 / 1024
            let plate = NSRect(
                x: (s - plateSide) / 2,
                y: (s - plateSide) / 2 + s * 0.012,
                width: plateSide, height: plateSide
            )
            let path = squircle(in: plate)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
            shadow.shadowBlurRadius = s * 0.030
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.016)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Violet: "dopamine" is the neurotransmitter joke in the name, and violet is
            // the one hue no other icon in this Dock is using.
            let gradient = NSGradient(colors: [
                NSColor(srgbRed: 0.616, green: 0.451, blue: 1.000, alpha: 1),   // #9D73FF
                NSColor(srgbRed: 0.290, green: 0.129, blue: 0.710, alpha: 1),   // #4A21B5
            ])
            gradient?.draw(in: path, angle: -90)

            // A single soft highlight across the top, the way a physical plate catches
            // light. Clipped to the plate so it cannot bleed over the rounded corners.
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSGradient(colors: [
                NSColor(white: 1, alpha: 0.20),
                NSColor(white: 1, alpha: 0.0),
            ])?.draw(in: NSRect(x: plate.minX, y: plate.midY,
                                width: plate.width, height: plate.height / 2), angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            // The mark itself, in white, at the size Apple's own glyphs occupy inside the
            // plate. `draw` re-derives its level of detail from the side it is given, so
            // handing it a large rect gets the full laptop rather than the 16 pt slab.
            let glyphSide = plateSide * 0.62
            let glyph = NSRect(
                x: plate.midX - glyphSide / 2,
                y: plate.midY - glyphSide / 2,
                width: glyphSide, height: glyphSide
            )
            NSColor.white.setFill()
            NSColor.white.setStroke()
            draw(state, in: glyph, colourAlreadySet: true)
            return true
        }
    }

    /// Apple's plate is a superellipse, not a rounded rectangle: its corners have no point
    /// where the curvature jumps from "straight" to "arc". A plain `roundedRect` next to
    /// the system icons looks subtly pinched at exactly those four points, so this samples
    /// |x|ⁿ + |y|ⁿ = 1 instead. n = 5 is the match for the macOS plate.
    private static func squircle(in rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
        let path = NSBezierPath()
        let a = rect.width / 2, b = rect.height / 2
        let cx = rect.midX, cy = rect.midY
        let steps = 720
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
            let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
        }
        path.close()
        return path
    }

    // MARK: - Drawing

    /// Everything is described in a 0…1 unit square and scaled, so one description serves
    /// every size.
    private static func draw(_ state: State, in rect: NSRect, colourAlreadySet: Bool = false) {
        let side = min(rect.width, rect.height)
        let ox = rect.minX + (rect.width - side) / 2
        let oy = rect.minY + (rect.height - side) / 2

        /// y is given top-down, the way the shape was designed; AppKit draws bottom-up.
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: ox + x * side, y: oy + (1 - y) * side)
        }

        // Three levels of detail, and the thresholds are set by what a contact sheet
        // actually showed rather than by what seemed reasonable. At 16 and 18 pt — the
        // only sizes that matter day to day — the laptop is what clogs the shape: with it
        // in, the three states are indistinguishable. So below 28 pt it becomes a solid
        // slab, and below 22 pt it goes entirely and the ring plus the marker carry the
        // state on their own.
        let detail: CGFloat = side >= 28 ? 2 : (side >= 22 ? 1 : 0)
        let stroke = side * (side >= 28 ? 0.058 : (side >= 22 ? 0.072 : 0.098))

        if !colourAlreadySet {
            NSColor.black.setStroke()
            NSColor.black.setFill()
        }

        // --- the ring, broken open at the bottom --------------------------------------
        let topY: CGFloat = 0.115
        let shoulderY: CGFloat = 0.315
        let hipY: CGFloat = 0.675
        let footY: CGFloat = 0.800
        let leftX: CGFloat = 0.180
        let rightX: CGFloat = 0.820
        // The break in the ring *is* the state. Whole means at rest; broken open means
        // something is being held open, and the marker in the break says what.
        //
        // This replaced a padlock hanging below the ring. At 16 and 18 pt — the sizes that
        // are actually on screen all day — that padlock collapsed into a featureless bump
        // and "off" became hard to tell from "error". A closed ring has no such problem:
        // the three states are three different silhouettes at every size.
        let gap: CGFloat = state == .off ? 0 : 0.185

        let ring = NSBezierPath()
        ring.lineWidth = stroke
        ring.lineJoinStyle = .round
        ring.lineCapStyle = .round
        if state == .off {
            ring.move(to: p(0.5, footY))
        } else {
            ring.move(to: p(0.5 + gap, footY))
        }
        ring.line(to: p(rightX, hipY))
        ring.line(to: p(rightX, shoulderY))
        ring.line(to: p(0.5, topY))
        ring.line(to: p(leftX, shoulderY))
        ring.line(to: p(leftX, hipY))
        ring.line(to: p(0.5 - gap, footY))
        if state == .off { ring.close() }
        ring.stroke()

        // The node at the apex. In the molecule it is a substituent; here it also reads as
        // a hinge pin, which is a happy accident worth keeping.
        let nodeRadius = stroke * (detail > 0 ? 0.95 : 1.15)
        NSBezierPath(ovalIn: NSRect(
            x: p(0.5, topY).x - nodeRadius,
            y: p(0.5, topY).y - nodeRadius,
            width: nodeRadius * 2, height: nodeRadius * 2
        )).fill()

        // --- the laptop ---------------------------------------------------------------
        if detail == 2 {
            let screen = NSRect(
                x: p(0.345, 0).x, y: p(0, 0.560).y,
                width: side * 0.310, height: side * 0.205
            )
            let screenPath = NSBezierPath(roundedRect: screen, xRadius: side * 0.022, yRadius: side * 0.022)
            screenPath.lineWidth = stroke
            screenPath.stroke()

            let base = NSRect(
                x: p(0.300, 0).x, y: p(0, 0.625).y,
                width: side * 0.400, height: side * 0.058
            )
            let basePath = NSBezierPath(roundedRect: base, xRadius: side * 0.026, yRadius: side * 0.026)
            basePath.lineWidth = stroke
            basePath.stroke()

            // The notch in the front edge of the base — the thumb scoop on a MacBook.
            let notch = NSBezierPath()
            notch.lineWidth = stroke * 0.8
            notch.lineCapStyle = .round
            notch.move(to: p(0.455, 0.629))
            notch.line(to: p(0.545, 0.629))
            notch.stroke()
        } else if detail == 1 {
            // One solid slab still reads as "a laptop" once the outline would fill itself in.
            let slab = NSRect(
                x: p(0.335, 0).x, y: p(0, 0.615).y,
                width: side * 0.330, height: side * 0.185
            )
            NSBezierPath(roundedRect: slab, xRadius: side * 0.030, yRadius: side * 0.030).fill()
        }

        // --- the state marker ---------------------------------------------------------
        // With the laptop gone there is room for the marker to be the thing you actually
        // see, which is what makes the three states tell themselves apart when small.
        let markerScale: CGFloat = detail == 0 ? 1.45 : 1.0
        let markerCentre = p(0.5, detail == 0 ? 0.765 : footY)
        switch state {
        case .off: break   // the closed ring is the marker
        case .on: drawInfinity(at: markerCentre, side: side * markerScale, stroke: stroke)
        case .error: drawBolt(at: markerCentre, side: side * markerScale)
        }
    }

    /// Two linked loops. A true lemniscate loses its crossing when small; two overlapping
    /// circles keep reading as "infinity" all the way down to 16 pt.
    private static func drawInfinity(at c: NSPoint, side: CGFloat, stroke: CGFloat) {
        // A proper lemniscate, drawn as two loops that cross in the middle. Two separate
        // circles were tried first and read as two dots at menu bar size — the crossing is
        // the whole thing that says "infinity".
        let w = side * 0.115   // half-width of one loop
        let h = side * 0.082   // half-height
        let path = NSBezierPath()
        path.lineWidth = stroke * 0.95
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        path.move(to: NSPoint(x: c.x, y: c.y))
        path.curve(to: NSPoint(x: c.x - w * 2, y: c.y),
                   controlPoint1: NSPoint(x: c.x - w * 0.7, y: c.y + h * 1.5),
                   controlPoint2: NSPoint(x: c.x - w * 2, y: c.y + h * 1.25))
        path.curve(to: NSPoint(x: c.x, y: c.y),
                   controlPoint1: NSPoint(x: c.x - w * 2, y: c.y - h * 1.25),
                   controlPoint2: NSPoint(x: c.x - w * 0.7, y: c.y - h * 1.5))
        path.curve(to: NSPoint(x: c.x + w * 2, y: c.y),
                   controlPoint1: NSPoint(x: c.x + w * 0.7, y: c.y + h * 1.5),
                   controlPoint2: NSPoint(x: c.x + w * 2, y: c.y + h * 1.25))
        path.curve(to: NSPoint(x: c.x, y: c.y),
                   controlPoint1: NSPoint(x: c.x + w * 2, y: c.y - h * 1.25),
                   controlPoint2: NSPoint(x: c.x + w * 0.7, y: c.y - h * 1.5))
        path.stroke()
    }


    /// A bolt. Solid and asymmetric, so the error state is a different silhouette rather
    /// than a variation on the calm one — legible even as a smudge.
    private static func drawBolt(at c: NSPoint, side: CGFloat) {
        let w = side * 0.145
        let h = side * 0.230
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x + w * 0.22, y: c.y + h / 2))
        path.line(to: NSPoint(x: c.x - w * 0.58, y: c.y + h * 0.01))
        path.line(to: NSPoint(x: c.x - w * 0.04, y: c.y + h * 0.01))
        path.line(to: NSPoint(x: c.x - w * 0.22, y: c.y - h / 2))
        path.line(to: NSPoint(x: c.x + w * 0.58, y: c.y - h * 0.01))
        path.line(to: NSPoint(x: c.x + w * 0.04, y: c.y - h * 0.01))
        path.close()
        path.fill()
    }
}
