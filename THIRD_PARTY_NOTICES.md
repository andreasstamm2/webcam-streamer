# Third-Party Notices

`webcam_streamer` redistributes the following third-party components in its
installer. Each is governed by its own license. By installing
`webcam_streamer`, you also accept the terms of these licenses.

---

## FFmpeg

- **Version shipped**: 8.1.1 ("essentials" build by gyan.dev)
- **Upstream project**: https://www.ffmpeg.org/
- **Binary source used**: https://www.gyan.dev/ffmpeg/builds/
- **License**: **GNU General Public License v3.0 or later** (this build is
  configured with `--enable-gpl --enable-version3`, which links GPL-only
  components such as `libx264`, `libx265`, `libxvid`, `librubberband`,
  `libvidstab`).
- **Build configuration of the bundled binary** (captured at packaging
  time — run `ffmpeg -version` on the installed binary to confirm):

  ```
  --enable-gpl --enable-version3 --enable-static --disable-w32threads
  --disable-autodetect --enable-libx264 --enable-libx265 --enable-libxvid
  --enable-libaom --enable-libvpx --enable-mediafoundation --enable-libass
  --enable-libfreetype --enable-libfribidi --enable-libharfbuzz
  --enable-libvidstab --enable-libvmaf --enable-libzimg --enable-amf
  --enable-cuda-llvm --enable-cuvid --enable-dxva2 --enable-d3d11va
  --enable-d3d12va --enable-ffnvcodec --enable-libvpl --enable-nvdec
  --enable-nvenc --enable-vaapi --enable-libmp3lame --enable-libtheora
  --enable-libopus --enable-libvorbis --enable-librubberband
  --enable-gnutls (...full list in `ffmpeg -version`)
  ```

- **Source code availability**: corresponding source code for the bundled
  FFmpeg binary is available at https://www.ffmpeg.org/releases/ and from
  the upstream build provider at https://www.gyan.dev/ffmpeg/builds/.
  In accordance with GPL-3.0 §6, the maintainers of `webcam_streamer`
  will, on written request submitted as a GitHub issue, supply the exact
  corresponding source for any binary shipped in an official release, for
  a period of three years from the release date.

- **License text**: see `LICENSE` at the root of this repository (the
  GPL-3.0 text), which is the same license `webcam_streamer` itself is
  released under.

---

## MediaMTX

- **Version shipped**: 1.18.1
- **Upstream project**: https://github.com/bluenviron/mediamtx
- **License**: MIT
- **License text**: bundled as `mediamtx-LICENSE.txt` next to the binary
  in the installation directory, and reproduced in
  `third_party/mediamtx/LICENSE` in the source tree.

---

## nlohmann/json

- **Used by**: the C++ supervisor (`supervisor/third_party/nlohmann/json.hpp`)
- **Upstream project**: https://github.com/nlohmann/json
- **License**: MIT
- **License text**: included in the header file itself; reproduced in
  the source tree under `supervisor/third_party/nlohmann/`.

---

## .NET 9 Desktop Runtime

The Windows Presentation Foundation (WPF) UI is published as a
self-contained executable. This embeds the .NET 9 runtime, which is
released by Microsoft under the **MIT License**. See
https://github.com/dotnet/runtime for sources and license text.
