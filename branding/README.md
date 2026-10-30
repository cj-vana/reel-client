# Reel logo

The Reel logo is a continuous open filmstrip that forms the letter R. The app icon is mint on a full-bleed midnight background. The flat marks use the same contour.

## Files

- `reelclient-logo.blend`: the editable Blender scene (contour, beveled mesh, material, lights, camera). No external art is needed.
- `reelclient-app-icon-1024.png`: opaque square source. Each platform applies its own mask.
- `reelclient-mark-transparent-1024.png`: shaded mark on a transparent background.
- `reelclient-mark.svg`: mint `#96E8CF` mark.
- `reelclient-mark-white.svg` and `reelclient-mark-template.svg`: white mark, for native template rendering.
- `reelclient-mark-ink.svg`: dark `#132D31` mark.
- `reelclient-mark-flat-1024.png` and `reelclient-mark-template-*`: flat white rasters.
- Icon, shaded and ink variants are also supplied at 16, 24, 32, 48, 64, 80, 96, 117, 128, 130, 256 and 512 pixels.

## Rebuild

You need Blender 5.2 or later and Python with Pillow:

```sh
blender --background --factory-startup --python-exit-code 1 --python build_blender.py
python3 package_assets.py
```

Output is written next to the scripts. To rebuild into a separate folder, pass `-- ./reproduce` after the Blender arguments.

`render_tv.py` and `package_tv.py` produce the tvOS icon layers from the same contour. The desktop packager (`apps/desktop/scripts/package.mjs`) builds ICNS and ICO files from these PNGs using `sips` and `iconutil` on macOS.

## License

The logo is original artwork under the repository's MIT license. It contains no font outlines, stock icons, downloaded models or Jellyfin marks.
