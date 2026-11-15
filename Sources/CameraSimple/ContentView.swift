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
        // The smallest window has the picture's shape too.
        .frame(minWidth: model.minWindowSize.width, minHeight: model.minWindowSize.height)
        .ignoresSafeArea()
        .onAppear { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.start()
            model.loadLatestPhoto()   // photos may have been deleted or moved in Finder meanwhile
        }
    }

    private var camera: some View {
        ZStack {
            CameraPreview(session: model.session, zoom: model.zoom, aspect: model.currentAspect.ratio) { size in
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

            // Hides the black gap while the camera restarts in another format (see CameraModel.coverPreview).
            if let cover = model.cover {
                Color.black
                    .overlay(Image(decorative: cover, scale: 1).resizable().scaledToFill().opacity(0.88))
                    .clipped()
                    .opacity(model.covered ? 1 : 0)
                    .allowsHitTesting(false)
            }

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
                    if option == model.currentAspect {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
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
        // Five slots with equal gaps between them; both sides are mirror images, so the shutter
        // stays exactly centred. Every icon is drawn in the same box (ControlGlyph) so they read
        // as one size, and the thumbnail is a small tile of the same visual weight.
        HStack(spacing: 0) {
            Button(action: model.revealInFinder) {
                Group {
                    if let image = model.thumbnail {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.primary.opacity(0.35), lineWidth: 1))
                    } else {
                        ControlGlyph(name: "photo")
                    }
                }
                .frame(width: Self.slot, height: Self.slot)
                .contentShape(Rectangle())
            }
            .help("Show in Finder")

            Spacer(minLength: 8)

            Button(action: model.chooseFolder) {
                ControlGlyph(name: "folder").frame(width: Self.slot, height: Self.slot).contentShape(Rectangle())
            }
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

            ZoomControl(model: model)

            Spacer(minLength: 8)

            CameraPicker(model: model)
        }
        .buttonStyle(.plain)
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 330)
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
/// A control-bar button with a small panel that floats above it (the zoom slider, the camera
/// list). Hover or click opens it; it closes when the pointer leaves both the button and the
/// panel, on a click anywhere else, when the app goes to the background, or via `close`.
private struct BarPopover<Panel: View>: View {
    let symbol: String
    let help: String
    /// Where the panel is pinned relative to the button; `.bottomTrailing` keeps a wide panel
    /// inside the window when the button is at the bar's right end.
    var alignment: Alignment = .bottom
    var xOffset: CGFloat = 0
    /// True while the panel is being used in a way hover cannot see (e.g. a drag): never close then.
    var busy: Binding<Bool> = .constant(false)
    @ViewBuilder let panel: (_ close: @escaping () -> Void) -> Panel

    @State private var overButton = false
    @State private var overPanel = false
    @State private var visible = false
    @State private var hideToken = 0
    @State private var clickMonitor: Any?

    var body: some View {
        Button { visible ? hide() : show() } label: {
            ControlGlyph(name: symbol)
                .frame(width: ContentView.slot, height: ContentView.slot)
                .contentShape(Rectangle())
        }
        .help(help)
        .onHover { overButton = $0; update() }
        .overlay(alignment: alignment) {
            if visible {
                panel { hide() }
                    .onHover { overPanel = $0; update() }
                    .offset(x: xOffset, y: -54)
                    .transition(.opacity)
            }
        }
        .onChange(of: busy.wrappedValue) { _ in update() }   // a drag that ends off the panel closes it
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hide()
        }
        .onDisappear { removeMonitor() }
    }

    /// Open at once; close after a short delay so the pointer can cross the gap between the
    /// button and the panel. Never close in the middle of a drag.
    private func update() {
        hideToken += 1
        if overButton || overPanel {
            show()
        } else if visible && !busy.wrappedValue {
            let token = hideToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if token == hideToken { hide() }
            }
        }
    }

    private func show() {
        hideToken += 1
        withAnimation(.easeOut(duration: 0.12)) { visible = true }
        installMonitor()
    }

    private func hide() {
        hideToken += 1
        withAnimation(.easeOut(duration: 0.2)) { visible = false }
        // A view that disappears under the pointer never reports the pointer leaving it.
        overPanel = false
        busy.wrappedValue = false
        removeMonitor()
    }

    /// While the panel is open, a click anywhere else in the app closes it.
    private func installMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if !overButton && !overPanel { hide() }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
    }
}

private struct ZoomControl: View {
    @ObservedObject var model: CameraModel
    @State private var dragging = false

    var body: some View {
        BarPopover(symbol: "plus.magnifyingglass", help: "Zoom", busy: $dragging) { _ in
            VerticalSlider(
                value: Binding(get: { model.zoom }, set: { model.setZoom($0) }),
                range: CameraModel.zoomRange,
                dragging: $dragging
            )
            .frame(width: 28, height: 120)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background(.regularMaterial, in: Capsule(style: .continuous))
        }
    }
}

/// The camera list, floating above the camera button like the zoom slider.
private struct CameraPicker: View {
    @ObservedObject var model: CameraModel

    var body: some View {
        BarPopover(symbol: ContentView.cameraSymbol, help: "Choose Camera",
                   alignment: .bottomTrailing, xOffset: 6) { close in
            VStack(alignment: .leading, spacing: 2) {
                if model.devices.isEmpty {
                    Text("No Camera Found")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                ForEach(model.devices, id: \.uniqueID) { device in
                    CameraRow(name: device.localizedName, selected: device.uniqueID == model.selectedID) {
                        model.choose(device)
                        close()
                    }
                }
            }
            .padding(5)
            .font(.system(size: 13))
            .fixedSize()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct CameraRow: View {
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 180, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A minimal vertical slider: thin track, filled from the bottom, round thumb.
/// Drawn by hand because a rotated system Slider does not render here.
private struct VerticalSlider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    @Binding var dragging: Bool

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
                    if !dragging { dragging = true }
                    let f = 1 - min(max((drag.location.y - thumb / 2) / travel, 0), 1)
                    value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in dragging = false }
            )
        }
    }
}

extension ContentView {
    /// Tap target of every control in the bar.
    static let slot: CGFloat = 36

    /// A webcam ("which camera"); `web.camera` needs macOS 13.
    static var cameraSymbol: String {
        if #available(macOS 13.0, *) { return "web.camera" }
        return "video"
    }
}

/// An SF Symbol fitted into one common box, so wide symbols (folder) and tall ones (camera)
/// come out the same optical size instead of the same font size.
struct ControlGlyph: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 21)
    }
}
