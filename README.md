# Pinhole

A small native macOS camera app: live preview, one shutter button, photos saved as JPEG.

## Features

- Live camera preview that fills the window.
- Take a photo with the round button or the Space key.
- Photos are saved to `~/Pictures/Pinhole` by default. The folder button picks another folder, and the choice is remembered.
- Click the thumbnail to show the last photo (or the save folder) in Finder.
- Switch between cameras: built-in, USB, and Continuity Camera. The list updates when a camera is plugged in or unplugged. The camera button only appears when there is more than one camera.
- Digital zoom from 1x to 5x: trackpad pinch, the zoom buttons, or Cmd-plus / Cmd-minus / Cmd-0. The saved photo is cropped to what the window shows.

## Install

1. Download `Pinhole-1.0.0.dmg` from the [latest release](https://github.com/ddfzhh/pinhole/releases/latest).
2. Open the DMG and drag Pinhole to Applications.
3. Open Pinhole and allow camera access when asked.

### First launch

Pinhole is not notarized by Apple (it is signed ad hoc, without a Developer ID). macOS will block it the first time you open it. To allow it:

1. Try to open Pinhole once and dismiss the warning.
2. Open System Settings > Privacy & Security, scroll down, and click "Open Anyway" next to the Pinhole message.
3. Confirm with your password or Touch ID.

You only need to do this once.

## Requirements

- macOS 12.0 or later
- Apple Silicon or Intel Mac (universal binary)

## Build from source

Requires Xcode (or the Xcode command line tools) with Swift 5.9 or later.

```sh
git clone https://github.com/ddfzhh/pinhole.git
cd pinhole
./scripts/build.sh      # builds dist/Pinhole.app (arm64 + x86_64, ad-hoc signed)
./scripts/make-dmg.sh   # builds dist/Pinhole-1.0.0.dmg
```

The app icon is drawn by `scripts/make-icon.swift` during the build.

## License

MIT. See [LICENSE](LICENSE).
