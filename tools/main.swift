import AppKit

// Renders the icon at the sizes that actually matter, plus a contact sheet so the small
// sizes can be judged next to each other instead of one at a time.

func png(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

let states: [(AppIcon.State, String)] = [(.off, "uit"), (.on, "aan"), (.error, "fout")]
let menuSizes: [CGFloat] = [16, 18, 32, 36]

for (state, name) in states {
    for size in menuSizes {
        for scale in [1, 2] {
            png(AppIcon.flat(state, pixels: size * CGFloat(scale)),
                to: "icons/menubar-\(name)-\(Int(size))@\(scale)x.png")
        }
    }
    for px in [512, 1024] as [CGFloat] {
        png(AppIcon.flat(state, pixels: px), to: "icons/app-\(name)-\(Int(px)).png")
        png(AppIcon.flat(state, pixels: px, onDark: true), to: "icons/app-\(name)-\(Int(px))-donker.png")
    }
}

// Contact sheet. Each state on both backgrounds, drawn 1:1 at the real menu bar sizes and
// again at 4x, so the true size and the shape can be judged side by side.
let colW: CGFloat = 190
let rowH: CGFloat = 110
let leftGutter: CGFloat = 120
let width = leftGutter + colW * CGFloat(menuSizes.count)
let height = rowH * 6 + 46

let sheet = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    let head = NSFont.boldSystemFont(ofSize: 12)
    let small = NSFont.systemFont(ofSize: 10)

    for (i, size) in menuSizes.enumerated() {
        ("\(Int(size)) pt" as NSString).draw(
            at: NSPoint(x: leftGutter + CGFloat(i) * colW + 16, y: height - 26),
            withAttributes: [.font: head, .foregroundColor: NSColor.black])
    }

    var row = 0
    for (state, name) in states {
        for dark in [false, true] {
            let y = height - 46 - rowH * CGFloat(row + 1)

            if dark {
                NSColor(white: 0.11, alpha: 1).setFill()
                NSRect(x: leftGutter, y: y, width: colW * CGFloat(menuSizes.count), height: rowH).fill()
            }
            ("\(name) · \(dark ? "donker" : "licht")" as NSString).draw(
                at: NSPoint(x: 14, y: y + rowH / 2 - 6),
                withAttributes: [.font: head, .foregroundColor: NSColor.black])

            for (i, size) in menuSizes.enumerated() {
                let x = leftGutter + CGFloat(i) * colW + 16
                // Tint inside a transparent layer. Tinting straight onto the sheet fills
                // the whole rect, because sourceAtop keys off the destination's alpha and
                // the background is already opaque.
                // Render at the NATIVE size. Rendering at 4x and scaling down shows the
                // detailed artwork shrunk — which is exactly the mistake the size-aware
                // drawing exists to avoid, and it made the small sizes look far worse than
                // they are. The blow-up is this same native glyph enlarged, so it shows the
                // real pixels rather than a different drawing.
                let glyph = AppIcon.menuBar(state, pointSize: size)
                let tint = dark ? NSColor.white : NSColor.black
                func stamp(_ r: NSRect) {
                    let layer = NSImage(size: r.size, flipped: false) { inner in
                        glyph.draw(in: inner, from: .zero, operation: .sourceOver, fraction: 1)
                        tint.set()
                        inner.fill(using: .sourceAtop)
                        return true
                    }
                    layer.draw(in: r)
                }
                // 1:1 — the size it will really be in the menu bar.
                stamp(NSRect(x: x, y: y + rowH - 20 - size, width: size, height: size))
                // 4x — what the shape is actually doing.
                stamp(NSRect(x: x + size + 16, y: y + 16, width: size * 2.4, height: size * 2.4))

                ("1:1" as NSString).draw(
                    at: NSPoint(x: x, y: y + 6),
                    withAttributes: [.font: small,
                                     .foregroundColor: dark ? NSColor.white : NSColor.gray])
            }
            row += 1
        }
    }
    return true
}
png(sheet, to: "icons/contactblad.png")
print("geschreven naar icons/")
