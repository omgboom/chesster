part of '../../main.dart';

const dojoStartFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

enum DojoOpponentKind { maia, stockfish }

class DojoOpponent {
  const DojoOpponent({required this.kind, required this.elo, this.fullStrength = false});

  final DojoOpponentKind kind;
  final int elo;

  /// Stockfish only: ignore [elo] and play at full strength.
  final bool fullStrength;

  String get name => switch (kind) {
    DojoOpponentKind.maia => 'Maia',
    DojoOpponentKind.stockfish => 'Stockfish',
  };

  String get label => kind == DojoOpponentKind.stockfish && fullStrength
      ? 'Stockfish (max)'
      : '$name $elo';

  /// Nominal rating used to compare against your performance.
  int get nominalElo =>
      kind == DojoOpponentKind.stockfish && fullStrength ? 3500 : elo;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'elo': elo,
    'fullStrength': fullStrength,
  };

  static DojoOpponent fromJson(Object? json) {
    final map = json is Map ? json : const {};
    return DojoOpponent(
      kind: DojoOpponentKind.values.firstWhere(
        (k) => k.name == map['kind'],
        orElse: () => DojoOpponentKind.maia,
      ),
      elo: (map['elo'] as num?)?.toInt() ?? 1500,
      fullStrength: map['fullStrength'] == true,
    );
  }
}

/// Lichess-style move labels derived from win-probability loss.
enum MoveQuality {
  best('Best move', '!!'),
  excellent('Excellent', '!'),
  good('Good move', ''),
  inaccuracy('Inaccuracy', '?!'),
  mistake('Mistake', '?'),
  blunder('Blunder', '??');

  const MoveQuality(this.label, this.glyph);
  final String label;
  final String glyph;

  bool get isError => index >= MoveQuality.inaccuracy.index;

  Color color(ColorScheme scheme) => switch (this) {
    best => const Color(0xFF2E9E5B),
    excellent => const Color(0xFF4CAF50),
    good => const Color(0xFF7FA650),
    inaccuracy => const Color(0xFFE0A100),
    mistake => const Color(0xFFE07B00),
    blunder => const Color(0xFFD03030),
  };
}

/// Winning chances (0–100) for a centipawn score, as used by Lichess.
double winPercent(int cp) {
  final clamped = cp.clamp(-1000, 1000);
  return 50 + 50 * (2 / (1 + exp(-0.00368208 * clamped)) - 1);
}

/// Lichess per-move accuracy from the mover's win% before and after.
double moveAccuracy(double winBefore, double winAfter) {
  final drop = max(0.0, winBefore - winAfter);
  return (103.1668 * exp(-0.04354 * drop) - 3.1669).clamp(0.0, 100.0);
}

/// Rough performance rating from average centipawn loss.
int estimateEloFromAcpl(double acpl) =>
    (3100 * exp(-0.0105 * acpl)).clamp(400, 3200).round();

/// Stockfish's verdict on one move.
class MoveVerdict {
  const MoveVerdict({
    required this.quality,
    required this.playedUci,
    required this.playedSan,
    required this.bestUci,
    required this.bestSan,
    required this.scoreBefore,
    required this.scoreAfter,
    this.alternativeSan,
    this.whiteEvalAfter,
  });

  final MoveQuality quality;
  final String playedUci;
  final String playedSan;
  final String? bestUci;
  final String? bestSan;

  /// Best achievable score for the mover before moving (centipawns, mover's view).
  final int scoreBefore;

  /// Score after the played move (centipawns, mover's view).
  final int scoreAfter;

  /// Another strong move worth knowing about.
  final String? alternativeSan;
  final String? whiteEvalAfter;

  int get centipawnLoss =>
      max(0, scoreBefore.clamp(-1000, 1000) - scoreAfter.clamp(-1000, 1000));

  double get accuracy => moveAccuracy(winPercent(scoreBefore), winPercent(scoreAfter));

  bool get playedBest => bestUci == null || bestUci == playedUci;

