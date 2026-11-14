part of '../../main.dart';

/// Maia-3 inference on desktop through ONNX Runtime's C API (FFI).
///
/// The session lives in a dedicated worker isolate so the 300 MB model load
/// and each inference never block the UI isolate. Requests are processed one
/// at a time in arrival order, like the Android single-thread executor.
class DesktopMaiaRuntime {
  DesktopMaiaRuntime({this.libraryPath, this.modelPath});

  static final instance = DesktopMaiaRuntime();

  static const tokenCount = 64 * 97;
  static const moveLogitCount = 4352;
  static const modelAsset = 'assets/models/maia3-79m.onnx';

  /// Explicit paths (tests); null resolves the defaults below.
  final String? libraryPath;
  final String? modelPath;
  Future<_DesktopMaiaWorker>? _worker;

  /// `onnxruntime.dll` next to the executable, overridable with
  /// `CHESSTER_ORT_DLL`; otherwise the system library search order applies.
  String resolveLibraryPath() {
    if (libraryPath case final path?) return path;
    final override = Platform.environment['CHESSTER_ORT_DLL'];
    if (override != null && override.isNotEmpty) return override;
    final name = Platform.isWindows
        ? 'onnxruntime.dll'
        : Platform.isMacOS
        ? 'libonnxruntime.dylib'
        : 'libonnxruntime.so';
    final local = File(
      '${File(Platform.resolvedExecutable).parent.path}'
      '${Platform.pathSeparator}$name',
    );
    return local.existsSync() ? local.path : name;
  }

  /// The model asset bundled by `flutter build windows` under
  /// `data/flutter_assets`, overridable with `CHESSTER_MAIA_MODEL`.
  String resolveModelPath() {
    if (modelPath case final path?) return path;
    final override = Platform.environment['CHESSTER_MAIA_MODEL'];
    if (override != null && override.isNotEmpty) return override;
    final separator = Platform.pathSeparator;
    final root = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$root${separator}data${separator}flutter_assets$separator$modelAsset',
      // macOS app bundle layout.
      '${File(root).parent.path}${separator}Frameworks${separator}App.framework'
          '${separator}Resources${separator}flutter_assets$separator$modelAsset',
    ].map((path) => path.replaceAll('/', separator));
    return candidates.firstWhere(
      (path) => File(path).existsSync(),
      orElse: () => candidates.first,
    );
  }

  /// Returns the move logits, or `{move_logits, value_logits}` when
  /// [includeValue] is set (same shape as the Android channel reply).
  Future<Object> predict({
    required Float32List tokens,
    required int selfElo,
    required int opponentElo,
    bool includeValue = false,
  }) async {
    if (tokens.length != tokenCount) {
      throw PlatformException(
        code: 'bad_arguments',
        message: 'Expected $tokenCount float tokens and two Elo values',
      );
    }
    final worker = await _ensureWorker();
    final reply = await worker.request(
      _MaiaWorkerRequest(
        TransferableTypedData.fromList([tokens]),
        selfElo,
        opponentElo,
        includeValue,
      ),
    );
    final moves = reply.moves.materialize().asFloat32List();
    if (!includeValue) return moves;
    final values = reply.values!.materialize().asFloat32List();
    if (values.length != 3 || values.any((value) => !value.isFinite)) {
      throw PlatformException(
        code: 'inference_failed',
        message: 'Expected finite Loss/Draw/Win logits',
      );
    }
    return {'move_logits': moves, 'value_logits': values};
  }

  Future<_DesktopMaiaWorker> _ensureWorker() {
    final pending = _worker ??= _DesktopMaiaWorker.spawn(
      resolveLibraryPath(),
      resolveModelPath(),
    );
    return pending.catchError((Object error) {
      if (identical(_worker, pending)) _worker = null;
      throw error;
    });
  }

  /// Frees the model session (re-created on the next prediction).
  Future<void> release() async {
    final pending = _worker;
    _worker = null;
    if (pending == null) return;
    try {
      await (await pending).close();
    } catch (_) {
      // A worker that never started has nothing to release.
    }
  }
}

class _MaiaWorkerRequest {
  const _MaiaWorkerRequest(
    this.tokens,
    this.selfElo,
    this.opponentElo,
    this.includeValue,
  );

  final TransferableTypedData tokens;
  final int selfElo;
  final int opponentElo;
  final bool includeValue;
}

class _MaiaWorkerReply {
  const _MaiaWorkerReply(this.id, this.moves, this.values, this.error);

  final int id;
  final TransferableTypedData moves;
  final TransferableTypedData? values;
  final String? error;
}

class _DesktopMaiaWorker {
  _DesktopMaiaWorker._(this._isolate, this._commands, this._replies);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;
  final Map<int, Completer<_MaiaWorkerReply>> _pending = {};
  int _nextId = 0;
  bool _closed = false;

