part of '../../main.dart';

/// Events streamed to the chat UI while Claude answers.
sealed class CoachEvent {
  const CoachEvent();
}

class CoachTextDelta extends CoachEvent {
  const CoachTextDelta(this.text);
  final String text;
}

class CoachToolNote extends CoachEvent {
  const CoachToolNote(this.note);
  final String note;
}

class CoachDone extends CoachEvent {
  const CoachDone(this.text, {this.truncated = false});
  final String text;
  final bool truncated;
}

class CoachError extends CoachEvent {
  const CoachError(this.message);
  final String message;
}

/// A client-side tool Claude can call. [run] returns the tool_result text.
class ClaudeTool {
  const ClaudeTool({
    required this.name,
    required this.description,
    required this.schema,
    required this.run,
    required this.describe,
  });

  final String name;
  final String description;
  final Map<String, Object?> schema;
  final Future<String> Function(Map<String, Object?> input) run;

  /// Short status line for the UI, e.g. "Stockfish: analysing position".
  final String Function(Map<String, Object?> input) describe;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'input_schema': schema,
    'eager_input_streaming': true,
  };
}

class ClaudeApiException implements Exception {
  ClaudeApiException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => 'Claude API error $status: $message';
}

/// Minimal Messages API client (raw HTTPS; there is no official Dart SDK).
/// Streams SSE, runs a client-side tool loop, and appends every assistant
/// turn to the caller's message list unchanged (thinking blocks included).
class ClaudeClient {
  ClaudeClient({
    required this.apiKey,
    required this.model,
    required this.effort,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  factory ClaudeClient.fromSettings([DojoSettings? settings]) {
    final s = settings ?? DojoSettings.instance;
    return ClaudeClient(apiKey: s.apiKey, model: s.model, effort: s.effort);
  }

  static const endpoint = 'https://api.anthropic.com/v1/messages';
  static const apiVersion = '2026-10-21';
  static const _fallbackBeta = 'server-side-fallback-2026-07-01';

  final String apiKey;
  final String model;
  final String effort;
  final http.Client _http;

  bool get _alwaysThinks => model.startsWith('claude-fable') || model.startsWith('claude-mythos');
  bool get _supportsFallbacks =>
      model.startsWith('claude-fable') ||
      model.startsWith('claude-opus-5') ||
      model == 'claude-sonnet-5-5';

  Map<String, Object?> _body({
    required String system,
    required List<Map<String, Object?>> messages,
    required List<ClaudeTool> tools,
    required int maxTokens,
  }) => {
    'model': model,
    'max_tokens': maxTokens,
    'stream': true,
    'system': [
      {'type': 'text', 'text': system},
    ],
    'messages': messages,
    if (tools.isNotEmpty) 'tools': [for (final t in tools) t.toJson()],
    if (!_alwaysThinks) 'thinking': {'type': 'adaptive'},
    'output_config': {'effort': effort},
    'cache_control': {'type': 'ephemeral'},
    if (_supportsFallbacks) 'fallbacks': 'default',
  };

  /// Sends one request and returns the assistant content and stop reason.
  Future<({List<Map<String, Object?>> content, String? stopReason, String? refusal})> _stream(
    Map<String, Object?> body,
    void Function(String delta) onText,
  ) async {
    var attempt = 0;
    while (true) {
      attempt++;
      final request = http.Request('POST', Uri.parse(endpoint))
        ..headers.addAll({
          'content-type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': apiVersion,
          if (_supportsFallbacks) 'anthropic-beta': _fallbackBeta,
        })
        ..body = jsonEncode(body);
      final response = await _http.send(request).timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        var message = text;
        try {
          message = ((jsonDecode(text) as Map)['error'] as Map)['message'] as String;
        } catch (_) {}
        final retryable = response.statusCode == 429 ||
            response.statusCode == 529 ||
            response.statusCode >= 500;
        if (retryable && attempt < 3) {
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
          continue;
        }
        throw ClaudeApiException(response.statusCode, message);
      }
      return _readEvents(response.stream, onText);
    }
  }

  Future<({List<Map<String, Object?>> content, String? stopReason, String? refusal})> _readEvents(
    Stream<List<int>> bytes,
    void Function(String delta) onText,
  ) async {
    final blocks = <int, Map<String, Object?>>{};
    final jsonBuffers = <int, StringBuffer>{};
    String? stopReason;
    String? refusal;
    await for (final line in bytes
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(const Duration(seconds: 90))) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      final Map<String, Object?> event;
      try {
        event = (jsonDecode(payload) as Map).cast<String, Object?>();
      } catch (_) {
        continue;
      }
      switch (event['type']) {
        case 'content_block_start':
          final index = (event['index'] as num).toInt();
          final block = Map<String, Object?>.from(event['content_block'] as Map);
          blocks[index] = block;
          if (block['type'] == 'tool_use') jsonBuffers[index] = StringBuffer();
        case 'content_block_delta':
          final index = (event['index'] as num).toInt();
          final block = blocks[index];
          final delta = (event['delta'] as Map).cast<String, Object?>();
          if (block == null) break;
          switch (delta['type']) {
            case 'text_delta':
              final text = delta['text'] as String? ?? '';
              block['text'] = '${block['text'] ?? ''}$text';
              onText(text);
            case 'thinking_delta':
              block['thinking'] = '${block['thinking'] ?? ''}${delta['thinking'] ?? ''}';
            case 'signature_delta':
              block['signature'] = '${block['signature'] ?? ''}${delta['signature'] ?? ''}';
            case 'input_json_delta':
              jsonBuffers[index]?.write(delta['partial_json'] ?? '');
            case 'citations_delta':
              final citations = (block['citations'] as List?) ?? <Object?>[];
              block['citations'] = [...citations, delta['citation']];
          }
        case 'content_block_stop':
          final index = (event['index'] as num).toInt();
          final buffer = jsonBuffers.remove(index);
          if (buffer != null) {
            final raw = buffer.toString().trim();
            Object? input;
            try {
              input = raw.isEmpty ? <String, Object?>{} : jsonDecode(raw);
            } on FormatException {
              input = null;
            }
            blocks[index]!['input'] = input is Map ? input : <String, Object?>{};
            if (input is! Map) blocks[index]!['_invalid'] = true;
          }
        case 'message_delta':
          final delta = (event['delta'] as Map?)?.cast<String, Object?>();
          stopReason = delta?['stop_reason'] as String? ?? stopReason;
          final details = delta?['stop_details'];
          if (details is Map) refusal = details['explanation'] as String? ?? details['category'] as String?;
        case 'error':
          final error = (event['error'] as Map?)?.cast<String, Object?>();
          throw ClaudeApiException(0, error?['message'] as String? ?? 'stream error');
      }
    }
    final ordered = [for (final key in blocks.keys.toList()..sort()) blocks[key]!];
    return (content: ordered, stopReason: stopReason, refusal: refusal);
  }

