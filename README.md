# Focus Palette

An Aseprite extension that replaces the native F8 preview with an editable focus mode and a floating palette-only picker.

## Features

- Cmd+Enter toggles a clean editable focus mode on macOS.
- Floating palette window with left-click foreground and right-click background picking.
- Tab toggles the timeline while focus mode is active.
- Optional PNG palette mode: draw a PNG as the palette, resize the window while preserving aspect ratio, and pick colors from the PNG pixels.
- Manual update check through GitHub Releases.

## Install

Download `focus-palette.aseprite-extension` from the latest GitHub Release and install it in Aseprite:

`Edit > Preferences > Extensions > Add Extension`

Restart Aseprite after installing or updating.

## PNG Palette

Use `View > Focus Palette: Choose PNG...` to select a PNG palette. The extension copies the PNG into Aseprite's config directory so the palette keeps working even if the original file moves.

Use `View > Focus Palette: Use PNG Palette` to switch between the sprite palette and the PNG palette.

## Updates

Use `View > Focus Palette: Check for Updates...`.

The extension checks the latest release from `rauldeavila/focus-palette`, downloads the `.aseprite-extension` asset if a newer version exists, and opens it so Aseprite can install it.

## Build

```sh
./build.sh
```

The extension package is generated at:

```text
dist/focus-palette.aseprite-extension
```

## Release

1. Update `version` in `package.json`.
2. Update `EXTENSION_VERSION` in `main.lua`.
3. Commit the change.
4. Tag the commit:

```sh
git tag v0.1.8
git push origin main --tags
```

GitHub Actions will build the extension and attach `focus-palette.aseprite-extension` to the release.