  static Future<_DesktopMaiaWorker> spawn(
    String libraryPath,
    String modelPath,
  ) async {
    if (!File(modelPath).existsSync()) {
      throw PlatformException(
        code: 'model_missing',
        message: 'Maia model not found at $modelPath',
      );
    }
    final replies = ReceivePort('maia-desktop-replies');
    final ready = Completer<SendPort>();
    late final _DesktopMaiaWorker worker;
    replies.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is List && message.length == 2 && !ready.isCompleted) {
        // Startup failure: [error, stack].
        ready.completeError(
          PlatformException(
            code: 'model_load_failed',
            message: '${message[0]}',
            details: '${message[1]}',
          ),
        );
      } else if (message is _MaiaWorkerReply) {
        worker._complete(message);
      }
    });
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _desktopMaiaWorkerMain,
        (replies.sendPort, libraryPath, modelPath),
        debugName: 'maia-onnxruntime',
        errorsAreFatal: true,
      );
    } catch (_) {
      replies.close();
      rethrow;
    }
    final SendPort commands;
    try {
      commands = await ready.future;
    } catch (_) {
      replies.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
    return worker = _DesktopMaiaWorker._(isolate, commands, replies);
  }

  Future<_MaiaWorkerReply> request(_MaiaWorkerRequest request) async {
    if (_closed) throw StateError('Maia runtime released');
    final id = _nextId++;
    final completer = _pending[id] = Completer<_MaiaWorkerReply>();
    _commands.send((id, request));
    final reply = await completer.future;
    if (reply.error != null) {
      throw PlatformException(code: 'inference_failed', message: reply.error);
    }
    return reply;
  }

  void _complete(_MaiaWorkerReply reply) {
    _pending.remove(reply.id)?.complete(reply);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final exited = ReceivePort();
    _isolate.addOnExitListener(exited.sendPort);
    _commands.send(null);
    await exited.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () => _isolate.kill(priority: Isolate.immediate),
    );
    exited.close();
    _replies.close();
    for (final pending in _pending.values) {
      pending.completeError(StateError('Maia runtime released'));
    }
    _pending.clear();
  }
}

/// Worker isolate entry: owns the ONNX Runtime environment and session.
Future<void> _desktopMaiaWorkerMain((SendPort, String, String) setup) async {
  final (replies, libraryPath, modelPath) = setup;
  final ort.OrtSession session;
  try {
    ort.onnxRuntimeLibraryPath = libraryPath;
    ort.OrtEnv.instance.init();
    final options = ort.OrtSessionOptions()
      ..setIntraOpNumThreads(
        (Platform.numberOfProcessors ~/ 2).clamp(1, 4).toInt(),
      )
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(
        ort.GraphOptimizationLevel.ortEnableBasic,
      );
    session = ort.OrtSession.fromFile(File(modelPath), options);
    options.release();
  } catch (error, stack) {
    replies.send(['$error', '$stack']);
    return;
  }
  final commands = ReceivePort('maia-desktop-commands');
  replies.send(commands.sendPort);
  final runOptions = ort.OrtRunOptions();
  await for (final message in commands) {
    if (message == null) break;
    final (int id, _MaiaWorkerRequest request) =
        message as (int, _MaiaWorkerRequest);
    final inputs = <ort.OrtValue>[];
    List<ort.OrtValue?> outputs = const [];
    try {
      final tokens = request.tokens.materialize().asFloat32List();
      final tokenTensor = ort.OrtValueTensor.createTensorWithDataList(tokens, [
        1,
        64,
        97,
      ]);
      inputs.add(tokenTensor);
      final selfTensor = ort.OrtValueTensor.createTensorWithDataList(
        Int64List.fromList([request.selfElo]),
        [1],
      );
      inputs.add(selfTensor);
      final opponentTensor = ort.OrtValueTensor.createTensorWithDataList(
        Int64List.fromList([request.opponentElo]),
        [1],
      );
      inputs.add(opponentTensor);
      outputs = session.run(
        runOptions,
        {
          'tokens': tokenTensor,
          'self_elo': selfTensor,
          'opponent_elo': opponentTensor,
        },
        ['move_logits', if (request.includeValue) 'value_logits'],
      );
      Float32List flatten(ort.OrtValue? value) {
        final data = (value as ort.OrtValueTensor).value as List;
        return Float32List.fromList(
          (data.first as List).cast<num>().map((v) => v.toDouble()).toList(),
        );
      }

      final moves = flatten(outputs[0]);
      if (moves.length != DesktopMaiaRuntime.moveLogitCount) {
        throw StateError('Expected 4352 move logits, got ${moves.length}');
      }
      replies.send(
        _MaiaWorkerReply(
          id,
          TransferableTypedData.fromList([moves]),
          request.includeValue
              ? TransferableTypedData.fromList([flatten(outputs[1])])
              : null,
          null,
        ),
      );
    } catch (error) {
      replies.send(
        _MaiaWorkerReply(
          id,
          TransferableTypedData.fromList([Float32List(0)]),
          null,
          '$error',
        ),
      );
    } finally {
      for (final value in inputs) {
        value.release();
      }
      for (final value in outputs) {
        value?.release();
      }
    }
  }
  commands.close();
  runOptions.release();
  session.release();
  ort.OrtEnv.instance.release();
}
