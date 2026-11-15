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
    /// Width / height of the picture. The window is kept at this shape, so no bars show around it.
    var aspect: CGFloat = 0 {
        didSet { if aspect != oldValue { fitWindowSoon() } }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitWindowSoon()
    }

    /// A drag can stop at the window's minimum size, which SwiftUI makes a title bar taller than the picture.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        fitWindow()
    }

    /// Both callers run inside a SwiftUI/AppKit layout pass; resize the window after it.
    private func fitWindowSoon() {
        DispatchQueue.main.async { self.fitWindow() }
    }

    /// Locks window resizing to the picture's shape and, if the window has another shape
    /// (the ratio or the camera changed), resizes it around its centre to match.
    private func fitWindow() {
        guard let window, aspect > 0 else { return }
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        guard !window.styleMask.contains(.fullScreen) else { return }
        let old = window.contentRect(forFrameRect: window.frame)
        guard old.height > 0, abs(old.width / old.height - aspect) / aspect > 0.002 else { return }
        // Keep the area, then fit between the window's minimum size and the screen.
        var height = (old.width * old.height / aspect).squareRoot()
        let screen = window.screen?.visibleFrame
        if let screen {
            let room = window.contentRect(forFrameRect: screen).size
            height = min(height, room.height, room.width / aspect)
        }
        height = max(height, window.contentMinSize.height, window.contentMinSize.width / aspect).rounded()
        let width = (height * aspect).rounded()
        var frame = window.frameRect(forContentRect:
            NSRect(x: old.midX - width / 2, y: old.midY - height / 2, width: width, height: height))
        if let screen {
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
            frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

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
    let aspect: CGFloat
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
        view.aspect = aspect
    }
}
