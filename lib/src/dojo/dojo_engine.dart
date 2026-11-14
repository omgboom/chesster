part of '../../main.dart';

/// Minimum and maximum strengths Stockfish exposes through `UCI_Elo`.
const dojoStockfishMinElo = 1320;
const dojoStockfishMaxElo = 3190;

/// One principal variation from a Stockfish search. Scores are from the
/// perspective of the side to move in the analysed position.
class EngineLine {
  const EngineLine({required this.pv, this.cp, this.mate, this.depth = 0});

  final List<String> pv;
  final int? cp;
  final int? mate;
  final int depth;

  String? get move => pv.isEmpty ? null : pv.first;

  /// Centipawns for the side to move; mates map to ±(10000 − distance).
  int get score {
    if (mate != null) {
      if (mate == 0) return -10000;
      return mate! > 0 ? 10000 - mate! * 10 : -10000 - mate! * 10;
    }
    return cp ?? 0;
  }

  Map<String, Object?> toJson() => {
    'pv': pv,
    if (cp != null) 'cp': cp,
    if (mate != null) 'mate': mate,
    'depth': depth,
  };

  static EngineLine fromJson(Map<String, Object?> json) => EngineLine(
    pv: [for (final m in (json['pv'] as List? ?? const [])) m as String],
    cp: (json['cp'] as num?)?.toInt(),
    mate: (json['mate'] as num?)?.toInt(),
    depth: (json['depth'] as num?)?.toInt() ?? 0,
  );
}

/// Result of analysing one position.
class EngineAnalysis {
  const EngineAnalysis({required this.fen, required this.lines});

  final String fen;
  final List<EngineLine> lines;

  bool get whiteToMove => fen.split(' ').elementAtOrNull(1) != 'b';
  String? get bestMove => lines.firstOrNull?.move;
  int get depth => lines.firstOrNull?.depth ?? 0;

  /// Best score for the side to move.
  int get score => lines.firstOrNull?.score ?? 0;

  /// Best score from White's point of view.
  int get whiteScore => whiteToMove ? score : -score;

  int? get whiteMate {
    final mate = lines.firstOrNull?.mate;
    if (mate == null) return null;
    return whiteToMove ? mate : -mate;
  }

  Map<String, Object?> toJson() => {
    'fen': fen,
    'lines': [for (final line in lines) line.toJson()],
  };

  static EngineAnalysis? fromJson(Object? json) {
    if (json is! Map) return null;
    return EngineAnalysis(
      fen: json['fen'] as String,
      lines: [
        for (final line in (json['lines'] as List? ?? const []))
          EngineLine.fromJson((line as Map).cast<String, Object?>()),
      ],
    );
  }
}

/// Human-readable evaluation from White's perspective, e.g. "+1.3" or "M4".
String formatWhiteEval(int whiteScore, {int? whiteMate}) {
  if (whiteMate != null) {
    if (whiteMate == 0) return whiteScore > 0 ? '1-0' : '0-1';
    return whiteMate > 0 ? 'M$whiteMate' : '-M${whiteMate.abs()}';
  }
  final pawns = whiteScore / 100;
  final text = pawns.abs().toStringAsFixed(1);
  if (text == '0.0') return '0.0';
  return pawns > 0 ? '+$text' : '−$text';
}

/// UCI wrapper used by the Dojo for both opponent moves and analysis.
///
/// Work is serialised: one search at a time. On Android the native engine is
/// a process-wide singleton, so the classic [StockfishAnalyzer] is closed
/// before this engine starts.
class DojoEngine {
  DojoEngine({Future<StockfishEngineHandle> Function()? factory})
    : _factory = factory ?? createPlatformStockfishHandle;

  static DojoEngine _instance = DojoEngine();
  static DojoEngine get instance => _instance;

  @visibleForTesting
  static set instance(DojoEngine engine) => _instance = engine;

