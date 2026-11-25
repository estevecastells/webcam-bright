import CoreVideo
import Foundation
import ImageIO
import Vision

/// Forehead, eyes, nose and cheeks inside a Vision face box (origin bottom-left):
/// skips the hair at the edges and the mouth and beard below.
func skinRegion(_ face: CGRect) -> CGRect {
    CGRect(x: face.minX + face.width * 0.2, y: face.minY + face.height * 0.35,
           width: face.width * 0.6, height: face.height * 0.5)
}

func largestFace(_ results: [VNFaceObservation]?) -> CGRect? {
    results?.map(\.boundingBox).max { $0.width * $0.height < $1.width * $1.height }
}

/// Mean luma over a normalized region with Vision's bottom-left origin, on the full 0-255 scale
/// the target was calibrated on (video-range buffers store 16-235 and are rescaled).
func meanLuma(_ buffer: CVPixelBuffer, _ region: CGRect) -> Double? {
    guard let raw = rawMeanLuma(buffer, region) else { return nil }
    let videoRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    return videoRange ? min(255, max(0, (raw - 16) * 255 / 219)) : raw
}

private func rawMeanLuma(_ buffer: CVPixelBuffer, _ region: CGRect) -> Double? {
    guard CVPixelBufferIsPlanar(buffer) else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let x0 = max(0, Int(region.minX * CGFloat(w))), x1 = min(w, Int(region.maxX * CGFloat(w)))
    let y0 = max(0, Int((1 - region.maxY) * CGFloat(h))), y1 = min(h, Int((1 - region.minY) * CGFloat(h)))
    guard x1 > x0, y1 > y0 else { return nil }
    var sum = 0, count = 0
    for y in stride(from: y0, to: y1, by: 2) {
        let row = pixels + y * rowBytes
        for x in stride(from: x0, to: x1, by: 2) {
            sum += Int(row[x])
            count += 1
        }
    }
    return count > 0 ? Double(sum) / Double(count) : nil
}

/// Calibration helper for `WebcamBright --measure photo.jpg`: the skin crop as an ffmpeg filter,
/// so the skin brightness of a photo can be measured the same way.
public func skinCrop(ofImageAt path: String) -> Result<String, MeasureError> {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .failure(.unreadable(path)) }
    let request = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(cgImage: image).perform([request])
    guard let face = largestFace(request.results) else { return .failure(.noFace) }
    let r = skinRegion(face), w = Double(image.width), h = Double(image.height)
    return .success("crop=\(Int(r.width * w)):\(Int(r.height * h)):\(Int(r.minX * w)):\(Int((1 - r.maxY) * h))")
}

public enum MeasureError: Error, CustomStringConvertible {
    case unreadable(String), noFace
    public var description: String {
        switch self {
        case let .unreadable(path): "cannot read \(path)"
        case .noFace: "no face found"
        }
    }
}