  /// Appends [messages] with each assistant turn and tool results. On failure
  /// the list is restored to its original length so the thread stays valid.
  Stream<CoachEvent> converse({
    required String system,
    required List<Map<String, Object?>> messages,
    List<ClaudeTool> tools = const [],
    int maxTokens = 16000,
    int maxToolRounds = 10,
  }) async* {
    if (apiKey.trim().isEmpty) {
      yield const CoachError('Add your Claude API key in Dojo settings to use the AI coach.');
      return;
    }
    final startLength = messages.length;
    final answer = StringBuffer();
    final toolsByName = {for (final t in tools) t.name: t};
    try {
      for (var round = 0; round <= maxToolRounds; round++) {
        final deltas = StreamController<String>();
        final pending = _stream(
          _body(system: system, messages: messages, tools: tools, maxTokens: maxTokens),
          deltas.add,
        ).whenComplete(deltas.close);
        // Errors are rethrown by `await pending` below.
        pending.ignore();
        await for (final delta in deltas.stream) {
          answer.write(delta);
          yield CoachTextDelta(delta);
        }
        final result = await pending;
        messages.add({'role': 'assistant', 'content': [
          for (final block in result.content) Map<String, Object?>.from(block)..remove('_invalid'),
        ]});
        if (result.stopReason == 'refusal') {
          yield CoachError(
            'Claude declined to answer${result.refusal == null ? '' : ' (${result.refusal})'}.',
          );
          return;
        }
        if (result.stopReason != 'tool_use') {
          yield CoachDone(answer.toString(), truncated: result.stopReason == 'max_tokens');
          return;
        }
        final toolResults = <Map<String, Object?>>[];
        for (final block in result.content.where((b) => b['type'] == 'tool_use')) {
          final tool = toolsByName[block['name']];
          final input = (block['input'] as Map? ?? const {}).cast<String, Object?>();
          if (tool == null || block['_invalid'] == true) {
            toolResults.add({
              'type': 'tool_result',
              'tool_use_id': block['id'],
              'content': tool == null ? 'Unknown tool.' : 'INVALID_JSON: tool input could not be parsed; please retry.',
              'is_error': true,
            });
            continue;
          }
          yield CoachToolNote(tool.describe(input));
          try {
            final output = await tool.run(input);
            toolResults.add({'type': 'tool_result', 'tool_use_id': block['id'], 'content': output});
          } catch (error) {
            toolResults.add({
              'type': 'tool_result',
              'tool_use_id': block['id'],
              'content': 'Error: $error',
              'is_error': true,
            });
          }
        }
        messages.add({'role': 'user', 'content': toolResults});
        if (answer.isNotEmpty && !answer.toString().endsWith('\n')) {
          answer.write('\n\n');
          yield const CoachTextDelta('\n\n');
        }
      }
      yield CoachDone(answer.toString());
    } catch (error) {
      messages.removeRange(startLength, messages.length);
      yield CoachError(_friendlyError(error));
    }
  }

