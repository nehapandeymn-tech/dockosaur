// Draws the 1024 px app icon from the dino sprite: swift Tools/icon.swift <out.png>
import AppKit

let out = CommandLine.arguments[1]
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: "Resources/Art/dino_vita.png") as CFURL, nil)!
let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let dino = sheet.cropping(to: CGRect(x: 4 * 24, y: 0, width: 24, height: 24))!   // a run frame
let spikeSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: "Resources/Art/spikes.png") as CFURL, nil)!
let spike = CGImageSourceCreateImageAtIndex(spikeSrc, 0, nil)!

let N = 1024
let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(shape); ctx.clip()
let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                     colors: [CGColor(red: 0.13, green: 0.15, blue: 0.24, alpha: 1), CGColor(red: 0.29, green: 0.23, blue: 0.42, alpha: 1)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
// Dock-like glass shelf
ctx.setFillColor(CGColor(gray: 1, alpha: 0.16))
ctx.addPath(CGPath(roundedRect: CGRect(x: 150, y: 150, width: 724, height: 150), cornerWidth: 48, cornerHeight: 48, transform: nil))
ctx.fillPath()
ctx.setFillColor(CGColor(gray: 1, alpha: 0.55))
ctx.fill(CGRect(x: 100, y: 316, width: 824, height: 6))
ctx.interpolationQuality = .none
let px: CGFloat = 22
ctx.draw(dino, in: CGRect(x: 230, y: 322 - 3 * px, width: 24 * px, height: 24 * px))
ctx.draw(spike, in: CGRect(x: 700, y: 322, width: 16 * 10, height: 16 * 10))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
