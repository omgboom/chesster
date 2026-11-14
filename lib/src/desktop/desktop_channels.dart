part of '../../main.dart';

/// The `maia_chess/engine` channel. Android answers it natively; on desktop
/// ([desktopFallbacksEnabled]) [DesktopEngineHost] answers it in Dart.
class MaiaEngineChannel extends MethodChannel {
  const MaiaEngineChannel(super.name);

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    if (!desktopFallbacksEnabled) {
      return super.invokeMethod<T>(method, arguments);
    }
    return DesktopEngineHost.instance.invoke(method, arguments).then((value) {
      return value as T?;
    });
  }
}

/// A channel whose Android-only feature is unavailable on desktop: every call
/// fails fast with an `unsupported` [PlatformException] there.
class AndroidOnlyMethodChannel extends MethodChannel {
  const AndroidOnlyMethodChannel(super.name, this.unsupportedMessage);

  final String unsupportedMessage;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    if (!desktopFallbacksEnabled) {
      return super.invokeMethod<T>(method, arguments);
    }
    return Future<T?>.error(
      PlatformException(code: 'unsupported', message: unsupportedMessage),
    );
  }
}

/// An event channel that stays silent on desktop instead of reporting a
/// missing plugin when listened to.
class AndroidOnlyEventChannel extends EventChannel {
  const AndroidOnlyEventChannel(super.name);

  @override
  Stream<dynamic> receiveBroadcastStream([dynamic arguments]) {
    if (!desktopFallbacksEnabled) {
      return super.receiveBroadcastStream(arguments);
    }
    return StreamController<dynamic>.broadcast().stream;
  }
}

/// Dart implementation of the Android `maia_chess/engine` host methods for
/// desktop builds. Features without a desktop equivalent degrade to no-ops.
class DesktopEngineHost {
  DesktopEngineHost({DesktopMaiaRuntime? maia, this.documentsDirectoryOverride})
    : maia = maia ?? DesktopMaiaRuntime.instance;

  static DesktopEngineHost instance = DesktopEngineHost();

  final DesktopMaiaRuntime maia;

  /// Replaces the user's Documents folder (tests).
  final Directory? documentsDirectoryOverride;

  static const _maxPgnBytes = 5 * 1024 * 1024;

  Future<Object?> invoke(String method, Object? arguments) async {
    final args = arguments is Map ? arguments : const <Object?, Object?>{};
    switch (method) {
      case 'predict':
        final tokens = args['tokens'];
        final selfElo = args['selfElo'];
        final opponentElo = args['opponentElo'];
        if (tokens is! Float32List || selfElo is! int || opponentElo is! int) {
          throw PlatformException(
            code: 'bad_arguments',
            message: 'Expected 6208 float tokens and two Elo values',
          );
        }
        try {
          return await maia.predict(
            tokens: tokens,
            selfElo: selfElo,
            opponentElo: opponentElo,
            includeValue: args['includeValue'] == true,
          );
        } on PlatformException {
          rethrow;
        } catch (error, stack) {
          throw PlatformException(
            code: 'inference_failed',
            message: '$error',
            details: '$stack',
          );
        }
      case 'release':
        await maia.release();
        return null;
      case 'dataDirectory':
        return (await applicationDataDirectory()).path;
      case 'previousProcessFailed':
        return false;
      case 'systemDiagnostics':
        return {
          'operatingSystem': Platform.operatingSystem,
          'operatingSystemVersion': Platform.operatingSystemVersion,
          'processors': Platform.numberOfProcessors,
        };
      case 'samplingMetadata':
        return _samplingMetadata();
      case 'openUrl':
        await openExternalUrl(args['url']);
        return null;
      case 'savePgnFile':
        await _writeDocument('pgn', '${args['pgn'] ?? ''}');
        return true;
      case 'sharePgn':
        final file = await _writeDocument('pgn', '${args['pgn'] ?? ''}');
        unawaited(_reveal(file));
        return file.path;
      case 'shareFen':
        final fen = args['fen'];
        if (fen is! String || fen.trim().isEmpty || fen.length > 512) {
          throw PlatformException(
            code: 'bad_arguments',
            message: 'Expected a FEN position',
          );
        }
        await Clipboard.setData(ClipboardData(text: fen));
        return null;
      case 'getPendingPgn':
        return null;
      case 'openPgnFile':
        return _openPgnFile();
      case 'setKeepScreenOn':
        return null;
      case 'saveSamplingData':
        return _saveSamplingData(args['readable'] == true);
      default:
        throw MissingPluginException(
          'No desktop implementation for $method on maia_chess/engine',
        );
    }
  }

  /// Per-user app data (sessions, sampling data).
  static Future<Directory> applicationDataDirectory() async {
    final env = Platform.environment;
    final separator = Platform.pathSeparator;
    final String base;
    if (Platform.isWindows) {
      base =
          env['APPDATA'] ??
          '${env['USERPROFILE'] ?? '.'}${separator}AppData${separator}Roaming';
    } else if (Platform.isMacOS) {
      base = '${env['HOME']}/Library/Application Support';
    } else {
      base = env['XDG_DATA_HOME'] ?? '${env['HOME'] ?? '.'}/.local/share';
    }
    final directory = Directory('$base${separator}Chesster');
    await directory.create(recursive: true);
    return directory;
  }

