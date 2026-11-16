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
}
