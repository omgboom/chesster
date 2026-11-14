# Local patches to onnxruntime 1.4.1

Source: https://pub.dev/packages/onnxruntime version 1.4.1 (MIT, see `LICENSE`).
Only `lib/`, `LICENSE`, `README.md` and `CHANGELOG.md` were copied.

1. Package renamed to `onnxruntime_dart`; `package:onnxruntime/` imports rewritten.
2. `pubspec.yaml`: removed the `flutter: plugin:` section (it bundled Android
   `libonnxruntime.so` files that would clash with the app's onnxruntime-android
   AAR) and the dev dependencies. No native binaries are vendored.
3. `lib/src/bindings/bindings.dart`: `onnxRuntimeLibraryPath` lets the app pick
   the shared library path before first use (defaults unchanged otherwise).
4. `lib/src/ort_session.dart`: `OrtSession.fromFile` passes the model path as
   UTF-16 (`wchar_t`) on Windows, as `ORTCHAR_T` requires there, and frees it.
5. `lib/onnxruntime.dart`: also exports `onnxRuntimeLibraryPath`.