  static String? _documentsCache;

  /// `<Documents>/Chesster`, honoring a redirected (e.g. OneDrive) folder.
  Future<Directory> documentsDirectory() async {
    final override = documentsDirectoryOverride;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }
    var documents = _documentsCache;
    if (documents == null) {
      final env = Platform.environment;
      if (Platform.isWindows) {
        try {
          final result = await Process.run('powershell', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            "[Environment]::GetFolderPath('MyDocuments')",
          ]).timeout(const Duration(seconds: 10));
          final path = '${result.stdout}'.trim();
          if (result.exitCode == 0 && path.isNotEmpty) documents = path;
        } catch (_) {
          // Fall back to the default profile location below.
        }
        documents ??= '${env['USERPROFILE'] ?? '.'}\\Documents';
      } else {
        documents = '${env['HOME'] ?? '.'}/Documents';
      }
      _documentsCache = documents;
    }
    final directory = Directory('$documents${Platform.pathSeparator}Chesster');
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _writeDocument(String extension, String text) async {
    final directory = await documentsDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    var file = File(
      '${directory.path}${Platform.pathSeparator}chesster-$stamp.$extension',
    );
    for (var suffix = 2; await file.exists(); suffix++) {
      file = File(
        '${directory.path}${Platform.pathSeparator}'
        'chesster-$stamp-$suffix.$extension',
      );
    }
    await file.writeAsString(text, flush: true);
    return file;
  }

  Future<Map<String, Object?>> _samplingMetadata() async {
    String version = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version;
    } catch (_) {}
    return {
      'appVersion': version,
      'flavor': 'desktop',
      'model': 'maia3-79m-3454b03a-sha256.onnx',
      'modelSha256':
          '3454b03ae78baa64a87b345fdb1a457265d912caec531039b074f07eda0d8010',
      'runtime': 'onnxruntime-dart-ffi',
      'runtimeVersion': '1.24.3',
      'provider': 'CPU',
    };
  }

  Future<bool> _saveSamplingData(bool readable) async {
    final data = await applicationDataDirectory();
    final separator = Platform.pathSeparator;
    final name = readable ? 'report.html' : 'export.jsonl';
    final source = File('${data.path}${separator}sampling-data$separator$name');
    if (!await source.exists()) return false;
    final target = await _writeDocument(
      readable ? 'html' : 'jsonl',
      await source.readAsString(),
    );
    unawaited(_reveal(target));
    return true;
  }

  Future<String?> _openPgnFile() async {
    if (!Platform.isWindows) {
      throw PlatformException(
        code: 'unsupported',
        message: 'Opening PGN files is only available on Windows and Android.',
      );
    }
    final initial = (await documentsDirectory()).path;
    const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = 'PGN files (*.pgn)|*.pgn|All files (*.*)|*.*'
$dialog.InitialDirectory = $env:CHESSTER_INITIAL_DIR
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.Write($dialog.FileName)
}
''';
    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-NonInteractive', '-STA', '-Command', script],
      environment: {'CHESSTER_INITIAL_DIR': initial},
      stdoutEncoding: utf8,
    );
    final path = '${result.stdout}'.trim();
    if (result.exitCode != 0 || path.isEmpty) return null;
    final file = File(path);
    try {
      if (await file.length() > _maxPgnBytes) {
        throw PlatformException(
          code: 'pgn_read_failed',
          message: 'PGN file is larger than 5 MB',
        );
      }
      return await file.readAsString();
    } on PlatformException {
      rethrow;
    } catch (error) {
      throw PlatformException(code: 'pgn_read_failed', message: '$error');
    }
  }

  Future<void> _reveal(File file) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', ['/select,', file.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', file.path]);
      }
    } catch (_) {
      // Revealing the saved file is a convenience only.
    }
  }

  /// Opens an http(s) URL in the default browser without a shell, so URL
  /// characters such as `&` are never interpreted as commands.
  static Future<void> openExternalUrl(Object? value) async {
    final uri = value is String ? Uri.tryParse(value) : null;
    if (uri == null || !{'http', 'https'}.contains(uri.scheme.toLowerCase())) {
      throw PlatformException(
        code: 'bad_arguments',
        message: 'Expected an HTTP or HTTPS URL',
      );
    }
    final url = uri.toString();
    final ProcessResult result;
    try {
      if (Platform.isWindows) {
        result = await Process.run('rundll32', [
          'url.dll,FileProtocolHandler',
          url,
        ]);
      } else if (Platform.isMacOS) {
        result = await Process.run('open', [url]);
      } else {
        result = await Process.run('xdg-open', [url]);
      }
    } catch (error) {
      throw PlatformException(code: 'url_unavailable', message: '$error');
    }
    if (result.exitCode != 0) {
      throw PlatformException(
        code: 'url_unavailable',
        message: 'No app can open this URL',
      );
    }
  }
}
