# PNG app icon assets

`glance/Assets.xcassets/appicon.imageset/appicon.png` is the full-size source artwork. The PNGs in `GlanceIcon.appiconset` use [macOS Compliant Icon Generator](https://github.com/yc-w-cn/macos-compliant-icon-generator) (`302c30239315a1ae90a5d43e6e51efc78d9d4c84`) to center the artwork at 832×832 on a transparent 1024×1024 canvas with the generator's rounded-corner clipping. The smaller slots are resized from that output.

Regenerate from the source artwork, applying the generator once, to preserve the 96-pixel margins at 1024×1024.
