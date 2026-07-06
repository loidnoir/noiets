// Generates App/AppIcon.icon (Icon Composer document) from the flat logo.
//
// The logo is a full-bleed dark square with the "N" glyph baked in. macOS 26
// shows non-adopted icons shrunken on a system plate, so we split the logo
// into what Icon Composer wants: a solid background fill (sampled from the
// logo's corners) plus a transparent-background glyph layer keyed out of the
// artwork. Run via `make icon`; the output is committed because CI builds
// straight from the repo without running this script.
//
// Usage: swift Scripts/GenAppIcon.swift <logo.png> <output.icon>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024 // Icon Composer's expected layer size, in pixels

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: GenAppIcon.swift <logo.png> <output.icon>")
}
let logoURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = CGImageSourceCreateWithURL(logoURL as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("cannot read \(logoURL.path)") }

// Normalize to RGBA8 at 1024x1024.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
    bytesPerRow: canvas * 4, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fail("cannot create bitmap context") }
ctx.interpolationQuality = .high
ctx.draw(logo, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
guard let data = ctx.data else { fail("no bitmap data") }
let px = data.bindMemory(to: UInt8.self, capacity: canvas * canvas * 4)

// Background = average of the four 32x32 corner patches.
var sum = (r: 0, g: 0, b: 0), count = 0
for oy in [0, canvas - 32] {
    for ox in [0, canvas - 32] {
        for y in oy..<(oy + 32) {
            for x in ox..<(ox + 32) {
                let i = (y * canvas + x) * 4
                sum.r += Int(px[i]); sum.g += Int(px[i + 1]); sum.b += Int(px[i + 2])
                count += 1
            }
        }
    }
}
let bg = (r: sum.r / count, g: sum.g / count, b: sum.b / count)

// Key out the background: alpha ramps with chebyshev distance from bg color.
// The glyph is far brighter than the near-black backdrop, so a soft ramp
// keeps antialiased edges without halos (edge fringe is bg-tinted, and the
// layer sits on that same color as the icon fill).
for i in stride(from: 0, to: canvas * canvas * 4, by: 4) {
    let d = max(abs(Int(px[i]) - bg.r), abs(Int(px[i + 1]) - bg.g), abs(Int(px[i + 2]) - bg.b))
    let a = min(max(Double(d - 8) / 32.0, 0), 1)
    px[i + 3] = UInt8(a * 255)
    // premultipliedLast: scale color by the new alpha
    px[i] = UInt8(Double(px[i]) * a)
    px[i + 1] = UInt8(Double(px[i + 1]) * a)
    px[i + 2] = UInt8(Double(px[i + 2]) * a)
}

guard let glyph = ctx.makeImage() else { fail("cannot make glyph image") }

let assetsURL = outURL.appendingPathComponent("Assets")
try! FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)

let glyphURL = assetsURL.appendingPathComponent("N.png")
guard let dest = CGImageDestinationCreateWithURL(glyphURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("cannot write \(glyphURL.path)") }
CGImageDestinationAddImage(dest, glyph, nil)
guard CGImageDestinationFinalize(dest) else { fail("cannot finalize \(glyphURL.path)") }

func srgb(_ c: (r: Int, g: Int, b: Int)) -> String {
    String(format: "srgb:%.5f,%.5f,%.5f,1.00000", Double(c.r) / 255, Double(c.g) / 255, Double(c.b) / 255)
}

let json = """
{
  "fill" : {
    "solid" : "\(srgb(bg))"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : true,
          "hidden" : false,
          "image-name" : "N.png",
          "name" : "N",
          "position" : {
            "scale" : 1,
            "translation-in-points" : [ 0, 0 ]
          }
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : true,
        "value" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "circles" : [ "watchOS" ],
    "squares" : "shared"
  }
}
"""
try! Data(json.utf8).write(to: outURL.appendingPathComponent("icon.json"))
print("wrote \(outURL.path) (fill \(srgb(bg)))")
