# Use the permission-free photo picker and ship iOS store metadata

Date: 2026-10-28

## Decision

The iOS image picker uses `PHPickerConfiguration()` rather than
`PHPickerConfiguration(photoLibrary:)`. It still requests the current asset
representation, including original HEIC bytes, and then transcodes through the
existing image pipeline. The iOS target now has its own app icon, the shared
accent color, a light/dark launch background, the display name Plainsong, and
`ITSAppUsesNonExemptEncryption = false`.

## Why

Accessing `PHPhotoLibrary.shared()` while constructing the picker requires
`NSPhotoLibraryUsageDescription` and can terminate the app when that key is
absent. The default picker lets the user select one image without granting
library access. The previous iOS bundle also had no icon, accent, or named
launch appearance.

## Alternatives

Adding a photo-library purpose string (rejected: asks for broader access than
the picker needs). Reusing the macOS icon catalog (rejected: its icon idiom is
macOS-only). Leaving the empty launch screen (rejected: the first frame does
not follow the app's light and dark appearance).

## Verification

Simulator build and launch remain separate evidence. This does not sign the app
or close any physical-device acceptance gate.


The 1024 icon is flattened to an opaque full-bleed square. Asset catalogs reject
transparent corners, and iOS applies the home-screen mask itself. Recent file
and folder bookmarks are stored only in this app's UserDefaults, so the bundle
includes a privacy manifest with reason CA92.1 and no tracking or collected-data
types. No photo-library purpose string is added.
