import CoreGraphics

enum ScreenshotScale {
    static func factor(width: CGFloat, height: CGFloat, maxSide: CGFloat = 1280) -> CGFloat {
        let longestSide = max(width, height)
        guard longestSide > maxSide, longestSide > 0 else { return 1 }
        return maxSide / longestSide
    }

    static func scaledSize(width: CGFloat, height: CGFloat, maxSide: CGFloat = 1280) -> CGSize {
        let factor = factor(width: width, height: height, maxSide: maxSide)
        return CGSize(width: width * factor, height: height * factor)
    }

    static func originalPoint(x: CGFloat, y: CGFloat, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return CGPoint(x: x, y: y) }
        return CGPoint(x: x / scale, y: y / scale)
    }
}