  /// "Good move, but Nxc6 is better" style headline.
  String get headline {
    final best = bestSan;
    switch (quality) {
      case MoveQuality.best:
        return alternativeSan == null
            ? 'Best move!'
            : 'Best move! $alternativeSan was also good';
      case MoveQuality.excellent:
      case MoveQuality.good:
        if (playedBest || best == null) {
          return alternativeSan == null
              ? quality.label
              : '${quality.label} — another option was $alternativeSan';
        }
        return '${quality.label}, but $best is better';
      case MoveQuality.inaccuracy:
      case MoveQuality.mistake:
      case MoveQuality.blunder:
        return best == null ? quality.label : '${quality.label} — best was $best';
    }
  }

  String get scoreLine {
    String fmt(int cp) {
      if (cp.abs() >= 9000) {
        final moves = ((10000 - cp.abs()) / 10).round();
        return cp > 0 ? 'M$moves' : '−M$moves';
      }
      final p = (cp / 100).toStringAsFixed(1);
      return cp > 0 ? '+$p' : p.replaceFirst('-', '−');
    }

    final loss = centipawnLoss;
    return 'Eval for you: ${fmt(scoreBefore)} → ${fmt(scoreAfter)}'
        '${loss > 0 ? ' (−${(loss / 100).toStringAsFixed(1)})' : ''}'
        ' · accuracy ${accuracy.round()}%';
  }

  static MoveQuality classify(int before, int after, {required bool best}) {
    final drop = winPercent(before) - winPercent(after);
    if (best || drop <= 0.5) return MoveQuality.best;
    if (drop < 2) return MoveQuality.excellent;
    if (drop < 5) return MoveQuality.good;
    if (drop < 10) return MoveQuality.inaccuracy;
    if (drop < 20) return MoveQuality.mistake;
    return MoveQuality.blunder;
  }

  Map<String, Object?> toJson() => {
    'quality': quality.name,
    'playedUci': playedUci,
    'playedSan': playedSan,
    'bestUci': bestUci,
    'bestSan': bestSan,
    'scoreBefore': scoreBefore,
    'scoreAfter': scoreAfter,
    'alternativeSan': alternativeSan,
    'whiteEvalAfter': whiteEvalAfter,
  };

  static MoveVerdict? fromJson(Object? json) {
    if (json is! Map) return null;
    return MoveVerdict(
      quality: MoveQuality.values.firstWhere(
        (q) => q.name == json['quality'],
        orElse: () => MoveQuality.good,
      ),
      playedUci: json['playedUci'] as String,
      playedSan: json['playedSan'] as String,
      bestUci: json['bestUci'] as String?,
      bestSan: json['bestSan'] as String?,
      scoreBefore: (json['scoreBefore'] as num).toInt(),
      scoreAfter: (json['scoreAfter'] as num).toInt(),
      alternativeSan: json['alternativeSan'] as String?,
      whiteEvalAfter: json['whiteEvalAfter'] as String?,
    );
  }
}

/// Chess helpers built on dartchess.
abstract final class DojoChess {
  static dc.Position position(String fen) =>
      dc.Chess.fromSetup(dc.Setup.parseFen(fen));

  static String? sanOf(String fen, String uci) {
    try {
      final pos = position(fen);
      final move = dc.Move.parse(uci);
      if (move == null || !pos.isLegal(move)) return null;
      return pos.makeSan(move).$2;
    } catch (_) {
      return null;
    }
  }

  /// Accepts SAN or UCI. Returns (uci, san, fenAfter) or null if illegal.
  static ({String uci, String san, String fen})? play(String fen, String move) {
    try {
      final pos = position(fen);
      var parsed = pos.parseSan(move.trim());
      if (parsed == null) {
        final uciMove = dc.Move.parse(move.trim());
        if (uciMove != null && pos.isLegal(uciMove)) parsed = uciMove;
      }
      if (parsed == null) return null;
      final (next, san) = pos.makeSan(parsed);
      return (uci: parsed.uci, san: san, fen: next.fen);
    } catch (_) {
      return null;
    }
  }