  static String _friendlyError(Object error) {
    if (error is ClaudeApiException) {
      return switch (error.status) {
        401 => 'Claude rejected the API key. Check it in Dojo settings.',
        403 => 'This API key is not allowed to use that model.',
        404 => 'Model not found — pick another model in Dojo settings.',
        429 => 'Rate limited by the Claude API. Try again in a moment.',
        529 => 'Claude is overloaded right now. Try again shortly.',
        _ => 'Claude API error: ${error.message}',
      };
    }
    if (error is SocketException || error is TimeoutException || error is http.ClientException) {
      return 'Could not reach Claude. Check your internet connection.';
    }
    return 'Something went wrong talking to Claude: $error';
  }
}

/// System prompts.
abstract final class DojoPrompts {
  static const coach = '''
You are Chesster, a friendly, honest chess coach inside the student's private training app. The student is playing a training game against an engine: Maia (a neural network that plays like a human of a given rating) or Stockfish (limited to a given Elo, or full strength).

How to help:
- Explain in plain, everyday English for an improving club player. Name the concrete idea (hanging piece, fork, pin, skewer, back-rank, weak square, king safety, pawn structure, piece activity, plan) and show the key line in SAN.
- Ground every concrete claim in Stockfish. Use the tools to check evaluations, candidate moves and lines instead of calculating in your head, and never mention a move the tools have not confirmed is legal.
- Tool evaluations are in pawns from White's point of view unless labelled otherwise; translate them for the student ("you're about a pawn better", "this loses the knight").
- Be brief: 2–5 sentences or a few short bullets unless the student asks for depth. Replies may be read aloud on a phone, so avoid tables and long move lists.
- Don't play the game for the student. When asked for a hint, prefer guiding questions or naming the theme before giving the move.

Each user message starts with a [Game state] block. It is the authoritative current position; earlier blocks describe older positions.''';

  static const review = '''
You are Chesster, a friendly, honest chess coach reviewing a finished training game with the student. A Stockfish report of every move is provided. Write for an improving club player in plain English.

Your first review should cover, briefly:
1. Overall verdict: how well the student played, including the estimated performance rating compared with the opponent's rating (treat the estimate as rough).
2. The 2–4 turning points: what happened, why it mattered, and what to do instead (use the tools to check positions and lines; never invent moves).
3. One or two patterns or habits to work on, with a concrete training tip.
Use short headings or bullets, no tables. Later messages are follow-up questions; answer them concisely.''';

  static const progress = '''
You are Chesster, the student's long-term chess coach. You receive a summary of their training games (date, opponent and rating, colour, result, accuracy, average centipawn loss, estimated performance rating, error counts, undo usage). Use the get_game tool to look at specific games when it helps.

Analyse trends honestly: strength over time, strengths and recurring weaknesses, performance by opponent type and colour, and whether undo usage hides problems. Give a short, practical training plan with concrete next steps and an opponent/rating suggestion for the next games. Plain English, short headings or bullets, no tables. Treat performance ratings as rough estimates. Follow-up messages are questions; answer concisely.''';
}

/// Stockfish-backed tools shared by every coach conversation.
class CoachTools {
  static int get _movetime => DojoSettings.instance.analysisDepth.movetimeMs;

  static String _side(String fen) =>
      fen.split(' ').elementAtOrNull(1) == 'b' ? 'Black' : 'White';

  static String _fenError(String fen) {
    try {
      DojoChess.position(fen);
      return '';
    } catch (error) {
      return 'Invalid FEN: $error';
    }
  }

