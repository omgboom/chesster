# Building Chesster

Chesster is a Flutter app (one Dart library, `lib/main.dart` plus `part`
files) built for Android (Pixel 8a) and Windows. CI builds both; local builds
are optional.

## Prerequisites (all platforms)

- Flutter **3.47.8** (the version CI pins). Either clone it
  (`git clone --depth 1 --branch 3.47.8 https://github.com/flutter/flutter.git`)
  and add `flutter/bin` to `PATH`, or use the Flutter installer and switch to
  3.47.8.
- Git LFS: the Maia model `assets/models/maia3-79m.onnx` (316 MB) is an LFS
  object. Run `git lfs install` once, then `git lfs pull` in the checkout.
  Without it the Android build stops with "Maia model missing or wrong size".
- `flutter pub get`, then `flutter analyze` and `flutter test` work on any
  host without further tooling.

Optional real-engine tests (`test/desktop_platform_test.dart`) run when these
variables point at local binaries, otherwise they are skipped:

```powershell
$env:CHESSTER_STOCKFISH = "C:\path\to\stockfish.exe"
$env:CHESSTER_ORT_DLL   = "C:\path\to\onnxruntime.dll"
flutter test test/desktop_platform_test.dart
```

## Windows desktop

1. Install **Visual Studio Build Tools 2022** (or Visual Studio 2022) with the
   **"Desktop development with C++"** workload (MSVC v143, Windows 10/11 SDK,
   CMake tools). `flutter doctor` must show the Visual Studio line as OK.
2. Enable Windows *Developer Mode* (Settings > System > For developers);
   Flutter needs symlink support for plugins.
3. Fetch the engine binaries into the gitignored `windows/deps/` folder
   (Microsoft's `onnxruntime.dll` 1.24.3 and the official Stockfish 19
   `stockfish.exe`, SHA-256 pinned):

   ```powershell
   powershell -ExecutionPolicy Bypass -File tool/fetch_windows_deps.ps1
   ```

4. Build and run:

   ```powershell
   flutter run -d windows                 # debug
   flutter build windows --release        # build\windows\x64\runner\Release\
   ```

The `Release` folder is self-contained: `chesster.exe`, `onnxruntime.dll`,
`stockfish.exe`, `licenses/` and `data/` (including the Maia model). Copy the
whole folder to install it anywhere.

How the desktop build works:

- **Stockfish** runs as a child process. The app looks for `stockfish.exe`
  next to `chesster.exe`, then in a `stockfish\` subfolder, then at the path
  saved in the `dojoStockfishPathV1` preference, then on `PATH`.
- **Maia** runs through ONNX Runtime's C API via Dart FFI
  (`third_party/onnxruntime_dart`) in a background isolate, loading the model
  from `data\flutter_assets\assets\models\`. `CHESSTER_ORT_DLL` and
  `CHESSTER_MAIA_MODEL` override the DLL and model paths.
- Android-only features degrade: PGN save/share writes to
  `Documents\Chesster\`, PGN open uses a Windows file dialog, FEN share copies
  to the clipboard, sound effects and Bluetooth boards are unavailable. App
  data lives in `%APPDATA%\Chesster`.

## Android

1. Install **Android Studio** (or the command-line tools) with an Android SDK
   (platform 36, build-tools, platform-tools) and let Flutter find it
   (`flutter config --android-sdk <path>`; `flutter doctor --android-licenses`).
   The NDK version Flutter needs is installed automatically on first build.
2. JDK 17 or newer (`JAVA_HOME`).
3. Build:

   ```powershell
   flutter build apk --release --target-platform android-arm64
   ```

   Output: `build\app\outputs\flutter-apk\app-release.apk`.

Signing: release builds use the Chesster release key when all four values are
set, either as environment variables `CHESSTER_KEYSTORE`,
`CHESSTER_KEYSTORE_PASSWORD`, `CHESSTER_KEY_ALIAS`, `CHESSTER_KEY_PASSWORD`,
or in `android/key.properties` (gitignored):

```properties
storeFile=C:/Users/<you>/dev/chesster-signing/chesster-release.jks
storePassword=...
keyAlias=chesster
keyPassword=...
```

Without them the release APK is signed with the debug key. A debug-signed APK
cannot update a release-signed install (and vice versa); uninstall first.

The application id is `com.chesster.dojo`, so Chesster installs next to the
upstream Mobile Maia app. The Kotlin package stays `com.dash1971.maia_chess`.

## CI

- **CI** (`.github/workflows/ci.yml`): every push and pull request to `main`
  runs `flutter analyze` and `flutter test` on Ubuntu.
- **Build** (`.github/workflows/build.yml`): on push to `main`, on `v*` tags and
  on manual dispatch (Actions > Build > Run workflow, any branch):
  - `chesster-android-arm64`: release APK signed with the key stored in the
    repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
    `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Every CI build gets
    versionCode `1000 + run number`, so newer builds install over older ones.
  - `chesster-windows-x64`: zip of the Windows `Release` folder. The job first
    runs the real Stockfish/ONNX Runtime desktop tests.
  - On a `v*` tag (e.g. `git tag v0.1.0 && git push origin v0.1.0`) both files
    are attached to a new GitHub Release.

Downloading builds: open the repository on GitHub > **Actions** > **Build** >
the run > **Artifacts** (kept 14 days; you must be signed in), or the
**Releases** page for tagged builds. With the GitHub CLI:

```powershell
gh run list -R omgboom/chesster -w build.yml
gh run download <run-id> -R omgboom/chesster
gh release download v0.1.0 -R omgboom/chesster
```

The Maia model is cached in Actions by its LFS object id, so LFS bandwidth is
only used when the model changes. Windows runners use Actions minutes at twice
the Linux rate in private repositories.

## Sideloading the APK on a Pixel 8a

1. Download the APK (artifact zips contain the `.apk`; extract it first).
2. Either:
   - **On the phone:** copy/download the APK to the phone, open it from Files
     or Chrome, allow "Install unknown apps" for that app when Android asks,
     then tap **Install**. Play Protect may warn about an unknown developer:
     choose **More details > Install anyway**.
   - **With USB (adb):** enable Developer options (Settings > About phone >
     tap *Build number* 7 times), turn on **USB debugging**, connect the
     phone, accept the prompt, then run
     `adb install -r chesster-...-arm64.apk`.
3. Updates: install a newer CI APK the same way; it replaces the app and keeps
   its data as long as it is signed with the same release key.
4. Microphone input asks for the microphone permission on first use; the Claude
   features need an Internet connection.
