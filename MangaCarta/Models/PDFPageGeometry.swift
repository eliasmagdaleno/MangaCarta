import CoreGraphics

/// PDF crop-box dimensions after applying the page's intrinsic rotation.
enum PDFPageGeometry {
    static func displayedSize(cropBox: CGRect, rotation: Int) -> CGSize {
        let size = cropBox.standardized.size
        switch ((rotation % 360) + 360) % 360 {
        case 90, 270:
            return CGSize(width: size.height, height: size.width)
        default:
            return size
        }
    }

    static func drawingTransform(cropBox: CGRect, rotation: Int, in bounds: CGRect) -> CGAffineTransform {
        let crop = cropBox.standardized
        let normalizedRotation = ((rotation % 360) + 360) % 360
        let rotatedSize = displayedSize(cropBox: crop, rotation: normalizedRotation)
        let scale = min(bounds.width / rotatedSize.width, bounds.height / rotatedSize.height)
        let offsetX = bounds.minX + (bounds.width - rotatedSize.width * scale) / 2
        let offsetY = bounds.minY + (bounds.height - rotatedSize.height * scale) / 2

        switch normalizedRotation {
        case 90:
            return CGAffineTransform(a: 0, b: -scale, c: scale, d: 0,
                                     tx: offsetX - crop.minY * scale,
                                     ty: offsetY + (crop.maxX) * scale)
        case 180:
            return CGAffineTransform(a: -scale, b: 0, c: 0, d: -scale,
                                     tx: offsetX + crop.maxX * scale,
                                     ty: offsetY + crop.maxY * scale)
        case 270:
            return CGAffineTransform(a: 0, b: scale, c: -scale, d: 0,
                                     tx: offsetX + crop.maxY * scale,
                                     ty: offsetY - crop.minX * scale)
        default:
            return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                     tx: offsetX - crop.minX * scale,
                                     ty: offsetY - crop.minY * scale)
        }
    }
}