  static String describeAnalysis(EngineAnalysis analysis, {int maxLines = 5}) {
    final buffer = StringBuffer()
      ..writeln('${_side(analysis.fen)} to move. Depth ${analysis.depth}.')
      ..writeln('Best evaluation (White\'s view): ${formatWhiteEval(analysis.whiteScore, whiteMate: analysis.whiteMate)}');
    for (final (i, line) in analysis.lines.take(maxLines).indexed) {
      final white = analysis.whiteToMove ? line.score : -line.score;
      final mate = line.mate == null ? null : (analysis.whiteToMove ? line.mate : -line.mate!);
      buffer.writeln(
        '${i + 1}. ${formatWhiteEval(white, whiteMate: mate)}  ${DojoChess.pvToSan(analysis.fen, line.pv)}',
      );
    }
    return buffer.toString().trim();
  }

  static final analyzePosition = ClaudeTool(
    name: 'analyze_position',
    description:
        'Run Stockfish on a position. Returns the evaluation and the top candidate lines in SAN. '
        'Use it to check what the best moves and main ideas are.',
    schema: {
      'type': 'object',
      'properties': {
        'fen': {'type': 'string', 'description': 'Position in FEN.'},
        'lines': {
          'type': 'integer',
          'description': 'Number of candidate lines (1-5, default 3).',
        },
      },
      'required': ['fen'],
      'additionalProperties': false,
    },
    describe: (_) => 'Stockfish: analysing the position',
    run: (input) async {
      final fen = '${input['fen'] ?? ''}';
      final error = _fenError(fen);
      if (error.isNotEmpty) return error;
      final lines = ((input['lines'] as num?)?.toInt() ?? 3).clamp(1, 5);
      final analysis = await DojoEngine.instance.analyze(fen, multiPv: lines, movetimeMs: _movetime);
      return '${DojoChess.asciiBoard(fen)}\n${describeAnalysis(analysis)}';
    },
  );

  static final evaluateMove = ClaudeTool(
    name: 'evaluate_move',
    description:
        'Judge one move in a position with Stockfish: evaluation before and after, how much it loses '
        'compared with the best move, a quality label, and the best move with its line.',
    schema: {
      'type': 'object',
      'properties': {
        'fen': {'type': 'string', 'description': 'Position before the move, in FEN.'},
        'move': {'type': 'string', 'description': 'The move in SAN (e.g. Nxe5) or UCI (e.g. g1f3).'},
      },
      'required': ['fen', 'move'],
      'additionalProperties': false,
    },
    describe: (input) => 'Stockfish: checking ${input['move']}',
    run: (input) async {
      final fen = '${input['fen'] ?? ''}';
      final error = _fenError(fen);
      if (error.isNotEmpty) return error;
      final played = DojoChess.play(fen, '${input['move'] ?? ''}');
      if (played == null) {
        return 'Illegal move "${input['move']}". Legal moves: ${DojoChess.legalSans(fen).join(', ')}';
      }
      final verdict = await DojoGuidance.judge(fen, played.uci);
      final before = await DojoEngine.instance.analyze(fen, multiPv: 1, movetimeMs: _movetime);
      return [
        'Move: ${played.san} by ${_side(fen)}',
        'Verdict: ${verdict.quality.label}. ${verdict.headline}',
        'Mover\'s evaluation: before ${(verdict.scoreBefore / 100).toStringAsFixed(2)}, after ${(verdict.scoreAfter / 100).toStringAsFixed(2)} pawns (loss ${verdict.centipawnLoss} cp)',
        'Best line: ${DojoChess.pvToSan(fen, before.lines.firstOrNull?.pv ?? const [])}',
        'Position after the move:\n${DojoChess.asciiBoard(played.fen)}',
        'FEN after: ${played.fen}',
      ].join('\n');
    },
  );

