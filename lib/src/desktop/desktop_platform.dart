part of '../../main.dart';

/// Platform seam for desktop support. On Android/iOS the native
/// `multistockfish` engine is used; desktop builds run Stockfish as a process.
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Test override for [desktopFallbacksEnabled]; null selects the default.
@visibleForTesting
bool? debugDesktopFallbacksOverride;

final bool _runningUnderFlutterTest = Platform.environment.containsKey(
  'FLUTTER_TEST',
);

/// Whether the Dart replacements for the Android-only platform channels are
/// active. Host tests run on desktop (`flutter_tester`) but mock the channels,
/// so the replacements stay off under `flutter test` unless a test opts in
/// with [debugDesktopFallbacksOverride].
bool get desktopFallbacksEnabled =>
    debugDesktopFallbacksOverride ??
    (isDesktopPlatform && !_runningUnderFlutterTest);

/// SharedPreferences key holding a user-chosen Stockfish executable path.
const dojoStockfishPathPreferenceKey = 'dojoStockfishPathV1';

/// Creates a fresh UCI engine handle for the current platform.
Future<StockfishEngineHandle> createPlatformStockfishHandle() async {
  if (!isDesktopPlatform) {
    return _MultistockfishHandle(await Stockfish.create());
  }
  final executable = await locateStockfishExecutable();
  if (executable == null) throw const StockfishNotFoundException();
  return ProcessStockfishHandle.start(executable);
}

class StockfishNotFoundException implements Exception {
  const StockfishNotFoundException();

  @override
  String toString() =>
      'Stockfish was not found. Put stockfish.exe next to the app, in a '
      '"stockfish" folder beside it, on PATH, or choose it in the settings.';
}

String get _stockfishExecutableName =>
    Platform.isWindows ? 'stockfish.exe' : 'stockfish';

/// Finds a Stockfish executable for desktop builds, in order: next to the
/// running executable, in a `stockfish/` folder beside it, the path stored in
/// [dojoStockfishPathPreferenceKey], then `PATH`. Returns null if none exist.
Future<String?> locateStockfishExecutable({
  String? executableDirectory,
  String? preferencePath,
  Map<String, String>? environment,
}) async {
  final name = _stockfishExecutableName;
  final separator = Platform.pathSeparator;
  final appDirectory =
      executableDirectory ?? File(Platform.resolvedExecutable).parent.path;
  final candidates = <String>[
    '$appDirectory$separator$name',
    '$appDirectory${separator}stockfish$separator$name',
  ];
  var stored = preferencePath;
  if (stored == null) {
    try {
      stored = (await SharedPreferences.getInstance()).getString(
        dojoStockfishPathPreferenceKey,
      );
    } catch (_) {
      // Preferences are optional here; fall through to PATH.
    }
  }
  if (stored != null && stored.trim().isNotEmpty) candidates.add(stored.trim());
  final env = environment ?? Platform.environment;
  final pathValue =
      env['PATH'] ??
      env['Path'] ??
      env.entries
          .where((entry) => entry.key.toUpperCase() == 'PATH')
          .map((entry) => entry.value)
          .firstOrNull;
  if (pathValue != null) {
    for (final directory in pathValue.split(Platform.isWindows ? ';' : ':')) {
      final trimmed = directory.trim().replaceAll('"', '');
      if (trimmed.isEmpty) continue;
      candidates.add('$trimmed$separator$name');
    }
  }
  for (final candidate in candidates) {
    if (await File(candidate).exists()) return File(candidate).absolute.path;
  }
  return null;
}

/// A UCI engine running as a child process (desktop builds).
final class ProcessStockfishHandle implements StockfishEngineHandle {
  ProcessStockfishHandle._(this._process) {
    _stdoutSubscription = _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _lines.add,
          onError: _lines.addError,
          onDone: () => unawaited(_lines.close()),
        );
    // Drain stderr so a chatty engine can never block on a full pipe.
    _stderrSubscription = _process.stderr.listen((_) {});
    unawaited(_process.exitCode.then((_) => _exited = true));
  }

  static Future<ProcessStockfishHandle> start(String executable) async {
    final process = await Process.start(
      executable,
      const [],
      workingDirectory: File(executable).parent.path,
    );
    return ProcessStockfishHandle._(process);
  }

  final Process _process;
  final StreamController<String> _lines = StreamController.broadcast();
  late final StreamSubscription<List<int>> _stderrSubscription;
  late final StreamSubscription<String> _stdoutSubscription;
  bool _exited = false;
  bool _disposed = false;

  int get pid => _process.pid;

  @override
  Stream<String> get stdout => _lines.stream;

  @override
  set stdin(String command) {
    if (_disposed || _exited) {
      throw StateError('Stockfish process is not running');
    }
    _process.stdin.write('$command\n');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_exited) {
      try {
        _process.stdin.write('quit\n');
        await _process.stdin.flush();
      } catch (_) {
        // The process may already be gone.
      }
    }
    try {
      await _process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _process.kill();
      await _process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
    }
    try {
      await _process.stdin.close();
    } catch (_) {}
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    if (!_lines.isClosed) await _lines.close();
  }
}
