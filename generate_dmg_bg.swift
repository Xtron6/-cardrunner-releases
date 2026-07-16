#!/usr/bin/env swift
// generate_dmg_bg.swift
// Generates the branded background image for the CardRunner DMG installer.
// Run: swift generate_dmg_bg.swift [output.png]
// Output: 660×400 PNG ready to drop into make_dmg.sh

import AppKit
import CoreGraphics

// ── Config ────────────────────────────────────────────────────────────────────
let W: CGFloat = 660
let H: CGFloat = 400
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_background.png"

// ── Canvas ────────────────────────────────────────────────────────────────────
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let gc = ctx.cgContext

// ── Background gradient (deep navy, matches CardRunner's dark UI) ─────────────
let topColor    = CGColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 1)   // #0A1024
let bottomColor = CGColor(red: 0.08, green: 0.10, blue: 0.20, alpha: 1)   // #141933
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [topColor, bottomColor] as CFArray,
    locations: [0.0, 1.0]
)!
gc.drawLinearGradient(gradient,
                      start: CGPoint(x: W / 2, y: H),
                      end:   CGPoint(x: W / 2, y: 0),
                      options: [])

// ── Subtle radial glow in the centre ─────────────────────────────────────────
let glowColor   = CGColor(red: 0.05, green: 0.69, blue: 0.91, alpha: 0.08)  // neon-blue tint
let clearColor  = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [glowColor, clearColor] as CFArray,
    locations: [0.0, 1.0]
)!
gc.drawRadialGradient(glow,
                      startCenter: CGPoint(x: W / 2, y: H / 2), startRadius: 0,
                      endCenter:   CGPoint(x: W / 2, y: H / 2), endRadius: 260,
                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// ── "CardRunner" wordmark at the top ─────────────────────────────────────────
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font:            NSFont.systemFont(ofSize: 18, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.65),
    .kern:            1.5 as NSNumber,
]
let title = NSAttributedString(string: "CARDRUNNER", attributes: titleAttrs)
let titleSize = title.size()
title.draw(at: NSPoint(x: (W - titleSize.width) / 2, y: H - 48))

// ── Thin horizontal rule below the title ─────────────────────────────────────
gc.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
gc.setLineWidth(1)
gc.move(to: CGPoint(x: 80, y: H - 58))
gc.addLine(to: CGPoint(x: W - 80, y: H - 58))
gc.strokePath()

// ── Subtle helper text at the very bottom ────────────────────────────────────
let hintAttrs: [NSAttributedString.Key: Any] = [
    .font:            NSFont.systemFont(ofSize: 11),
    .foregroundColor: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.28),
]
let hint = NSAttributedString(string: "Drag CardRunner to Applications to install", attributes: hintAttrs)
let hintSize = hint.size()
hint.draw(at: NSPoint(x: (W - hintSize.width) / 2, y: 18))

// ── Save ──────────────────────────────────────────────────────────────────────
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Error: could not encode PNG\n", stderr); exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("✅  Background saved → \(outputPath)  (\(Int(W))×\(Int(H)) px)")
} catch {
    fputs("Error writing \(outputPath): \(error)\n", stderr); exit(1)
}
