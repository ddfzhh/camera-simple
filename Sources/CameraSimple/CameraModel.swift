import AVFoundation
import AppKit
import CoreImage
import ImageIO
import SwiftUI

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Access { case unknown, granted, denied }

    static let zoomRange: ClosedRange<CGFloat> = 1...5
    private static let folderKey = "saveFolderPath"
    private static let cameraKey = "cameraID"

    @Published private(set) var access: Access = .unknown
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var showZoomLabel = false
    @Published var flash = false
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var saveFolder: URL
    /// Pixel size of the selected camera's largest format, read each time a camera is activated.
    @Published private(set) var nativeSize: CGSize?
    /// Chosen aspect ratio id; nil means Full, the camera's own shape (the default).
    @Published private(set) var aspectID: String?
    /// Blurred still of the last frame, shown over the preview while `covered` (see `coverPreview`).
    @Published private(set) var cover: CGImage?
    @Published private(set) var covered = false

    let session = AVCaptureSession()
    /// Width / height of the on-screen preview, used to crop saved photos to what is visible.
    var viewAspect: CGFloat = 4.0 / 3.0

    /// `aspect` 0 means no aspect crop (Full).
    private struct Shot { let aspect: CGFloat; let zoom: CGFloat; let folder: URL }

    private let photoOutput = AVCapturePhotoOutput()
    /// Only keeps the latest frame (for the cover) and tells when a restarted stream delivers again.
    private let frameOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "io.github.ddfzhh.camera-simple.session")
    private let frameQueue = DispatchQueue(label: "io.github.ddfzhh.camera-simple.frames")
    private let frameLock = NSLock()
    private var lastFrame: CVPixelBuffer?   // guarded by frameLock
    private var awaited: (id: Int, frames: Int)?   // guarded by frameLock: the switch waiting for new frames
    private var stillWarm = false           // frame queue only
    private var switchID = 0                // the latest switch; written on the main thread, under frameLock
    private let ciContext = CIContext()
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var observation: NSKeyValueObservation?
    private var outputAdded = false
    private var pending: [Int64: Shot] = [:]
    private var lastPhotoURL: URL?
    private var zoomLabelToken = 0

    override init() {
        if let path = UserDefaults.standard.string(forKey: Self.folderKey) {
            saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
            saveFolder = pictures.appendingPathComponent("Camera Simple", isDirectory: true)
        }
        super.init()
        loadLatestPhoto()
    }

    // MARK: Permission

    func start() {
        guard access != .granted else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .granted
            setUpDiscovery()
        case .notDetermined:
            guard access == .unknown else { return }
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    self.access = ok ? .granted : .denied
                    if ok { self.setUpDiscovery() }
                }
            }
        default:
            access = .denied
        }
    }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Devices

    private func setUpDiscovery() {
        guard discovery == nil else { return }
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types.append(.externalUnknown)
        }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        discovery = session
        observation = session.observe(\.devices, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
        // Belt and braces: some drivers only post the notifications.
        let center = NotificationCenter.default
        for name in [Notification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected] {
            center.addObserver(self, selector: #selector(devicesChanged), name: name, object: nil)
        }
        refreshDevices()
    }

    @objc private func devicesChanged() {
        DispatchQueue.main.async { self.refreshDevices() }
    }

    private func refreshDevices() {
        guard let discovery else { return }
        let found = discovery.devices.filter { $0.isConnected }
        devices = found
        if let id = selectedID, found.contains(where: { $0.uniqueID == id }) { return }
        // Nothing selected yet, or the active camera went away: pick the remembered one, else a default.
        let remembered = UserDefaults.standard.string(forKey: Self.cameraKey)
        let systemDefault = AVCaptureDevice.default(for: .video)?.uniqueID
        let next = found.first { $0.uniqueID == remembered }
            ?? found.first { $0.uniqueID == systemDefault }
            ?? found.first
        activate(next)
    }

    /// User picked a camera explicitly.
    func choose(_ device: AVCaptureDevice) {
        UserDefaults.standard.set(device.uniqueID, forKey: Self.cameraKey)
        activate(device)
    }

    private func activate(_ device: AVCaptureDevice?) {
        selectedID = device?.uniqueID
        coverPreview(for: device)
        nativeSize = device.flatMap { Self.bestFormat(of: $0, ratio: nil) }.map(Self.size)
        configure(device)
    }

    /// A new format or camera restarts the stream, which leaves the preview black for a moment.
    /// Call this before such a change (and before the window changes shape with it): it covers the
    /// preview with a blurred still of the last frame. The new stream's frames uncover it.
    private func coverPreview(for device: AVCaptureDevice?) {
        if device == nil {
            covered = false
        } else if !covered, let still = makeStill(aspect: viewAspect, zoom: zoom) {
            cover = still
            covered = true
        }
    }

    /// The preview layer shows a restarted stream a few frames after the first frame is delivered
    /// here (measured: 2 to 3 frames), so uncover on the fourth.
    private static let framesBeforeUncover = 4

    /// Fades the cover out, unless a later switch has taken it over.
    private func uncover(_ id: Int) {
        guard id == switchID, covered else { return }
        withAnimation(.easeOut(duration: 0.25)) { covered = false }
    }

    /// The last frame as the preview shows it (same crop, mirrored), small and blurred.
    private func makeStill(aspect: CGFloat, zoom: CGFloat) -> CGImage? {
        frameLock.lock()
        let frame = lastFrame
        frameLock.unlock()
        guard let frame else { return nil }
        var image = CIImage(cvPixelBuffer: frame)
        image = image.cropped(to: Self.visibleRect(in: image.extent.size, aspect: aspect, zoom: zoom))
        let scale = min(1, 480 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: -scale, y: scale))
        let extent = image.extent
        // Clamp first, so the blur does not fade to transparent at the edges.
        return ciContext.createCGImage(image.clampedToExtent().applyingGaussianBlur(sigma: 12), from: extent)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        lastFrame = frame
        var id: Int?
        if let waiting = awaited {
            awaited = waiting.frames > 1 ? (waiting.id, waiting.frames - 1) : nil
            if awaited == nil { id = waiting.id }
        }
        frameLock.unlock()
        if let id { DispatchQueue.main.async { self.uncover(id) } }
        if !stillWarm {
            // The first still pays for Core Image's set-up (about 0.4 s); pay it now, not on the first switch.
            stillWarm = true
            queue.async { _ = self.makeStill(aspect: 0, zoom: 1) }
        }
    }

    /// Makes `device` the session's input, in the format that suits the chosen aspect ratio.
    private func configure(_ device: AVCaptureDevice?) {
        let ratio = aspectID == nil ? nil : currentAspect.ratio
        frameLock.lock()
        switchID += 1
        let id = switchID
        frameLock.unlock()
        queue.async {
            // Quick switches queue up behind a slow restart; only the latest is worth a restart.
            self.frameLock.lock()
            let latest = self.switchID
            self.frameLock.unlock()
            guard id == latest else { return }
            let session = self.session
            session.beginConfiguration()
            if (session.inputs.first as? AVCaptureDeviceInput)?.device != device {
                session.inputs.forEach { session.removeInput($0) }
                session.sessionPreset = .high
                if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
            }
            if !self.outputAdded, session.canAddOutput(self.photoOutput) {
                session.addOutput(self.photoOutput)
                self.outputAdded = true
                if session.canAddOutput(self.frameOutput) {
                    self.frameOutput.setSampleBufferDelegate(self, queue: self.frameQueue)
                    session.addOutput(self.frameOutput)
                }
            }
            // Keep the device locked until the session runs with the format;
            // otherwise macOS replaces it with the session preset's own choice.
            var locked = false
            if let device, let format = Self.bestFormat(of: device, ratio: ratio),
               (try? device.lockForConfiguration()) != nil {
                locked = true
                device.activeFormat = format
            } else if session.canSetSessionPreset(.photo) {
                session.sessionPreset = .photo
            }
            session.commitConfiguration()
            if device != nil {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
            if locked { device?.unlockForConfiguration() }
            // From here on a frame is a frame of the new stream. No frames without a camera:
            // drop the old one, so a camera plugged in later does not start behind a stale cover.
            self.frameLock.lock()
            self.awaited = device == nil ? nil : (id, Self.framesBeforeUncover)
            if device == nil { self.lastFrame = nil }
            self.frameLock.unlock()
            // If no frame comes (a camera that fails to start), do not stay covered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.uncover(id) }
        }
    }

    private static func size(_ format: AVCaptureDevice.Format) -> CGSize {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return CGSize(width: Int(d.width), height: Int(d.height))
    }

    /// The format that gives the most pixels once cropped to `ratio`; nil means uncropped,
    /// so the camera's largest landscape picture. Formats too slow for a live preview are left out if possible.
    static func bestFormat(of device: AVCaptureDevice, ratio: CGFloat?) -> AVCaptureDevice.Format? {
        func score(_ format: AVCaptureDevice.Format) -> (CGFloat, CGFloat) {
            let full = size(format)
            let used = ratio.map { visibleRect(in: full, aspect: $0, zoom: 1).size } ?? full
            return (used.width * used.height, full.width)   // equal area: prefer landscape
        }
        func fps(_ format: AVCaptureDevice.Format) -> Double {
            format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        let video = device.formats.filter {
            CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video && size($0).height > 0
        }
        let smooth = video.filter { fps($0) >= 24 }
        var pool = smooth.isEmpty ? video : smooth
        if ratio == nil {
            // Full: the largest landscape picture, not a square or portrait sensor crop.
            let landscape = pool.filter { size($0).width > size($0).height }
            if !landscape.isEmpty { pool = landscape }
        }
        return pool.max { score($0) < score($1) }
    }

    // MARK: Aspect ratio

    struct AspectOption: Identifiable, Equatable {
        let id: String        // "Full", "16:9", "1:1" or "9:16"
        let ratio: CGFloat    // width / height
        let isFull: Bool      // the camera's own shape, not a fixed ratio
        let title: String     // menu title; for Full it also names the shape, e.g. "Full (4:3)"
    }

    private static let commonRatios: [(String, CGFloat)] = [("16:9", 16.0 / 9), ("1:1", 1), ("9:16", 9.0 / 16)]
    private static let knownRatios: [(String, CGFloat)] =
        commonRatios + [("4:3", 4.0 / 3), ("3:2", 3.0 / 2), ("3:4", 3.0 / 4), ("2:3", 2.0 / 3)]

    private static func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) / b < 0.02 }

    /// Full (the selected camera's own shape) first, then the fixed ratios.
    var aspectOptions: [AspectOption] {
        let size = nativeSize ?? CGSize(width: 16, height: 9)
        let native = size.width / max(size.height, 1)
        var shape = ""
        if nativeSize != nil {
            shape = Self.knownRatios.first { Self.same(native, $0.1) }?.0 ?? "\(Int(size.width))×\(Int(size.height))"
            shape = " (\(shape))"
        }
        return [AspectOption(id: "Full", ratio: native, isFull: true, title: "Full" + shape)]
            + Self.commonRatios.map { AspectOption(id: $0.0, ratio: $0.1, isFull: false, title: $0.0) }
    }

    var currentAspect: AspectOption {
        let options = aspectOptions
        return options.first { $0.id == aspectID } ?? options[0]
    }

    /// The smallest window of the current shape that is at least 380 wide and 360 high.
    var minWindowSize: CGSize {
        let ratio = currentAspect.ratio
        let height = max(360, 380 / ratio).rounded()
        return CGSize(width: (height * ratio).rounded(), height: height)
    }

    func chooseAspect(_ option: AspectOption) {
        let id = option.isFull ? nil : option.id
        guard id != aspectID else { return }
        let device = devices.first { $0.uniqueID == selectedID }
        coverPreview(for: device)
        aspectID = id
        configure(device)
    }

    // MARK: Zoom

    func setZoom(_ value: CGFloat) {
        let clamped = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard clamped != zoom else { return }
        zoom = clamped
        showZoomLabel = true
        zoomLabelToken += 1
        let token = zoomLabelToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if token == self.zoomLabelToken {
                withAnimation(.easeOut(duration: 0.3)) { self.showZoomLabel = false }
            }
        }
    }

    func zoomIn() { setZoom((zoom * 2).rounded(.down) / 2 + 0.5) }
    func zoomOut() { setZoom((zoom * 2).rounded(.up) / 2 - 0.5) }

    // MARK: Save folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.fileExists(atPath: saveFolder.path)
            ? saveFolder : saveFolder.deletingLastPathComponent()
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        loadLatestPhoto()
    }

    /// Shows the newest Camera Simple photo in the save folder as the thumbnail, so it survives a
    /// relaunch, follows a folder change, and drops a photo that was deleted in Finder.
    func loadLatestPhoto() {
        let folder = saveFolder
        DispatchQueue.global(qos: .utility).async {
            let latest = Self.latestPhoto(in: folder)
            let thumb = latest.flatMap { Self.thumbnail(for: $0) }
            DispatchQueue.main.async {
                guard self.saveFolder == folder else { return }   // the folder changed meanwhile
                // A photo taken while this ran is newer than anything the scan saw: keep it.
                if let current = self.lastPhotoURL, current.deletingLastPathComponent() == folder,
                   FileManager.default.fileExists(atPath: current.path),
                   Self.created(current) >= latest.map(Self.created) ?? .distantPast { return }
                guard latest != self.lastPhotoURL || latest == nil else { return }
                self.lastPhotoURL = latest
                self.thumbnail = thumb
            }
        }
    }

    /// The most recently created photo this app saved in `folder` ("Camera Simple <date>.jpg").
    private static func latestPhoto(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("Camera Simple ") && $0.pathExtension.lowercased() == "jpg" }
            .max { created($0) < created($1) }
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Shows the photo folder in Finder: reuses a Finder window that already shows it, and brings
    /// only that one window forward. (`activateFileViewerSelecting` opened a new window every time
    /// and pulled every Finder window in front of other apps.)
    func revealInFinder() {
        let folder: URL
        if let url = lastPhotoURL, FileManager.default.fileExists(atPath: url.path) {
            folder = url.deletingLastPathComponent()
        } else {
            try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            folder = saveFolder
        }
        let finderID = "com.apple.finder"
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderID) else {
            NSWorkspace.shared.open(folder)
            return
        }
        // Let Finder open (or re-use) the folder's window without activating itself, which would
        // bring all of its windows forward; then activate Finder with only that front window.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open([folder], withApplicationAt: finderURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first
                else { return }
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: finder)
                    finder.activate()
                } else {
                    finder.activate(options: [])
                }
            }
        }
    }

    // MARK: Capture

    func capture() {
        guard access == .granted, selectedID != nil else { return }
        let shot = Shot(aspect: aspectID == nil ? 0 : viewAspect, zoom: zoom, folder: saveFolder)
        queue.async {
            guard self.session.isRunning, self.photoOutput.connection(with: .video) != nil else { return }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            self.pending[settings.uniqueID] = shot
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.easeOut(duration: 0.3)) { self.flash = false }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let data = error == nil ? photo.fileDataRepresentation() : nil
        queue.async {
            guard let shot = self.pending.removeValue(forKey: id) else { return }
            guard let data, let url = Self.save(data, shot: shot) else {
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            let thumb = Self.thumbnail(for: url)
            DispatchQueue.main.async {
                self.lastPhotoURL = url
                self.thumbnail = thumb
            }
        }
    }

    /// The part of an image of `size` that is visible in a view of `aspect` (aspect fill) at `zoom`.
    static func visibleRect(in size: CGSize, aspect: CGFloat, zoom: CGFloat) -> CGRect {
        var w = size.width, h = size.height
        if aspect > 0 {
            if w / h > aspect { w = h * aspect } else { h = w / aspect }
        }
        let z = max(zoom, 1)
        w /= z
        h /= z
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h).integral
    }

    private static func save(_ data: Data, shot: Shot) -> URL? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Decode upright (applies any EXIF orientation) at full size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph),
        ]
        guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rect = visibleRect(in: CGSize(width: full.width, height: full.height), aspect: shot.aspect, zoom: shot.zoom)
        guard let cropped = full.cropping(to: rect) else { return nil }

        do {
            try FileManager.default.createDirectory(at: shot.folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Camera Simple " + formatter.string(from: Date())
        var url = shot.folder.appendingPathComponent(base + ".jpg")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = shot.folder.appendingPathComponent("\(base) \(n).jpg")
            n += 1
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cropped, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    private static func thumbnail(for url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
