import AVFoundation
import SwiftUI

/// Hosts an AVCaptureVideoPreviewLayer. Digital zoom is done by enlarging the
/// layer around the view centre and clipping, so it works with every camera.
final class PreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var onResize: ((CGSize) -> Void)?
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { layoutPreview() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        previewLayer.videoGravity = .resizeAspectFill
        // Show the preview mirrored, like a mirror. Saved photos are not flipped.
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layoutPreview()
        onResize?(bounds.size)
    }

    private func layoutPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width * zoom, h = bounds.height * zoom
        // Set bounds and position rather than frame: the layer is flipped (mirror).
        previewLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let zoom: CGFloat
    let onResize: (CGSize) -> Void

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.onResize = onResize
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.onResize = onResize
        view.zoom = zoom
    }
}
