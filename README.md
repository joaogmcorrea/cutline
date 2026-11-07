# Cutline

Cutting for Silhouette machines on the Mac — a lean, free, native app for people who just want to draw or import something and send it to cut.

*English, Portuguese and Spanish UI.*

**[⬇ Download Cutline for Mac (.dmg)](https://github.com/joaogmcorrea/cutline/releases/latest/download/Cutline.dmg)** — macOS 26 (Tahoe) or newer. See [Install](#install) for the first launch.

## What it does

- Draws (Bézier pen, rectangle, ellipse, star, text) and imports PDF, AI, SVG and EPS, images (it traces the outline) and Silhouette Studio `.studio3` files.
- Imports Photoshop files layer by layer: each layer comes in as its own image, in its place, and can get its own cut outline.
- Pastes what you copy in Illustrator. The stroke sets the cut, like when you import a file.
- Sends from Illustrator in one click with the **Send to Cutline** script (see [below](#send-to-cutline-from-illustrator)).
- **Cut by line color:** each stroke color gets its own material, force, speed, blade and passes.
- **Experimental:** tool holder 2 with a pen, foil, the emboss tool or the Heat Pen for each color, and a print bleed for Print & Cut. They haven't been tried on a machine yet: if something goes wrong, **Report a Problem…** next to each one fills in the details.
- Sends to the machine over USB or Bluetooth, and remembers the settings in the file and in the app.
- macOS 26 interface (Liquid Glass), with Illustrator-style panels: Color (CMYK), Stroke, Pathfinder, Layers, Character and Paragraph.
- Quick Look in the Finder: `.cutline` and `.studio3` icons show their page, and Space opens the whole file.

## Machines

| Status | Models |
|---|---|
| Tested | Portrait 4 (Bluetooth) |
| Recognized, not tested yet | Portrait 4 over USB; Portrait 2 and 3, Cameo 3, 4 (and Plus/Pro), 5 (and Plus/Alpha) and Cameo Pro MK II, over Bluetooth or USB; Portrait, Cameo and Cameo 2 (USB only) |
| Not yet | CURIO 2 |

When a machine is plugged in over USB, Cutline uses the cable and skips Bluetooth.

Have one of these machines and want to help test? Open an *issue* — in the app, **Help › Report a Bug…** fills in the version, the Mac and the machine for you (and sends it by email if you don't have a GitHub account).

## Requirements

macOS 26 (Tahoe) or newer.

## Install

1. Download [Cutline.dmg](https://github.com/joaogmcorrea/cutline/releases/latest/download/Cutline.dmg) — always the latest version. (On a [release page](https://github.com/joaogmcorrea/cutline/releases/latest), the `.dmg` is under **Assets**; the "Source code" files are only the code.)
2. Open the DMG and drag Cutline to the Applications folder.
3. The first time you open it, macOS says it can't verify the app: Cutline isn't notarized by Apple (that requires a paid developer account). Go to System Settings › Privacy & Security and click **Open Anyway**. You only need to do this once.

From then on, Cutline updates itself: when a new version comes out, it lets you know and installs it (Cutline › Check for Updates… checks right away). Every update is verified with an EdDSA signature before it's installed.

## Send to Cutline from Illustrator

Cutline comes with an Illustrator script that sends your artwork in one click.

1. In Cutline, choose **Help › Install Illustrator Script…**. It puts the script in the Scripts folder of each Illustrator on your Mac. macOS asks for your password, because that folder belongs to the system. Then quit and reopen Illustrator.
2. In Illustrator, choose **File › Scripts › Send to Cutline**. With something selected, it sends the selection. With nothing selected, it sends the active artboard.

Cutline opens it as a new document, with the artboard's size and the artwork in its place. As with Import and Paste, a stroke becomes a cut line and a fill without a stroke only prints. Your Illustrator document doesn't change: the script copies the artwork into a new document, turns the text into outlines there and saves it as a PDF for Cutline.

To install it by hand, copy [`Send to Cutline.jsx`](Cutline/Illustrator/Send%20to%20Cutline.jsx) to `/Applications/Adobe Illustrator <year>/Presets/<language>/Scripts/` and restart Illustrator. You can also run it from anywhere with **File › Scripts › Other Script…**. If Preview opens instead of Cutline, install the latest Cutline: older versions don't know the script's file.

## Build

```bash
xcodebuild -project Cutline.xcodeproj -scheme Cutline build
```

The machine driver is the local Swift package in `CutlineKit/`, which the Xcode project builds along with the app. Updates come from the GitHub releases (Sparkle), signed with a key that stays outside the repository.

## Credits

The machine driver (`CutlineKit`) is a Swift port of the `silhouette/` module of [inkscape-silhouette](https://github.com/fablabnbg/inkscape-silhouette) (commit `f166edc`, October 2026) — © 2013–2017 Jürgen Weigert, Alexander Wenger, Johann Gail and contributors — which is itself based on [Robocut](https://github.com/nosliwneb/robocut).

The interface icons are from [Tabler Icons](https://tabler.io/icons) — © 2020–2026 Paweł Kuna, MIT license ([LICENSE-tabler-icons.txt](LICENSE-tabler-icons.txt)) — with the stroke adjusted to 1.5.

Updates use [Sparkle](https://sparkle-project.org) — © 2006–2013 Andy Matuschak and contributors, MIT license ([LICENSE-sparkle.txt](LICENSE-sparkle.txt)).

## License

Copyright © 2026 João Corrêa.

[GPL-2.0](LICENSE) — the same as inkscape-silhouette, which the driver derives from.

## Disclaimer

Cutline is an independent project with no affiliation with Silhouette America, Inc. "Silhouette", "Silhouette Studio", "Cameo", "Portrait" and "Curio" are trademarks of their owners, mentioned here only to indicate compatibility. `.studio3` files are opened by reading only the file's own data; no Silhouette Studio code or data is part of this project. "Adobe" and "Illustrator" are trademarks of Adobe Inc., mentioned only to indicate compatibility.
