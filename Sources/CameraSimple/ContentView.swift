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
            .aspectRatio(model.currentAspect.ratio, contentMode: .fit)
            .animation(.easeInOut(duration: 0.2), value: model.currentAspect.id)
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

            VStack(spacing: 8) {
                aspectMenu
                    .padding(.top, 34)
                Text(String(format: "%.1fx", Double(model.zoom)))
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .opacity(model.showZoomLabel ? 1 : 0)
                Spacer()
                controls
            }
        }
    }

    private var aspectMenu: some View {
        Menu {
            ForEach(model.aspectOptions) { option in
                Button {
                    model.chooseAspect(option)
                } label: {
                    let title = option.isDefault ? "\(option.id)  Default" : option.id
                    if option == model.currentAspect {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Text(model.currentAspect.id).font(.callout.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .help("Aspect Ratio")
    }

    private var controls: some View {
        // Two equal-width side groups keep the shutter exactly centred.
        HStack(spacing: 0) {
            HStack(spacing: 10) {
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

                Button(action: model.chooseFolder) {
                    Image(systemName: "folder").frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .help(model.saveFolder.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

            HStack(spacing: 10) {
                ZoomControl(model: model)

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
                .frame(width: 36, height: 36)
                .help("Camera")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .font(.system(size: 17))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 340)
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

/// A single zoom button. Hovering it reveals a vertical slider above it;
/// clicking it keeps the slider open until clicked again.
private struct ZoomControl: View {
    @ObservedObject var model: CameraModel
    @State private var overButton = false
    @State private var overSlider = false
    @State private var visible = false
    @State private var pinned = false
    @State private var hideToken = 0

    private let trackLength: CGFloat = 120

    var body: some View {
        Button { pinned.toggle(); update() } label: {
            Image(systemName: "plus.magnifyingglass")
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .onHover { overButton = $0; update() }
        .overlay(alignment: .bottom) {
            if visible {
                VerticalSlider(
                    value: Binding(get: { model.zoom }, set: { model.setZoom($0) }),
                    range: CameraModel.zoomRange
                )
                .frame(width: 28, height: trackLength)
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .onHover { overSlider = $0; update() }
                .offset(y: -54)
                .transition(.opacity)
            }
        }
    }

    /// Show at once; hide after a short delay so the pointer can cross the
    /// gap between the button and the slider.
    private func update() {
        hideToken += 1
        if overButton || overSlider || pinned {
            withAnimation(.easeOut(duration: 0.12)) { visible = true }
        } else {
            let token = hideToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if token == hideToken {
                    withAnimation(.easeOut(duration: 0.2)) { visible = false }
                }
            }
        }
    }
}

/// A minimal vertical slider: thin track, filled from the bottom, round thumb.
/// Drawn by hand because a rotated system Slider does not render here.
private struct VerticalSlider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    private let thumb: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.height - thumb, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbY = (1 - fraction) * travel          // top of the thumb
            ZStack(alignment: .top) {
                Capsule().fill(.primary.opacity(0.25))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                Capsule().fill(.primary)
                    .frame(width: 4, height: max(geo.size.height - thumbY - thumb / 2, 0))
                    .offset(y: thumbY + thumb / 2)
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: thumb, height: thumb)
                    .offset(y: thumbY)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let f = 1 - min(max((drag.location.y - thumb / 2) / travel, 0), 1)
                    value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                }
            )
        }
    }
}
