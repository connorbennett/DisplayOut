//
//  TestPattern.swift
//  DisplayOut
//

import CoreVideo

enum TestPattern: String, CaseIterable, Identifiable {
    case bars75
    case bars100
    case ramp
    case grid
    case white
    case black

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars75: return "Colour Bars 75%"
        case .bars100: return "Colour Bars 100%"
        case .ramp: return "Luma Ramp"
        case .grid: return "Grid"
        case .white: return "White"
        case .black: return "Black"
        }
    }

    /// Renders the pattern into a new IOSurface-backed 32BGRA buffer.
    func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        guard let pixelBuffer = created, CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Every pattern is built from at most two distinct rows, so render those and copy them down.
        let plain = Self.row(width: width) { x in color(atColumn: x, width: width) }
        var ruled: [UInt8]?
        // Square cells, 16 across on a 16:9 raster, with the lines centred on the frame.
        let cell = max(2, width / 16)
        if self == .grid {
            ruled = Self.row(width: width) { _ in (255, 255, 255) }
        }
        for y in 0..<height {
            let onLine = ruled != nil && Self.isGridLine(y, cell: cell, extent: height)
            (onLine ? ruled! : plain).withUnsafeBytes { source in
                _ = memcpy(base + y * rowBytes, source.baseAddress!, width * 4)
            }
        }
        return pixelBuffer
    }

    private func color(atColumn x: Int, width: Int) -> (UInt8, UInt8, UInt8) {
        switch self {
        case .bars75, .bars100:
            // White, yellow, cyan, green, magenta, red, blue (+ black at 100%).
            let level: UInt8 = self == .bars75 ? 191 : 255
            let bars: [(UInt8, UInt8, UInt8)] = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1), (0, 0, 0)]
            let count = self == .bars75 ? 7 : 8
            let bar = bars[min(count - 1, x * count / width)]
            return (bar.0 * level, bar.1 * level, bar.2 * level)
        case .ramp:
            let value = UInt8(x * 255 / max(1, width - 1))
            return (value, value, value)
        case .grid:
            let cell = max(2, width / 16)
            return Self.isGridLine(x, cell: cell, extent: width) ? (255, 255, 255) : (0, 0, 0)
        case .white:
            return (255, 255, 255)
        case .black:
            return (0, 0, 0)
        }
    }

    /// Two-pixel lines every `cell` pixels, positioned so one pair straddles the centre.
    private static func isGridLine(_ position: Int, cell: Int, extent: Int) -> Bool {
        let offset = (position - extent / 2 + 1) % cell
        return offset == 0 || offset == 1 || offset == 1 - cell
    }

    private static func row(width: Int, _ color: (Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * 4)
        for x in 0..<width {
            let (r, g, b) = color(x)
            bytes[x * 4] = b
            bytes[x * 4 + 1] = g
            bytes[x * 4 + 2] = r
        }
        return bytes
    }
}
