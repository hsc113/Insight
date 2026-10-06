#!/usr/bin/env swift
// Renders Insight's app icon into an .iconset directory.
//
// The glyph is a direct statement of the product: one thick bar (the summary) sitting
// above two thinner bars (the translation) — the same layout as the result panel.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1
	? CommandLine.arguments[1]
	: FileManager.default.currentDirectoryPath + "/AppIcon.iconset"

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let variants: [(px: Int, name: String)] = [
	(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
	(32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
	(128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
	(256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
	(512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
	CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

func drawIcon(px: Int) -> CGImage? {
	let space = CGColorSpaceCreateDeviceRGB()
	guard let ctx = CGContext(
		data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
		space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
	) else { return nil }

	ctx.scaleBy(x: CGFloat(px), y: CGFloat(px))
	ctx.setAllowsAntialiasing(true)
	ctx.interpolationQuality = .high

	// Squircle body
	let body = CGPath(
		roundedRect: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.90),
		cornerWidth: 0.225, cornerHeight: 0.225, transform: nil)

	ctx.saveGState()
	ctx.addPath(body)
	ctx.clip()
	let gradient = CGGradient(
		colorsSpace: space,
		colors: [rgb(0.38, 0.27, 0.93), rgb(0.55, 0.36, 0.96), rgb(0.29, 0.20, 0.78)] as CFArray,
		locations: [0, 0.55, 1])!
	ctx.drawLinearGradient(
		gradient, start: CGPoint(x: 0.05, y: 0.95), end: CGPoint(x: 0.95, y: 0.05), options: [])

	// Top-left sheen
	let sheen = CGGradient(
		colorsSpace: space,
		colors: [rgb(1, 1, 1, 0.26), rgb(1, 1, 1, 0)] as CFArray,
		locations: [0, 1])!
	ctx.drawLinearGradient(
		sheen, start: CGPoint(x: 0.1, y: 0.95), end: CGPoint(x: 0.75, y: 0.35), options: [])
	ctx.restoreGState()

	// Glyph bars
	ctx.setFillColor(rgb(1, 1, 1, 0.97))
	func bar(x: Double, y: Double, w: Double, h: Double) {
		ctx.addPath(CGPath(
			roundedRect: CGRect(x: x, y: y, width: w, height: h),
			cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
		ctx.fillPath()
	}
	bar(x: 0.255, y: 0.640, w: 0.490, h: 0.098)   // summary
	bar(x: 0.255, y: 0.462, w: 0.420, h: 0.086)   // translation
	bar(x: 0.255, y: 0.284, w: 0.330, h: 0.086)   // translation

	return ctx.makeImage()
}

for v in variants {
	guard let image = drawIcon(px: v.px) else {
		FileHandle.standardError.write(Data("failed to render \(v.px)px\n".utf8))
		exit(1)
	}
	let url = URL(fileURLWithPath: outDir).appendingPathComponent(v.name)
	guard let dest = CGImageDestinationCreateWithURL(
		url as CFURL, UTType.png.identifier as CFString, 1, nil
	) else {
		FileHandle.standardError.write(Data("cannot write \(url.path)\n".utf8))
		exit(1)
	}
	CGImageDestinationAddImage(dest, image, nil)
	guard CGImageDestinationFinalize(dest) else {
		FileHandle.standardError.write(Data("cannot finalize \(url.path)\n".utf8))
		exit(1)
	}
}

print("wrote \(variants.count) images to \(outDir)")