  /// Converts a UCI principal variation into SAN with move numbers.
  static String pvToSan(String fen, List<String> pv, {int maxMoves = 8}) {
    final buffer = StringBuffer();
    try {
      var pos = position(fen);
      for (final (index, uci) in pv.take(maxMoves).indexed) {
        final move = dc.Move.parse(uci);
        if (move == null || !pos.isLegal(move)) break;
        final white = pos.turn == dc.Side.white;
        if (white) {
          buffer.write('${pos.fullmoves}. ');
        } else if (index == 0) {
          buffer.write('${pos.fullmoves}... ');
        }
        final (next, san) = pos.makeSan(move);
        buffer.write('$san ');
        pos = next;
      }
    } catch (_) {}
    return buffer.toString().trim();
  }

  static List<String> legalSans(String fen) {
    final pos = position(fen);
    final result = <String>[];
    for (final entry in pos.legalMoves.entries) {
      for (final to in entry.value.squares) {
        final piece = pos.board.pieceAt(entry.key);
        final isPromotion = piece?.role == dc.Role.pawn &&
            (to.rank == dc.Rank.first || to.rank == dc.Rank.eighth);
        if (isPromotion) {
          for (final role in [dc.Role.queen, dc.Role.rook, dc.Role.bishop, dc.Role.knight]) {
            result.add(pos.makeSan(dc.NormalMove(from: entry.key, to: to, promotion: role)).$2);
          }
        } else {
          final move = dc.NormalMove(from: entry.key, to: to);
          if (pos.isLegal(move)) result.add(pos.makeSan(move).$2);
        }
      }
    }
    return result;
  }

  /// Plain-text diagram (White at the bottom) for the language model.
  static String asciiBoard(String fen) {
    final pos = position(fen);
    final buffer = StringBuffer();
    for (var rank = 7; rank >= 0; rank--) {
      buffer.write('${rank + 1} ');
      for (var file = 0; file < 8; file++) {
        final square = dc.Square.fromCoords(dc.File(file), dc.Rank(rank));
        final piece = pos.board.pieceAt(square);
        buffer.write(piece == null ? '. ' : '${piece.fenChar} ');
      }
      buffer.writeln();
    }
    buffer.write('  a b c d e f g h');
    return buffer.toString();
  }

  /// Material balance in pawns from White's view (P1 N3 B3 R5 Q9).
  static int materialBalance(String fen) {
    final board = fen.split(' ').first;
    const values = {'p': 1, 'n': 3, 'b': 3, 'r': 5, 'q': 9};
    var total = 0;
    for (final char in board.split('')) {
      final value = values[char.toLowerCase()];
      if (value == null) continue;
      total += char == char.toUpperCase() ? value : -value;
    }
    return total;
  }
}

/// One position in the game tree.
class DojoNode {
  DojoNode({
    required this.id,
    required this.fen,
    this.parentId,
    this.uci,
    this.san,
    List<int>? children,
    this.analysis,
    this.verdict,
    this.byPlayer = false,
  }) : children = children ?? [];

  final int id;
  final int? parentId;
  final String fen;
  final String? uci;
  final String? san;
  final List<int> children;

  /// Engine analysis of this position (side to move = whoever moves next).
  EngineAnalysis? analysis;

  /// Verdict on the move that led here (player moves only).
  MoveVerdict? verdict;
  final bool byPlayer;

  /// Child to follow when stepping forward.
  int? preferredChild;

  dc.Side get turn => fen.split(' ').elementAtOrNull(1) == 'b' ? dc.Side.black : dc.Side.white;

  int get fullmove => int.tryParse(fen.split(' ').elementAtOrNull(5) ?? '') ?? 1;

  Map<String, Object?> toJson() => {
    'id': id,
    'parentId': parentId,
    'fen': fen,
    'uci': uci,
    'san': san,
    'children': children,
    'byPlayer': byPlayer,
    'preferredChild': preferredChild,
    if (analysis != null) 'analysis': analysis!.toJson(),
    if (verdict != null) 'verdict': verdict!.toJson(),
  };