  final Future<StockfishEngineHandle> Function() _factory;
  StockfishEngineHandle? _handle;
  StreamSubscription<String>? _subscription;
  final _output = StreamController<String>.broadcast();
  Future<void>? _startup;
  Future<void> _tail = Future<void>.value();
  int _threads = 2;

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final result = Completer<T>();
    _tail = _tail.catchError((_) {}).then((_) async {
      try {
        result.complete(await job());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<void> _ensureStarted() => _startup ??= _start().catchError((
    Object error,
    StackTrace stackTrace,
  ) {
    _startup = null;
    throw error;
  });

  Future<void> _start() async {
    try {
      await StockfishAnalyzer.instance.close();
    } catch (_) {}
    final handle = await _factory();
    _handle = handle;
    _subscription = handle.stdout.listen(
      (chunk) {
        for (final line in const LineSplitter().convert(chunk)) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) _output.add(trimmed);
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          AppDiagnostics.record('dojo-engine-stdout', error, stackTrace),
    );
    _threads = isDesktopPlatform
        ? max(1, min(4, Platform.numberOfProcessors - 1))
        : 2;
    final ready = _output.stream.firstWhere((line) => line == 'readyok');
    handle.stdin = 'uci';
    handle.stdin = 'setoption name Threads value $_threads';
    handle.stdin = 'setoption name Hash value ${isDesktopPlatform ? 128 : 64}';
    handle.stdin = 'isready';
    await ready.timeout(const Duration(seconds: 15));
  }

  void _send(String command) {
    final handle = _handle;
    if (handle == null) throw StateError('Stockfish is not running');
    handle.stdin = command;
  }

  Future<void> _sync() async {
    final ready = _output.stream.firstWhere((line) => line == 'readyok');
    _send('isready');
    await ready.timeout(const Duration(seconds: 10));
  }

  /// Runs one search and returns the final principal variations.
  Future<({List<EngineLine> lines, String? bestMove})> _search(
    String fen, {
    required int multiPv,
    required int movetimeMs,
    int? depth,
    int? limitElo,
  }) async {
    await _ensureStarted();
    _send('setoption name MultiPV value $multiPv');
    if (limitElo != null) {
      _send('setoption name UCI_LimitStrength value true');
      _send(
        'setoption name UCI_Elo value '
        '${limitElo.clamp(dojoStockfishMinElo, dojoStockfishMaxElo)}',
      );
    } else {
      _send('setoption name UCI_LimitStrength value false');
    }
    _send('position fen $fen');
    await _sync();
    final lines = <int, EngineLine>{};
    final done = Completer<String?>();
    final subscription = _output.stream.listen((line) {
      if (line.startsWith('info ') && line.contains(' pv ')) {
        final parsed = _parseInfo(line);
        if (parsed != null) lines[parsed.$1] = parsed.$2;
      } else if (line.startsWith('bestmove')) {
        final parts = line.split(' ');
        final move = parts.length > 1 ? parts[1] : null;
        if (!done.isCompleted) {
          done.complete(move == '(none)' ? null : move);
        }
      }
    });
    try {
      _send(depth == null ? 'go movetime $movetimeMs' : 'go depth $depth movetime $movetimeMs');
      final best = await done.future.timeout(
        Duration(milliseconds: movetimeMs + 15000),
        onTimeout: () {
          _send('stop');
          return null;
        },
      );
      final ordered = [
        for (final key in lines.keys.toList()..sort()) lines[key]!,
      ];
      return (lines: ordered, bestMove: best);
    } finally {
      await subscription.cancel();
    }
  }

  static (int, EngineLine)? _parseInfo(String line) {
    final tokens = line.split(' ');
    var multipv = 1;
    int? cp;
    int? mate;
    var depth = 0;
    List<String>? pv;
    for (var i = 0; i < tokens.length; i++) {
      switch (tokens[i]) {
        case 'depth':
          depth = int.tryParse(tokens.elementAtOrNull(i + 1) ?? '') ?? depth;
        case 'multipv':
          multipv = int.tryParse(tokens.elementAtOrNull(i + 1) ?? '') ?? 1;
        case 'score':
          final kind = tokens.elementAtOrNull(i + 1);
          final value = int.tryParse(tokens.elementAtOrNull(i + 2) ?? '');
          if (kind == 'cp') cp = value;
          if (kind == 'mate') mate = value;
        case 'lowerbound' || 'upperbound':
          return null;
        case 'pv':
          pv = tokens.sublist(i + 1);
          i = tokens.length;
      }
    }
    if (pv == null || pv.isEmpty || (cp == null && mate == null)) return null;
    return (multipv, EngineLine(pv: pv, cp: cp, mate: mate, depth: depth));
  }

  /// Full-strength analysis with [multiPv] lines.
  Future<EngineAnalysis> analyze(
    String fen, {
    int multiPv = 3,
    int movetimeMs = 700,
    int? depth,
  }) => _enqueue(() async {
    final position = dc.Chess.fromSetup(dc.Setup.parseFen(fen));
    if (position.isGameOver) {
      final mated = position.isCheckmate;
      return EngineAnalysis(
        fen: fen,
        lines: [EngineLine(pv: const [], cp: mated ? null : 0, mate: mated ? 0 : null)],
      );
    }
    final result = await _search(
      fen,
      multiPv: multiPv,
      movetimeMs: movetimeMs,
      depth: depth,
    );
    var lines = result.lines;
    if (lines.isEmpty && result.bestMove != null) {
      lines = [EngineLine(pv: [result.bestMove!], cp: 0)];
    }
    return EngineAnalysis(fen: fen, lines: lines);
  });

  /// Chooses a move for Stockfish as the opponent. A null [elo] plays at full
  /// strength.
  Future<String?> chooseMove(String fen, {int? elo, int movetimeMs = 800}) =>
      _enqueue(() async {
        final result = await _search(
          fen,
          multiPv: 1,
          movetimeMs: movetimeMs,
          limitElo: elo,
        );
        return result.bestMove;
      });

  Future<void> close() async {
    final startup = _startup;
    _startup = null;
    if (startup == null) return;
    try {
      await startup;
    } catch (_) {}
    final handle = _handle;
    _handle = null;
    await _subscription?.cancel();
    _subscription = null;
    if (handle != null) {
      try {
        await handle.dispose().timeout(const Duration(seconds: 6));
      } catch (error, stackTrace) {
        unawaited(AppDiagnostics.record('dojo-engine-close', error, stackTrace));
      }
    }
  }
}
