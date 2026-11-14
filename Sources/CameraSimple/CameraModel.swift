import AVFoundation
import AppKit
import ImageIO
import SwiftUI

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
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
    /// Pixel size the active camera delivers, detected each time a camera is activated.
    @Published private(set) var nativeSize: CGSize?
    /// Chosen aspect ratio id; nil means the camera's own (default) ratio.
    @Published private(set) var aspectID: String?

    let session = AVCaptureSession()
    /// Width / height of the on-screen preview, used to crop saved photos to what is visible.
    var viewAspect: CGFloat = 4.0 / 3.0

    private struct Shot { let aspect: CGFloat; let zoom: CGFloat; let folder: URL }

    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "io.github.ddfzhh.camera-simple.session")
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
        queue.async {
            let session = self.session
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.sessionPreset = .high
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            }
            if !self.outputAdded, session.canAddOutput(self.photoOutput) {
                session.addOutput(self.photoOutput)
                self.outputAdded = true
            }
            session.commitConfiguration()
            // Detect what this camera actually delivers with the chosen preset.
            var detected: CGSize?
            if let device {
                let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                if d.width > 0, d.height > 0 { detected = CGSize(width: Int(d.width), height: Int(d.height)) }
            }
            DispatchQueue.main.async { self.nativeSize = detected }
            if device != nil {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: Aspect ratio

    struct AspectOption: Identifiable, Equatable {
        let id: String        // "16:9", "1:1", "9:16", or the camera's own ratio
        let ratio: CGFloat    // width / height
        let isDefault: Bool   // matches what the camera delivers
    }

    private static let commonRatios: [(String, CGFloat)] = [("1:1", 1), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]
    private static let knownRatios: [(String, CGFloat)] =
        commonRatios + [("4:3", 4.0 / 3), ("3:2", 3.0 / 2), ("3:4", 3.0 / 4), ("2:3", 2.0 / 3)]

    private static func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) / b < 0.02 }

    /// The camera's own ratio first (marked default), then the other common ratios.
    var aspectOptions: [AspectOption] {
        let size = nativeSize ?? CGSize(width: 16, height: 9)
        let native = size.width / max(size.height, 1)
        let name = Self.knownRatios.first { Self.same(native, $0.1) }?.0
            ?? "\(Int(size.width))×\(Int(size.height))"
        var options = [AspectOption(id: name, ratio: native, isDefault: true)]
        for (id, ratio) in Self.commonRatios where id != name {
            options.append(AspectOption(id: id, ratio: ratio, isDefault: false))
        }
        return options
    }

    var currentAspect: AspectOption {
        let options = aspectOptions
        return options.first { $0.id == aspectID } ?? options[0]
    }

    func chooseAspect(_ option: AspectOption) {
        aspectID = option.isDefault ? nil : option.id
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
    }

    func revealInFinder() {
        if let url = lastPhotoURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(saveFolder)
        }
    }

    // MARK: Capture

    func capture() {
        guard access == .granted, selectedID != nil else { return }
        let shot = Shot(aspect: viewAspect, zoom: zoom, folder: saveFolder)
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