  static DojoNode fromJson(Map<String, Object?> json) => DojoNode(
    id: (json['id'] as num).toInt(),
    parentId: (json['parentId'] as num?)?.toInt(),
    fen: json['fen'] as String,
    uci: json['uci'] as String?,
    san: json['san'] as String?,
    children: [for (final c in (json['children'] as List? ?? const [])) (c as num).toInt()],
    analysis: EngineAnalysis.fromJson(json['analysis']),
    verdict: MoveVerdict.fromJson(json['verdict']),
    byPlayer: json['byPlayer'] == true,
  )..preferredChild = (json['preferredChild'] as num?)?.toInt();
}

/// A visible chat message plus the raw API transcript needed to continue it.
class DojoChatEntry {
  DojoChatEntry({
    required this.role,
    required this.text,
    DateTime? time,
    this.nodeId,
    this.kind = 'chat',
    this.toolNotes = const [],
  }) : time = time ?? DateTime.now();

  final String role; // 'user' | 'assistant' | 'error'
  String text;
  final DateTime time;
  final int? nodeId;
  final String kind; // chat | explain | review | progress
  List<String> toolNotes;

  Map<String, Object?> toJson() => {
    'role': role,
    'text': text,
    'time': time.toIso8601String(),
    'nodeId': nodeId,
    'kind': kind,
    if (toolNotes.isNotEmpty) 'tools': toolNotes,
  };

  static DojoChatEntry fromJson(Map<String, Object?> json) => DojoChatEntry(
    role: json['role'] as String? ?? 'assistant',
    text: json['text'] as String? ?? '',
    time: DateTime.tryParse(json['time'] as String? ?? ''),
    nodeId: (json['nodeId'] as num?)?.toInt(),
    kind: json['kind'] as String? ?? 'chat',
    toolNotes: [for (final t in (json['tools'] as List? ?? const [])) '$t'],
  );
}

/// A conversation: what the user sees plus the exact API message history.
class DojoConversation {
  DojoConversation({List<DojoChatEntry>? entries, List<Map<String, Object?>>? apiMessages})
    : entries = entries ?? [],
      apiMessages = apiMessages ?? [];

  final List<DojoChatEntry> entries;
  final List<Map<String, Object?>> apiMessages;

  bool get isEmpty => entries.isEmpty;

  Map<String, Object?> toJson() => {
    'entries': [for (final e in entries) e.toJson()],
    'api': apiMessages,
  };

  static DojoConversation fromJson(Object? json) {
    if (json is! Map) return DojoConversation();
    return DojoConversation(
      entries: [
        for (final e in (json['entries'] as List? ?? const []))
          DojoChatEntry.fromJson((e as Map).cast<String, Object?>()),
      ],
      apiMessages: [
        for (final m in (json['api'] as List? ?? const []))
          (jsonDecode(jsonEncode(m)) as Map).cast<String, Object?>(),
      ],
    );
  }
}

/// Per-move row of the post-game report.
class PostGameMove {
  const PostGameMove({
    required this.ply,
    required this.san,
    required this.uci,
    required this.byPlayer,
    required this.fenBefore,
    required this.whiteEvalBefore,
    required this.whiteEvalAfter,
    required this.quality,
    required this.accuracy,
    required this.centipawnLoss,
    this.bestSan,
    this.bestLine,
  });

  final int ply;
  final String san;
  final String uci;
  final bool byPlayer;
  final String fenBefore;
  final int whiteEvalBefore;
  final int whiteEvalAfter;
  final MoveQuality quality;
  final double accuracy;
  final int centipawnLoss;
  final String? bestSan;
  final String? bestLine;

  String get moveLabel {
    final number = (ply + 1) ~/ 2;
    return ply.isOdd ? '$number. $san' : '$number... $san';
  }

