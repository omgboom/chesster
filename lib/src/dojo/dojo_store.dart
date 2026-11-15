part of '../../main.dart';

/// Claude models offered in Settings (id, label).
const dojoClaudeModels = <(String, String)>[
  ('claude-haiku-5-5', 'Haiku 5.5 (fast, cheapest)'),
  ('claude-sonnet-5-5', 'Sonnet 5.5'),
  ('claude-opus-5-5', 'Opus 5.5'),
  ('claude-fable-5-2', 'Fable 5.2 (most capable)'),
];
const dojoEffortLevels = ['low', 'medium', 'high', 'xhigh', 'max'];

enum DojoAnalysisDepth {
  quick('Quick', 350),
  normal('Normal', 800),
  deep('Deep', 1800);

  const DojoAnalysisDepth(this.label, this.movetimeMs);
  final String label;
  final int movetimeMs;
}

/// Dojo preferences. The API key lives in secure storage.
class DojoSettings extends ChangeNotifier {
  DojoSettings._();
  static final instance = DojoSettings._();

  static const _guidanceKey = 'dojoGuidanceV1';
  static const _modelKey = 'dojoClaudeModelV1';
  static const _effortKey = 'dojoClaudeEffortV1';
  static const _opponentKey = 'dojoOpponentV1';
  static const _sideKey = 'dojoSideV1';
  static const _depthKey = 'dojoAnalysisDepthV1';
  static const _voiceAutoSendKey = 'dojoVoiceAutoSendV1';
  static const stockfishPathKey = 'dojoStockfishPathV1';
  static const _apiKeyName = 'dojoAnthropicApiKeyV1';

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  bool loaded = false;
  bool guidance = true;
  String model = 'claude-haiku-5-5';
  String effort = 'medium';
  DojoOpponent opponent = const DojoOpponent(kind: DojoOpponentKind.maia, elo: 1500);
  PlayerSide side = PlayerSide.white;
  DojoAnalysisDepth analysisDepth = DojoAnalysisDepth.normal;
  bool voiceAutoSend = false;
  String stockfishPath = '';
  String _apiKey = '';

  String get apiKey => _apiKey;
  bool get hasApiKey => _apiKey.trim().isNotEmpty;
  String get modelLabel =>
      dojoClaudeModels.firstWhere((m) => m.$1 == model, orElse: () => (model, model)).$2;