  static final playMoves = ClaudeTool(
    name: 'play_moves',
    description:
        'Play a sequence of moves from a position (SAN or UCI) and return the resulting position, '
        'a board diagram and Stockfish\'s evaluation of it. Stops at the first illegal move.',
    schema: {
      'type': 'object',
      'properties': {
        'fen': {'type': 'string', 'description': 'Starting position in FEN.'},
        'moves': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Moves to play in order.',
        },
      },
      'required': ['fen', 'moves'],
      'additionalProperties': false,
    },
    describe: (input) => 'Stockfish: trying ${(input['moves'] as List?)?.join(' ') ?? 'a line'}',
    run: (input) async {
      var fen = '${input['fen'] ?? ''}';
      final error = _fenError(fen);
      if (error.isNotEmpty) return error;
      final played = <String>[];
      for (final move in (input['moves'] as List? ?? const [])) {
        final step = DojoChess.play(fen, '$move');
        if (step == null) {
          return 'Played ${played.join(' ')}; "$move" is illegal there. '
              'Legal moves: ${DojoChess.legalSans(fen).join(', ')}\nFEN: $fen';
        }
        played.add(step.san);
        fen = step.fen;
      }
      final analysis = await DojoEngine.instance.analyze(fen, multiPv: 2, movetimeMs: _movetime);
      return 'Played: ${played.join(' ')}\nFEN: $fen\n${DojoChess.asciiBoard(fen)}\n${describeAnalysis(analysis)}';
    },
  );

  static final legalMoves = ClaudeTool(
    name: 'legal_moves',
    description: 'List every legal move in a position (SAN).',
    schema: {
      'type': 'object',
      'properties': {
        'fen': {'type': 'string', 'description': 'Position in FEN.'},
      },
      'required': ['fen'],
      'additionalProperties': false,
    },
    describe: (_) => 'Listing legal moves',
    run: (input) async {
      final fen = '${input['fen'] ?? ''}';
      final error = _fenError(fen);
      if (error.isNotEmpty) return error;
      return DojoChess.legalSans(fen).join(', ');
    },
  );

  static List<ClaudeTool> get chess => [analyzePosition, evaluateMove, playMoves, legalMoves];

  static ClaudeTool getGame(Future<DojoGame?> Function(String id) loader) => ClaudeTool(
    name: 'get_game',
    description:
        'Fetch one stored training game by id: PGN, result and the Stockfish report of the student\'s '
        'inaccuracies, mistakes and blunders (if the game was analysed).',
    schema: {
      'type': 'object',
      'properties': {
        'game_id': {'type': 'string', 'description': 'Game id from the summary list.'},
      },
      'required': ['game_id'],
      'additionalProperties': false,
    },
    describe: (input) => 'Opening game ${input['game_id']}',
    run: (input) async {
      final game = await loader('${input['game_id']}');
      if (game == null) return 'No game with that id.';
      return DojoReviewContext.gameReport(game);
    },
  );
}

/// Builds the text blocks sent with review and progress requests.
abstract final class DojoReviewContext {
  static String gameReport(DojoGame game) {
    final buffer = StringBuffer()
      ..writeln('Game ${game.id}: student played ${game.playerIsWhite ? 'White' : 'Black'} '
          'vs ${game.opponent.label} (nominal rating ${game.opponent.nominalElo}).')
      ..writeln('Result: ${game.result ?? 'unfinished'} (${game.outcomeLabel}${game.resultReason == null ? '' : ', ${game.resultReason}'}).')
      ..writeln('Undos used during the game: ${game.undoCount}.')
      ..writeln('PGN (final line plus explored variations):')
      ..writeln(game.toPgn());
    final report = game.postGame;
    if (report == null) {
      buffer.writeln('No Stockfish report yet.');
      return buffer.toString();
    }
    final p = report.player;
    final o = report.opponent;
    buffer
      ..writeln()
      ..writeln('Stockfish report (${report.movetimeMs} ms per position):')
      ..writeln('Student: accuracy ${p.accuracy.round()}%, ACPL ${p.acpl.round()}, '
          'estimated performance ~${p.estimatedElo}, '
          '${p.counts[MoveQuality.blunder]} blunders, ${p.counts[MoveQuality.mistake]} mistakes, '
          '${p.counts[MoveQuality.inaccuracy]} inaccuracies.')
      ..writeln('Opponent: accuracy ${o.accuracy.round()}%, ACPL ${o.acpl.round()}, '
          'estimated performance ~${o.estimatedElo}.')
      ..writeln('Move-by-move (eval in pawns, White\'s view; * = student move):');
    for (final m in report.moves) {
      final mark = m.byPlayer ? '*' : ' ';
      final best = m.quality.isError && m.bestSan != null ? ' best ${m.bestSan} (${m.bestLine ?? ''})' : '';
      buffer.writeln(
        '$mark ${m.moveLabel} ${m.quality.label} ${(m.whiteEvalBefore / 100).toStringAsFixed(1)}→'
        '${(m.whiteEvalAfter / 100).toStringAsFixed(1)} fen_before="${m.fenBefore}"$best',
      );
    }
    return buffer.toString();
  }
}