  Map<String, Object?> toJson() => {
    'ply': ply,
    'san': san,
    'uci': uci,
    'byPlayer': byPlayer,
    'fenBefore': fenBefore,
    'evalBefore': whiteEvalBefore,
    'evalAfter': whiteEvalAfter,
    'quality': quality.name,
    'accuracy': accuracy,
    'cpl': centipawnLoss,
    'bestSan': bestSan,
    'bestLine': bestLine,
  };

  static PostGameMove fromJson(Map<String, Object?> json) => PostGameMove(
    ply: (json['ply'] as num).toInt(),
    san: json['san'] as String,
    uci: json['uci'] as String,
    byPlayer: json['byPlayer'] == true,
    fenBefore: json['fenBefore'] as String,
    whiteEvalBefore: (json['evalBefore'] as num).toInt(),
    whiteEvalAfter: (json['evalAfter'] as num).toInt(),
    quality: MoveQuality.values.firstWhere(
      (q) => q.name == json['quality'],
      orElse: () => MoveQuality.good,
    ),
    accuracy: (json['accuracy'] as num).toDouble(),
    centipawnLoss: (json['cpl'] as num).toInt(),
    bestSan: json['bestSan'] as String?,
    bestLine: json['bestLine'] as String?,
  );
}

class SideStats {
  const SideStats({
    required this.accuracy,
    required this.acpl,
    required this.counts,
    required this.estimatedElo,
  });

  final double accuracy;
  final double acpl;
  final Map<MoveQuality, int> counts;
  final int estimatedElo;

  static SideStats from(Iterable<PostGameMove> moves) {
    final list = moves.toList();
    if (list.isEmpty) {
      return const SideStats(accuracy: 0, acpl: 0, counts: {}, estimatedElo: 0);
    }
    final acpl = list.map((m) => min(m.centipawnLoss, 1000)).reduce((a, b) => a + b) / list.length;
    // Harmonic-leaning mean, so a single blunder matters like on Lichess.
    final mean = list.map((m) => m.accuracy).reduce((a, b) => a + b) / list.length;
    final harmonic = list.length /
        list.map((m) => 1 / max(m.accuracy, 1)).reduce((a, b) => a + b);
    return SideStats(
      accuracy: (mean + harmonic) / 2,
      acpl: acpl,
      counts: {
        for (final q in MoveQuality.values) q: list.where((m) => m.quality == q).length,
      },
      estimatedElo: estimateEloFromAcpl(acpl),
    );
  }

  Map<String, Object?> toJson() => {
    'accuracy': accuracy,
    'acpl': acpl,
    'counts': {for (final e in counts.entries) e.key.name: e.value},
    'estimatedElo': estimatedElo,
  };
}

class PostGameReport {
  PostGameReport({required this.moves, required this.analyzedAt, required this.movetimeMs});

  final List<PostGameMove> moves;
  final DateTime analyzedAt;
  final int movetimeMs;

  SideStats get player => SideStats.from(moves.where((m) => m.byPlayer));
  SideStats get opponent => SideStats.from(moves.where((m) => !m.byPlayer));

  Map<String, Object?> toJson() => {
    'analyzedAt': analyzedAt.toIso8601String(),
    'movetimeMs': movetimeMs,
    'moves': [for (final m in moves) m.toJson()],
    'player': player.toJson(),
    'opponent': opponent.toJson(),
  };

  static PostGameReport? fromJson(Object? json) {
    if (json is! Map) return null;
    return PostGameReport(
      analyzedAt: DateTime.tryParse(json['analyzedAt'] as String? ?? '') ?? DateTime.now(),
      movetimeMs: (json['movetimeMs'] as num?)?.toInt() ?? 0,
      moves: [
        for (final m in (json['moves'] as List? ?? const []))
          PostGameMove.fromJson((m as Map).cast<String, Object?>()),
      ],
    );
  }
}

/// A complete Dojo game: tree, result, guidance, chats and analysis.
class DojoGame {
  DojoGame({
    required this.id,
    required this.opponent,
    required this.playerIsWhite,
    required this.started,
    Map<int, DojoNode>? nodes,
    this.currentId = 0,
    this.result,
    this.resultReason,
    this.resultNodeId,
    this.finished,
    this.undoCount = 0,
    DojoConversation? coach,
    DojoConversation? review,
    this.postGame,
  }) : nodes = nodes ?? {0: DojoNode(id: 0, fen: dojoStartFen)},
       coach = coach ?? DojoConversation(),
       review = review ?? DojoConversation();