  Future<void> load() async {
    if (loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      guidance = prefs.getBool(_guidanceKey) ?? true;
      model = prefs.getString(_modelKey) ?? model;
      effort = prefs.getString(_effortKey) ?? effort;
      final opponentJson = prefs.getString(_opponentKey);
      if (opponentJson != null) opponent = DojoOpponent.fromJson(jsonDecode(opponentJson));
      side = PlayerSide.values.firstWhere(
        (s) => s.name == prefs.getString(_sideKey),
        orElse: () => PlayerSide.white,
      );
      analysisDepth = DojoAnalysisDepth.values.firstWhere(
        (d) => d.name == prefs.getString(_depthKey),
        orElse: () => DojoAnalysisDepth.normal,
      );
      voiceAutoSend = prefs.getBool(_voiceAutoSendKey) ?? false;
      stockfishPath = prefs.getString(stockfishPathKey) ?? '';
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-settings-load', error, stackTrace));
    }
    try {
      _apiKey = await _secure.read(key: _apiKeyName) ?? '';
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-api-key-read', error, stackTrace));
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _save(Future<void> Function(SharedPreferences prefs) write) async {
    notifyListeners();
    try {
      await write(await SharedPreferences.getInstance());
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-settings-save', error, stackTrace));
    }
  }

  Future<void> setGuidance(bool value) {
    guidance = value;
    return _save((p) => p.setBool(_guidanceKey, value));
  }

  Future<void> setModel(String value) {
    model = value;
    return _save((p) => p.setString(_modelKey, value));
  }

  Future<void> setEffort(String value) {
    effort = value;
    return _save((p) => p.setString(_effortKey, value));
  }

  Future<void> setOpponent(DojoOpponent value) {
    opponent = value;
    return _save((p) => p.setString(_opponentKey, jsonEncode(value.toJson())));
  }

  Future<void> setSide(PlayerSide value) {
    side = value;
    return _save((p) => p.setString(_sideKey, value.name));
  }

  Future<void> setAnalysisDepth(DojoAnalysisDepth value) {
    analysisDepth = value;
    return _save((p) => p.setString(_depthKey, value.name));
  }

  Future<void> setVoiceAutoSend(bool value) {
    voiceAutoSend = value;
    return _save((p) => p.setBool(_voiceAutoSendKey, value));
  }

  Future<void> setStockfishPath(String value) {
    stockfishPath = value.trim();
    return _save((p) => p.setString(stockfishPathKey, stockfishPath));
  }

  Future<void> setApiKey(String value) async {
    _apiKey = value.trim();
    notifyListeners();
    try {
      if (_apiKey.isEmpty) {
        await _secure.delete(key: _apiKeyName);
      } else {
        await _secure.write(key: _apiKeyName, value: _apiKey);
      }
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-api-key-write', error, stackTrace));
    }
  }
}

/// Lightweight summary of a stored game for lists and progress charts.
class DojoGameSummary {
  const DojoGameSummary({
    required this.id,
    required this.started,
    required this.opponent,
    required this.playerIsWhite,
    required this.result,
    required this.moveCount,
    required this.undoCount,
    this.resultReason,
    this.playerAccuracy,
    this.playerElo,
    this.playerAcpl,
    this.opponentAccuracy,
    this.blunders,
    this.mistakes,
    this.inaccuracies,
    this.hasAiReview = false,
  });

  final String id;
  final DateTime started;
  final DojoOpponent opponent;
  final bool playerIsWhite;
  final String? result;
  final String? resultReason;
  final int moveCount;
  final int undoCount;
  final double? playerAccuracy;
  final int? playerElo;
  final double? playerAcpl;
  final double? opponentAccuracy;
  final int? blunders;
  final int? mistakes;
  final int? inaccuracies;
  final bool hasAiReview;

  double? get playerScore => switch (result) {
    '1-0' => playerIsWhite ? 1 : 0,
    '0-1' => playerIsWhite ? 0 : 1,
    '1/2-1/2' => 0.5,
    _ => null,
  };

  String get outcomeLabel => switch (playerScore) {
    1 => 'Won',
    0 => 'Lost',
    0.5 => 'Draw',
    _ => 'Unfinished',
  };

  static DojoGameSummary of(DojoGame game) {
    final report = game.postGame;
    final player = report?.player;
    return DojoGameSummary(
      id: game.id,
      started: game.started,
      opponent: game.opponent,
      playerIsWhite: game.playerIsWhite,
      result: game.result,
      resultReason: game.resultReason,
      moveCount: (game.finalLine.length - 1 + 1) ~/ 2,
      undoCount: game.undoCount,
      playerAccuracy: player?.accuracy,
      playerElo: player?.estimatedElo,
      playerAcpl: player?.acpl,
      opponentAccuracy: report?.opponent.accuracy,
      blunders: player?.counts[MoveQuality.blunder],
      mistakes: player?.counts[MoveQuality.mistake],
      inaccuracies: player?.counts[MoveQuality.inaccuracy],
      hasAiReview: !game.review.isEmpty,
    );
  }

  /// Compact line for the progress coach.
  String describe() {
    final date = started.toIso8601String().substring(0, 10);
    final parts = [
      'id=$id',
      date,
      'vs ${opponent.label}',
      'as ${playerIsWhite ? 'White' : 'Black'}',
      outcomeLabel + (resultReason == null ? '' : ' ($resultReason)'),
      '$moveCount moves',
      if (undoCount > 0) '$undoCount undos',
      if (playerAccuracy != null) 'accuracy ${playerAccuracy!.round()}%',
      if (playerAcpl != null) 'ACPL ${playerAcpl!.round()}',
      if (playerElo != null) 'perf ~$playerElo',
      if (blunders != null) 'blunders $blunders, mistakes $mistakes, inaccuracies $inaccuracies',
    ];
    return parts.join(', ');
  }
}

/// JSON files under the app support directory: one file per game plus the
/// progress coach conversation.
class DojoStore {
  DojoStore._();
  static final instance = DojoStore._();

  Directory? _root;

  @visibleForTesting
  static Directory? overrideRoot;

  Future<Directory> root() async {
    if (overrideRoot != null) return overrideRoot!;
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}dojo');
    await Directory('${dir.path}${Platform.pathSeparator}games').create(recursive: true);
    return _root = dir;
  }

  Future<File> _gameFile(String id) async {
    final dir = await root();
    return File('${dir.path}${Platform.pathSeparator}games${Platform.pathSeparator}$id.json');
  }

  Future<void> save(DojoGame game) async {
    try {
      game.updated = DateTime.now().toUtc();
      final file = await _gameFile(game.id);
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(game.toJson()));
      await tmp.rename(file.path);
      DojoSync.instance.noteGameSaved(game);
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-save', error, stackTrace));
    }
  }

  Future<DojoGame?> load(String id) async {
    try {
      final file = await _gameFile(id);
      if (!await file.exists()) return null;
      return DojoGame.fromJson((jsonDecode(await file.readAsString()) as Map).cast());
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-load', error, stackTrace));
      return null;
    }
  }

  Future<void> delete(String id) async {
    final file = await _gameFile(id);
    if (await file.exists()) await file.delete();
    await DojoSync.instance.noteGameDeleted(id);
  }

  /// All games, newest first.
  Future<List<DojoGame>> loadAll() async {
    final dir = Directory('${(await root()).path}${Platform.pathSeparator}games');
    if (!await dir.exists()) return [];
    final games = <DojoGame>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        games.add(DojoGame.fromJson((jsonDecode(await entity.readAsString()) as Map).cast()));
      } catch (error, stackTrace) {
        unawaited(AppDiagnostics.record('dojo-load-all', error, stackTrace));
      }
    }
    games.sort((a, b) => b.started.compareTo(a.started));
    return games;
  }

  Future<String> gamesFolder() async =>
      '${(await root()).path}${Platform.pathSeparator}games';

  Future<File> _progressFile() async =>
      File('${(await root()).path}${Platform.pathSeparator}progress_chat.json');

  Future<DojoConversation> loadProgressChat() async {
    try {
      final file = await _progressFile();
      if (!await file.exists()) return DojoConversation();
      return DojoConversation.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return DojoConversation();
    }
  }

  Future<void> saveProgressChat(DojoConversation conversation) async {
    try {
      final file = await _progressFile();
      await file.writeAsString(const JsonEncoder.withIndent(' ').convert({
        ...conversation.toJson(),
        'updated': DateTime.now().toUtc().toIso8601String(),
      }));
      DojoSync.instance.noteLocalChange();
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-progress-save', error, stackTrace));
    }
  }
}
