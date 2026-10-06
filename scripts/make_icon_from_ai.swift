#!/usr/bin/env swift
// Turn an AI-generated square image into a real macOS icon.
//
// Image models render "transparent margin" as a baked-in checkerboard, which looks like rubbish
// the moment it becomes an .icns. So this script does the iconography properly:
//   1. finds the artwork's bounding box by looking for chromatic pixels (the checkerboard is
//      achromatic, the artwork never is),
//   2. re-cuts the silhouette with an Apple-style superellipse,
//   3. places it on Apple's icon grid — 824x824 centred in 1024, which is the real padding,
//   4. emits every size in the iconset.
//
// Usage: swift scripts/make_icon_from_ai.swift <input.png> <out.iconset>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
	FileHandle.standardError.write(Data("usage: make_icon_from_ai <in.png> <out.iconset>\n".utf8))
	exit(1)
}
let inputURL = URL(fileURLWithPath: args[1])
let outDir = args[2]

// MARK: - Load and locate the artwork

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
	let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
	FileHandle.standardError.write(Data("cannot read \(inputURL.path)\n".utf8))
	exit(1)
}

let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let bitmap = CGContext(
	data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
	space: CGColorSpaceCreateDeviceRGB(),
	bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

var minX = width, maxX = 0, minY = height, maxY = 0
for y in 0..<height {
	for x in 0..<width {
		let i = (y * width + x) * 4
		let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
		// Chromatic and not near-white: a gradient fill qualifies, a grey checkerboard never does.
		let chroma = max(r, g, b) - min(r, g, b)
		guard chroma > 46, max(r, g, b) < 250 else { continue }
		minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
		minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
	}
}
guard maxX > minX, maxY > minY else {
	FileHandle.standardError.write(Data("no chromatic artwork found\n".utf8))
	exit(1)
}
let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
print("artwork bbox \(crop) of \(width)x\(height)")

// MARK: - Composite onto Apple's grid

// Apple's icon grid: a 1024px canvas with the shape at 824px, centred. This is where the ~10%
// of visual padding every Mac icon has comes from.
let canvas = 1024
let shapeSide = 824
let shapeRect = CGRect(
	x: CGFloat(canvas - shapeSide) / 2, y: CGFloat(canvas - shapeSide) / 2,
	width: CGFloat(shapeSide), height: CGFloat(shapeSide))

let output = CGContext(
	data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
	space: CGColorSpaceCreateDeviceRGB(),
	bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

/// Apple's continuous-curvature squircle, approximated with the superellipse |x|^n + |y|^n = 1.
/// `n = 5` is the value that visually matches the macOS silhouette.
let squircle = CGMutablePath()
let exponent = 5.0
let steps = 512
for i in 0..<steps {
	let theta = 2 * Double.pi * Double(i) / Double(steps)
	let cosT = cos(theta), sinT = sin(theta)
	let x = copysign(pow(abs(cosT), 2 / exponent), cosT)
	let y = copysign(pow(abs(sinT), 2 / exponent), sinT)
	let point = CGPoint(
		x: shapeRect.midX + x * shapeRect.width / 2,
		y: shapeRect.midY + y * shapeRect.height / 2)
	if i == 0 { squircle.move(to: point) } else { squircle.addLine(to: point) }
}
squircle.closeSubpath()

output.saveGState()
output.addPath(squircle)
output.clip()
output.interpolationQuality = .high
// Fill the shape first so any checkerboard that survived the bbox crop is covered.
output.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.24, 0.15, 0.62, 1])!)
output.fill(shapeRect)
// Crop first: CGContext can only scale a whole CGImage, not a sub-rect of one.
let artwork = image.cropping(to: crop) ?? image
output.draw(artwork, in: shapeRect)
output.restoreGState()

guard let master = output.makeImage() else { exit(1) }

// MARK: - Emit the iconset

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let variants: [(px: Int, name: String)] = [
	(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
	(32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
	(128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
	(256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
	(512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for variant in variants {
	// One context per size: a single 1024 canvas would leave the smaller rasters sitting in a
	// corner of an oversized bitmap.
	guard let context = CGContext(
		data: nil, width: variant.px, height: variant.px, bitsPerComponent: 8, bytesPerRow: 0,
		space: CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
	context.interpolationQuality = .high
	context.draw(
		master,
		in: CGRect(x: 0, y: 0, width: CGFloat(variant.px), height: CGFloat(variant.px)))
	guard let scaled = context.makeImage() else { continue }

	let url = URL(fileURLWithPath: outDir).appendingPathComponent(variant.name)
	guard let dest = CGImageDestinationCreateWithURL(
		url as CFURL, UTType.png.identifier as CFString, 1, nil)
	else { continue }
	CGImageDestinationAddImage(dest, scaled, nil)
	_ = CGImageDestinationFinalize(dest)
}

print("wrote \(variants.count) images to \(outDir)")