import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CameraModel
    @State private var pinchBase: CGFloat?

    var body: some View {
        ZStack {
            Color.black
            switch model.access {
            case .granted: camera
            case .denied: denied
            case .unknown: EmptyView()
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.start()
        }
    }

    private var camera: some View {
        ZStack {
            CameraPreview(session: model.session, zoom: model.zoom) { size in
                if size.width > 0, size.height > 0 { model.viewAspect = size.width / size.height }
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = model.zoom }
                        model.setZoom((pinchBase ?? 1) * value)
                    }
                    .onEnded { _ in pinchBase = nil }
            )

            if model.devices.isEmpty {
                Image(systemName: "video.slash")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
            }

            Color.white
                .opacity(model.flash ? 0.85 : 0)
                .allowsHitTesting(false)

            VStack {
                Text(String(format: "%.1fx", Double(model.zoom)))
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .opacity(model.showZoomLabel ? 1 : 0)
                    .padding(.top, 36)
                Spacer()
                controls
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button(action: model.revealInFinder) {
                Group {
                    if let image = model.thumbnail {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .help("Show in Finder")

            Button(action: model.chooseFolder) { Image(systemName: "folder") }
                .help(model.saveFolder.path)

            Spacer(minLength: 8)

            Button(action: model.capture) {
                ZStack {
                    Circle().strokeBorder(.primary, lineWidth: 2.5).frame(width: 46, height: 46)
                    Circle().fill(.primary).frame(width: 36, height: 36)
                }
                .contentShape(Circle())
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.selectedID == nil)
            .help("Take Photo")

            Spacer(minLength: 8)

            if model.devices.count > 1 {
                Menu {
                    ForEach(model.devices, id: \.uniqueID) { device in
                        Button {
                            model.choose(device)
                        } label: {
                            if device.uniqueID == model.selectedID {
                                Label(device.localizedName, systemImage: "checkmark")
                            } else {
                                Text(device.localizedName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Camera")
            }

            Button(action: model.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .disabled(model.zoom <= CameraModel.zoomRange.lowerBound)
                .help("Zoom Out")
            Button(action: model.zoomIn) { Image(systemName: "plus.magnifyingglass") }
                .disabled(model.zoom >= CameraModel.zoomRange.upperBound)
                .help("Zoom In")
        }
        .buttonStyle(.plain)
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var denied: some View {
        HStack(spacing: 10) {
            Text("Camera access is off.")
            Button("Open Settings", action: model.openCameraSettings)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