  factory DojoGame.create({required DojoOpponent opponent, required bool playerIsWhite}) {
    final now = DateTime.now();
    return DojoGame(
      id: 'g${now.millisecondsSinceEpoch}',
      opponent: opponent,
      playerIsWhite: playerIsWhite,
      started: now,
    );
  }

  final String id;
  final DojoOpponent opponent;
  final bool playerIsWhite;
  final DateTime started;
  final Map<int, DojoNode> nodes;
  int currentId;
  String? result; // 1-0, 0-1, 1/2-1/2
  String? resultReason;
  int? resultNodeId;
  DateTime? finished;
  int undoCount;
  final DojoConversation coach;
  final DojoConversation review;
  PostGameReport? postGame;

  DojoNode get root => nodes[0]!;
  DojoNode get current => nodes[currentId]!;
  bool get isFinished => result != null;
  dc.Side get playerSide => playerIsWhite ? dc.Side.white : dc.Side.black;

  /// Points for the player: 1, 0.5, 0, or null if unfinished.
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
    _ => 'In progress',
  };

  int _nextId() => nodes.keys.fold(0, max) + 1;

  /// Root → [id] inclusive.
  List<DojoNode> pathTo(int id) {
    final path = <DojoNode>[];
    DojoNode? node = nodes[id];
    while (node != null) {
      path.add(node);
      node = node.parentId == null ? null : nodes[node.parentId!];
    }
    return path.reversed.toList();
  }

  /// The path through [id] continued along preferred children to a leaf.
  List<DojoNode> lineThrough(int id) {
    final path = pathTo(id);
    var node = path.last;
    while (node.children.isNotEmpty) {
      node = nodes[node.preferredChild ?? node.children.first]!;
      path.add(node);
    }
    return path;
  }

  /// The line that decides the result (or the current line if unfinished).
  List<DojoNode> get finalLine => pathTo(resultNodeId ?? lineThrough(currentId).last.id);

  /// Adds (or reuses) the child of [parentId] reached by [uci].
  DojoNode addMove(int parentId, String uci, {required bool byPlayer}) {
    final parent = nodes[parentId]!;
    for (final childId in parent.children) {
      final child = nodes[childId]!;
      if (child.uci == uci) {
        parent.preferredChild = childId;
        return child;
      }
    }
    final played = DojoChess.play(parent.fen, uci);
    if (played == null) throw ArgumentError('Illegal move $uci');
    final node = DojoNode(
      id: _nextId(),
      parentId: parentId,
      fen: played.fen,
      uci: played.uci,
      san: played.san,
      byPlayer: byPlayer,
    );
    nodes[node.id] = node;
    parent.children.add(node.id);
    parent.preferredChild = node.id;
    return node;
  }

  /// Marks preferred children so stepping forward follows [id]'s line.
  void select(int id) {
    final path = pathTo(id);
    for (var i = 0; i < path.length - 1; i++) {
      path[i].preferredChild = path[i + 1].id;
    }
    currentId = id;
  }

  /// Natural game end (mate, stalemate, draws) for the line ending at [id].
  ({String result, String reason})? naturalOutcome(int id) {
    final node = nodes[id]!;
    final pos = DojoChess.position(node.fen);
    if (pos.isCheckmate) {
      return (result: pos.turn == dc.Side.white ? '0-1' : '1-0', reason: 'checkmate');
    }
    if (pos.isStalemate) return (result: '1/2-1/2', reason: 'stalemate');
    if (pos.isInsufficientMaterial) {
      return (result: '1/2-1/2', reason: 'insufficient material');
    }
    if (pos.halfmoves >= 100) return (result: '1/2-1/2', reason: '50-move rule');
    String key(String fen) => fen.split(' ').take(4).join(' ');
    final target = key(node.fen);
    final repeats = pathTo(id).where((n) => key(n.fen) == target).length;
    if (repeats >= 3) return (result: '1/2-1/2', reason: 'threefold repetition');
    return null;
  }

  void finish(String result, String reason, int nodeId) {
    this.result = result;
    resultReason = reason;
    resultNodeId = nodeId;
    finished = DateTime.now();
  }

  /// PGN with every explored branch as a variation.
  String toPgn() {
    final white = playerIsWhite ? 'You' : opponent.label;
    final black = playerIsWhite ? opponent.label : 'You';
    final date = started.toIso8601String().substring(0, 10).replaceAll('-', '.');
    final buffer = StringBuffer()
      ..writeln('[Event "Chesster Dojo"]')
      ..writeln('[Site "Chesster"]')
      ..writeln('[Date "$date"]')
      ..writeln('[White "$white"]')
      ..writeln('[Black "$black"]')
      ..writeln('[Result "${result ?? '*'}"]');
    if (resultReason != null) buffer.writeln('[Termination "$resultReason"]');
    buffer.writeln();
    final mainIds = {for (final n in finalLine) n.id};

    void writeLine(DojoNode from, bool forceNumber) {
      var node = from;
      var needNumber = forceNumber;
      while (true) {
        if (node.children.isEmpty) return;
        final ordered = [...node.children]
          ..sort((a, b) => (mainIds.contains(b) ? 1 : 0) - (mainIds.contains(a) ? 1 : 0));
        final main = nodes[ordered.first]!;
        final moveNumber = node.fullmove;
        if (node.turn == dc.Side.white) {
          buffer.write('$moveNumber. ');
        } else if (needNumber) {
          buffer.write('$moveNumber... ');
        }
        buffer.write('${main.san}${main.verdict?.quality.glyph ?? ''} ');
        needNumber = false;
        for (final alt in ordered.skip(1)) {
          final altNode = nodes[alt]!;
          buffer.write('(');
          buffer.write(node.turn == dc.Side.white ? '$moveNumber. ' : '$moveNumber... ');
          buffer.write('${altNode.san} ');
          writeLine(altNode, true);
          buffer.write(') ');
          needNumber = true;
        }
        node = main;
      }
    }

    writeLine(root, false);
    buffer.write(result ?? '*');
    return buffer.toString().replaceAll(' )', ')');
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'opponent': opponent.toJson(),
    'playerIsWhite': playerIsWhite,
    'started': started.toIso8601String(),
    'finished': finished?.toIso8601String(),
    'currentId': currentId,
    'result': result,
    'resultReason': resultReason,
    'resultNodeId': resultNodeId,
    'undoCount': undoCount,
    'nodes': [for (final n in nodes.values) n.toJson()],
    'coach': coach.toJson(),
    'review': review.toJson(),
    if (postGame != null) 'postGame': postGame!.toJson(),
    'pgn': toPgn(),
  };

  static DojoGame fromJson(Map<String, Object?> json) {
    final nodes = <int, DojoNode>{
      for (final n in (json['nodes'] as List))
        (n as Map)['id'] as int: DojoNode.fromJson(n.cast<String, Object?>()),
    };
    return DojoGame(
      id: json['id'] as String,
      opponent: DojoOpponent.fromJson(json['opponent']),
      playerIsWhite: json['playerIsWhite'] != false,
      started: DateTime.parse(json['started'] as String),
      finished: DateTime.tryParse(json['finished'] as String? ?? ''),
      nodes: nodes,
      currentId: (json['currentId'] as num?)?.toInt() ?? 0,
      result: json['result'] as String?,
      resultReason: json['resultReason'] as String?,
      resultNodeId: (json['resultNodeId'] as num?)?.toInt(),
      undoCount: (json['undoCount'] as num?)?.toInt() ?? 0,
      coach: DojoConversation.fromJson(json['coach']),
      review: DojoConversation.fromJson(json['review']),
      postGame: PostGameReport.fromJson(json['postGame']),
    );
  }
}
