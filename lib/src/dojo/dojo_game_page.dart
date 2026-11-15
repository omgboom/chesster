part of '../../main.dart';

/// Builds the hidden "[Game state]" block sent with coach messages.
String dojoGameStateBlock(DojoGame game, DojoNode node) {
  final path = game.pathTo(node.id);
  final moves = StringBuffer();
  for (final n in path.skip(1)) {
    final parent = game.nodes[n.parentId]!;
    if (parent.turn == dc.Side.white) moves.write('${parent.fullmove}. ');
    if (n == path[1] && parent.turn == dc.Side.black) moves.write('${parent.fullmove}... ');
    moves.write('${n.san} ');
  }
  final playerColour = game.playerIsWhite ? 'White' : 'Black';
  final toMove = node.turn == dc.Side.white ? 'White' : 'Black';
  final whoMoves = node.turn == game.playerSide ? 'the student' : 'the opponent';
  DojoNode? lastPlayerMove;
  for (final n in path.reversed) {
    if (n.byPlayer) {
      lastPlayerMove = n;
      break;
    }
  }
  final buffer = StringBuffer()
    ..writeln('[Game state]')
    ..writeln('The student plays $playerColour against ${game.opponent.label}.')
    ..writeln('Moves so far: ${moves.isEmpty ? '(none)' : moves.toString().trim()}')
    ..writeln('Current FEN: ${node.fen}')
    ..writeln('$toMove to move ($whoMoves).')
    ..writeln(DojoChess.asciiBoard(node.fen));
  final verdict = lastPlayerMove?.verdict;
  if (lastPlayerMove != null) {
    final parent = game.nodes[lastPlayerMove.parentId]!;
    buffer.writeln(
      'Student\'s last move: ${lastPlayerMove.san} (from FEN ${parent.fen})'
      '${verdict == null ? '' : ' — Stockfish: ${verdict.headline}; ${verdict.scoreLine}'}',
    );
  }
  final analysis = node.analysis;
  if (analysis != null) {
    buffer.writeln(
      'Current Stockfish eval (White\'s view): ${formatWhiteEval(analysis.whiteScore, whiteMate: analysis.whiteMate)}',
    );
  }
  final takebacks = game.takebacksOnLine(node.id);
  if (takebacks.isNotEmpty) {
    buffer.writeln('Takebacks on this line (the student stepped back and changed a move):');
    for (final t in takebacks) {
      buffer.writeln('- $t');
    }
  }
  final otherLines = game.nodes.values.where((n) => n.children.length > 1).length;
  if (otherLines > 0) buffer.writeln('The game tree has $otherLines branching points from explored alternatives.');
  final training = game.training;
  if (training != null) {
    buffer.writeln(training.isOpening
        ? 'This is an opening training game: ${training.title}. Use the opening name and typical plans when helpful.'
        : 'This is an endgame training game: ${training.title} (goal: ${training.endgame?.goal}).');
  }
  if (game.isFinished) buffer.writeln('Game result: ${game.result} (${game.resultReason}).');
  buffer.write('[/Game state]');
  return buffer.toString();
}

CoachSession dojoCoachSession(DojoGame game, Future<void> Function() persist) => CoachSession(
  conversation: game.coach,
  system: DojoPrompts.coach,
  tools: CoachTools.chess,
  kind: 'chat',
  onPersist: persist,
  contextBuilder: () => (dojoGameStateBlock(game, game.current), game.currentId),
);

class DojoGamePage extends StatefulWidget {
  const DojoGamePage({required this.game, this.maiaEvaluator, super.key});

  final DojoGame game;

  /// Test seam: returns Maia logits for (positions, elo).
  final Future<Float32List> Function(List<String> positions, int elo)? maiaEvaluator;

  @override
  State<DojoGamePage> createState() => _DojoGamePageState();
}

class _DojoGamePageState extends State<DojoGamePage> {
  DojoGame get game => widget.game;
  late final cg.ChessboardController _board;
  late final CoachSession _coach;
  final MaiaInferenceScope _maiaScope = MaiaInferenceScope();
  final ScrollController _movesScroll = ScrollController();
  int _generation = 0;
  bool _opponentThinking = false;
  bool _evalVisible = false;
  bool _verdictOpen = false;
  bool _flipped = false;
  String? _engineError;
  final Set<int> _analysing = {};
  Timer? _saveTimer;
  bool _backgroundRunning = false;
  String? _trainingMiss;
  bool _showBookArrow = false;
  bool _pointersOpen = true;

  DojoSettings get settings => DojoSettings.instance;
  bool get _guidance => settings.guidance;

  @override
  void initState() {
    super.initState();
    _board = cg.ChessboardController(game: _boardData());
    _coach = dojoCoachSession(game, _saveNow);
    settings.addListener(_settingsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _arrive(game.current, initial: true));
  }

  @override
  void dispose() {
    _generation++;
    _maiaScope.invalidate();
    settings.removeListener(_settingsChanged);
    _saveTimer?.cancel();
    unawaited(DojoStore.instance.save(game));
    _movesScroll.dispose();
    _coach.dispose();
    super.dispose();
  }

  void _settingsChanged() {
    if (!mounted) return;
    setState(() {});
    if (_guidance) _analyse(game.current);
  }

  // ---- Board state -------------------------------------------------------

  bool _isGameOverAt(DojoNode node) => game.naturalOutcome(node.id) != null;

  bool get _playerToMove =>
      game.current.turn == game.playerSide && !_isGameOverAt(game.current);

  cg.GameData _boardData() {
    final node = game.current;
    final pos = DojoChess.position(node.fen);
    final interactive = _playerToMove && !_opponentThinking;
    return cg.GameData(
      fen: node.fen,
      playerSide: interactive
          ? (game.playerIsWhite ? cg.PlayerSide.white : cg.PlayerSide.black)
          : cg.PlayerSide.none,
      sideToMove: pos.turn,
      validMoves: dc.makeLegalMoves(pos),
      kingSquareInCheck: pos.isCheck ? pos.board.kingOf(pos.turn) : null,
      lastMove: node.uci == null ? null : dc.Move.parse(node.uci!),
    );
  }

  void _sync({bool animate = true}) {
    _board.updatePosition(_boardData(), animate: animate, resetPremove: true);
    if (mounted) setState(() {});
    _scrollMovesToCurrent();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _saveNow);
  }

  Future<void> _saveNow() async {
    _saveTimer?.cancel();
    await DojoStore.instance.save(game);
  }

  // ---- Flow --------------------------------------------------------------

  void _arrive(DojoNode node, {bool initial = false}) {
    if (!mounted) return;
    final outcome = game.naturalOutcome(node.id);
    if (outcome != null) {
      final newlyFinished = game.resultNodeId != node.id;
      if (newlyFinished) game.finish(outcome.result, outcome.reason, node.id);
      _sync();
      _scheduleSave();
      if (newlyFinished && !initial) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showResultDialog());
      }
      _analyse(node);
      _backgroundAnalyse();
      return;
    }
    if (node.turn != game.playerSide) {
      if (node.children.isNotEmpty) {
        // Replaying a known move: follow the opponent's earlier reply.
        final next = game.nodes[node.preferredChild ?? node.children.first]!;
        Future<void>.delayed(const Duration(milliseconds: 250), () {
          if (!mounted || game.currentId != node.id) return;
          game.select(next.id);
          _sync();
          _arrive(next);
        });
      } else if (!initial || !_opponentThinking) {
        unawaited(_opponentMove(node));
      }
    }
    _analyse(node);
    _backgroundAnalyse();
    _scheduleSave();
  }

  /// Opening book move expected at [node] (training only).
  BookMove? _bookMoveAt(DojoNode node) {
    final lesson = game.training?.opening;
    if (lesson == null) return null;
    final ply = game.plyOf(node.id);
    if (ply >= lesson.moves.length) return null;
    // Only while the game is still following the book.
    final path = game.pathTo(node.id);
    for (var i = 1; i < path.length; i++) {
      if (path[i].san != lesson.moves[i - 1].san) return null;
    }
    return lesson.moves[ply];
  }

  /// Analyses earlier positions on the current line while you play, at the
  /// report's strength, so the post-game report is nearly instant.
  void _backgroundAnalyse() {
    if (_backgroundRunning) return;
    _backgroundRunning = true;
    () async {
      try {
        while (mounted) {
          final pending = game
              .pathTo(game.currentId)
              .where((n) => n.analysis == null && !_analysing.contains(n.id))
              .firstOrNull;
          if (pending == null) break;
          final analysis = await DojoEngine.instance.analyze(
            pending.fen,
            multiPv: _guidance ? 3 : 1,
            movetimeMs: settings.analysisDepth.movetimeMs,
            background: true,
          );
          pending.analysis ??= analysis;
          _scheduleSave();
        }
      } catch (error, stackTrace) {
        unawaited(AppDiagnostics.record('dojo-background-analysis', error, stackTrace));
      } finally {
        _backgroundRunning = false;
      }
    }();
  }

  Future<void> _onMove(dc.Move move, {bool? viaDragAndDrop}) async {
    if (!_playerToMove || _opponentThinking) return;
    final parent = game.current;
    final book = _bookMoveAt(parent);
    if (book != null) {
      final expected = DojoChess.play(parent.fen, book.san);
      if (expected != null && expected.uci != move.uci) {
        final played = DojoChess.sanOf(parent.fen, move.uci) ?? move.uci;
        setState(() {
          game.training = game.training!.withMiss();
          _trainingMiss = 'Not quite — $played is not the book move here. Try again, or tap "Show me".';
        });
        _sync();
        _scheduleSave();
        return;
      }
    }
    _trainingMiss = null;
    _showBookArrow = false;
    final isTakeback = parent.children.any((c) {
      final child = game.nodes[c]!;
      return child.byPlayer && child.uci != move.uci;
    }) && book == null;
    if (isTakeback && !parent.children.any((c) => game.nodes[c]!.uci == move.uci)) {
      game.undoCount++;
    }
    final DojoNode node;
    try {
      node = game.addMove(parent.id, move.uci, byPlayer: true);
    } catch (_) {
      _sync();
      return;
    }
    game.select(node.id);
    _sync(animate: viaDragAndDrop != true);
    _arrive(node);
  }

  Future<void> _opponentMove(DojoNode node) async {
    final generation = ++_generation;
    setState(() {
      _opponentThinking = true;
      _engineError = null;
    });
    _sync();
    final timer = Stopwatch()..start();
    String? uci;
    final book = _bookMoveAt(node);
    try {
      uci = book != null
          ? await Future<String?>.delayed(
              const Duration(milliseconds: 500),
              () => DojoChess.play(node.fen, book.san)?.uci,
            )
          : game.opponent.kind == DojoOpponentKind.maia
          ? await _maiaMove(node)
          : await DojoEngine.instance.chooseMove(
              node.fen,
              elo: game.opponent.fullStrength ? null : game.opponent.elo,
              movetimeMs: game.opponent.fullStrength
                  ? 1500
                  : (300 + (game.opponent.elo - dojoStockfishMinElo) ~/ 3).clamp(300, 1000),
            );
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-opponent-move', error, stackTrace));
      if (mounted && generation == _generation) {
        setState(() => _engineError = '${game.opponent.name} could not move: $error');
      }
    }
    final minimum = const Duration(milliseconds: 450) - timer.elapsed;
    if (minimum > Duration.zero) await Future<void>.delayed(minimum);
    if (!mounted || generation != _generation) return;
    setState(() => _opponentThinking = false);
    if (uci == null || game.currentId != node.id) {
      _sync();
      return;
    }
    final child = game.addMove(node.id, uci, byPlayer: false);
    game.select(child.id);
    _sync();
    _arrive(child);
  }

  Future<String?> _maiaMove(DojoNode node) async {
    final positions = [for (final n in game.pathTo(node.id)) n.fen];
    final elo = game.opponent.elo;
    final Float32List? logits;
    if (widget.maiaEvaluator != null) {
      logits = await widget.maiaEvaluator!(positions, elo);
    } else {
      final tokens = MaiaEncoding.historicalTokens(positions);
      logits = await MaiaInferenceQueue.predict(
        {'tokens': tokens, 'selfElo': elo, 'opponentElo': elo},
        replaceableScope: _maiaScope,
      );
    }
    if (logits == null) return null;
    if (logits.length != 4352 || logits.any((v) => !v.isFinite)) {
      throw StateError('Maia returned an invalid policy');
    }
    final board = chess.Chess.fromFEN(node.fen);
    final legal = board.moves({'asObjects': true}).cast<chess.Move>();
    final sampling = const MaiaPlaySettings(
      temperature: defaultMaiaTemperature,
      topP: defaultMaiaTopP,
      maxOpeningVariety: true,
    ).forFen(node.fen);
    final move = MaiaEncoding.sampleLegalMove(
      board,
      legal,
      logits.toList(growable: false),
      temperature: sampling.temperature,
      topP: sampling.topP,
    );
    return MaiaEncoding.uci(move);
  }

  /// Background Stockfish work for guidance: eval of [node] and, for player
  /// moves, the verdict.
  void _analyse(DojoNode node) {
    if (!_guidance || _analysing.contains(node.id)) return;
    final needsEval = node.analysis == null;
    final needsVerdict = node.byPlayer && node.verdict == null && node.parentId != null;
    if (!needsEval && !needsVerdict) return;
    _analysing.add(node.id);
    if (mounted) setState(() {});
    final movetime = settings.analysisDepth.movetimeMs;
    () async {
      try {
        node.analysis ??= await DojoEngine.instance.analyze(node.fen, multiPv: 3, movetimeMs: movetime);
        if (needsVerdict) {
          final parent = game.nodes[node.parentId!]!;
          parent.analysis ??= await DojoEngine.instance.analyze(parent.fen, multiPv: 3, movetimeMs: movetime);
          node.verdict = await DojoGuidance.judge(
            parent.fen,
            node.uci!,
            before: parent.analysis,
            after: node.analysis,
          );
        }
        _scheduleSave();
      } catch (error, stackTrace) {
        unawaited(AppDiagnostics.record('dojo-analyse', error, stackTrace));
        if (mounted) setState(() => _engineError = 'Stockfish unavailable: $error');
      } finally {
        _analysing.remove(node.id);
        if (mounted) setState(() {});
      }
    }();
  }

  // ---- Navigation --------------------------------------------------------

  void _goTo(int id) {
    if (!game.nodes.containsKey(id)) return;
    _generation++;
    _maiaScope.invalidate();
    if (_opponentThinking) setState(() => _opponentThinking = false);
    game.select(id);
    _sync();
    _analyse(game.current);
    _scheduleSave();
  }

  void _back() {
    final parent = game.current.parentId;
    if (parent != null) _goTo(parent);
  }

  void _forward() {
    final node = game.current;
    if (node.children.isEmpty) return;
    _goTo(node.preferredChild ?? node.children.first);
  }

  /// Take back to the player's previous decision point. The abandoned moves
  /// stay in the tree as a variation.
  void _undo() {
    final node = game.current;
    int? target;
    if (node.turn == game.playerSide) {
      // Opponent just replied: go back before the player's move.
      final parent = node.parentId == null ? null : game.nodes[node.parentId!];
      target = parent?.parentId;
      if (parent != null && !parent.byPlayer) target = parent.id;
    } else {
      target = node.parentId;
    }
    if (target == null) return;
    _goTo(target);
  }

  void _continueOpponent() {
    final node = game.current;
    if (node.turn == game.playerSide || _opponentThinking || _isGameOverAt(node)) return;
    if (node.children.isNotEmpty) {
      _forward();
      return;
    }
    unawaited(_opponentMove(node));
  }

  void _scrollMovesToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_movesScroll.hasClients) return;
      final line = game.lineThrough(game.currentId);
      final index = line.indexWhere((n) => n.id == game.currentId);
      final fraction = line.length <= 1 ? 1.0 : index / (line.length - 1);
      final target = (_movesScroll.position.maxScrollExtent * fraction)
          .clamp(0.0, _movesScroll.position.maxScrollExtent);
      _movesScroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  // ---- Actions -----------------------------------------------------------

  DojoNode? get _lastPlayerMove {
    for (final n in game.pathTo(game.currentId).reversed) {
      if (n.byPlayer) return n;
    }
    return null;
  }

  Future<void> _openCoach({String? prompt, String? kind}) => showCoachSheet(
    context,
    session: _coach,
    title: 'Coach',
    initialPrompt: prompt,
    initialKind: kind,
    suggestions: const [
      'What should I be thinking about here?',
      'Give me a hint',
      'What is my opponent threatening?',
      'What is the plan for both sides?',
    ],
  );

  void _explain(DojoNode move) {
    final verdict = move.verdict;
    final number = game.nodes[move.parentId]!.fullmove;
    final label = '${game.playerIsWhite ? '$number.' : '$number...'} ${move.san}';
    final prompt = verdict == null
        ? 'Explain my move $label. Was it good, and why?'
        : verdict.quality.isError
        ? 'Explain my move $label. Stockfish calls it a ${verdict.quality.label.toLowerCase()} and prefers ${verdict.bestSan}. Why was my move bad and why is ${verdict.bestSan} better?'
        : verdict.playedBest
        ? 'Explain my move $label. Stockfish rates it "${verdict.quality.label}". Why is it good, and what idea does it serve?'
        : 'Explain my move $label. Stockfish rates it "${verdict.quality.label}" but prefers ${verdict.bestSan}. Why was mine fine, and why is ${verdict.bestSan} better?';
    unawaited(_openCoach(prompt: prompt, kind: 'explain'));
  }

  Future<void> _resign() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Resign this game?'),
        content: const Text('The current line is recorded as a loss. You can still explore afterwards.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Resign')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _generation++;
    setState(() => _opponentThinking = false);
    game.finish(game.playerIsWhite ? '0-1' : '1-0', 'resignation', game.currentId);
    await _saveNow();
    _sync();
    if (mounted) await _showResultDialog();
  }

  Future<void> _claimDraw() async {
    game.finish('1/2-1/2', 'agreed draw', game.currentId);
    await _saveNow();
    _sync();
    if (mounted) await _showResultDialog();
  }

  Future<void> _showResultDialog() async {
    if (!mounted) return;
    final score = game.playerScore;
    final title = switch (score) {
      1 => 'You won!',
      0 => '${game.opponent.name} won',
      _ => 'Draw',
    };
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text('${game.result} by ${game.resultReason}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'explore'), child: const Text('Keep exploring')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, 'analyse'),
            icon: const Icon(Icons.insights),
            label: const Text('Analyze game'),
          ),
        ],
      ),
    );
    if (choice == 'analyse' && mounted) await _openPostGame();
  }

  Future<void> _openPostGame() async {
    await _saveNow();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DojoPostGamePage(game: game)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _showLines() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      maxChildSize: 0.9,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('All lines', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Tap any move to jump there. Play a different move from an earlier position to start a new line.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          DojoMoveTree(
            game: game,
            showQuality: _guidance,
            onSelect: (id) {
              Navigator.pop(context);
              _goTo(id);
            },
          ),
        ],
      ),
    ),
  );

  Future<void> _copyPgn() async {
    await Clipboard.setData(ClipboardData(text: game.toPgn()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PGN copied')));
  }

  void _onMenu(String value) {
    switch (value) {
      case 'flip':
        setState(() => _flipped = !_flipped);
      case 'undo':
        _undo();
      case 'resign':
        unawaited(_resign());
      case 'draw':
        unawaited(_claimDraw());
      case 'analyse':
        unawaited(_openPostGame());
      case 'pgn':
        unawaited(_copyPgn());
      case 'settings':
        unawaited(Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const DojoSettingsPage()),
        ));
    }
  }

  // ---- UI ----------------------------------------------------------------

  dc.Side get _orientation {
    final player = game.playerSide;
    return _flipped ? player.opposite : player;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 900 && size.width > size.height;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              game.training == null ? 'vs ${game.opponent.label}' : game.training!.title,
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
            if (_openingName() case final name?)
              Text(
                name,
                key: const ValueKey('dojo-opening-name'),
                style: Theme.of(context).textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Dojo settings',
            icon: const Icon(Icons.tune),
            onPressed: () => _onMenu('settings'),
          ),
          PopupMenuButton<String>(
            onSelected: _onMenu,
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'undo', child: ListTile(leading: Icon(Icons.undo), title: Text('Take back my move'))),
              const PopupMenuItem(value: 'flip', child: ListTile(leading: Icon(Icons.swap_vert), title: Text('Flip board'))),
              const PopupMenuItem(value: 'analyse', child: ListTile(leading: Icon(Icons.insights), title: Text('Analyze game'))),
              const PopupMenuItem(value: 'pgn', child: ListTile(leading: Icon(Icons.copy), title: Text('Copy PGN'))),
              if (!game.isFinished) ...[
                const PopupMenuItem(value: 'draw', child: ListTile(leading: Icon(Icons.handshake_outlined), title: Text('Call it a draw'))),
                const PopupMenuItem(value: 'resign', child: ListTile(leading: Icon(Icons.flag_outlined), title: Text('Resign'))),
              ],
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: wide ? _wideLayout() : _narrowLayout(),
      ),
    );
  }

  Widget _narrowLayout() {
    return Column(
      children: [
        _playerBar(opponent: true),
        LayoutBuilder(
          builder: (context, constraints) {
            final height = MediaQuery.sizeOf(context).height;
            // Leave room for bars, move list, guidance and controls.
            final maxBoard = max(220.0, height - 360);
            return _boardWithBar(min(constraints.maxWidth, maxBoard + 16));
          },
        ),
        _playerBar(opponent: false),
        _moveStrip(),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: _guidancePanel(),
          ),
        ),
        _controls(),
      ],
    );
  }

  Widget _wideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final boardSide = min(constraints.maxWidth - 24, constraints.maxHeight - 110);
              return Center(
                child: SizedBox(
                  width: boardSide + 18,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _playerBar(opponent: true),
                      _boardWithBar(boardSide + 18),
                      _playerBar(opponent: false),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 420,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: DojoMoveTree(
                      game: game,
                      showQuality: _guidance,
                      onSelect: _goTo,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(padding: const EdgeInsets.all(8), child: _guidancePanel()),
              _controls(),
              const Divider(height: 1),
              if (_guidance)
                Expanded(
                  child: CoachChatView(
                    session: _coach,
                    title: 'Coach',
                    embedded: true,
                    suggestions: const ['Give me a hint', 'What is my opponent threatening?'],
                  ),
                )
              else
                const Spacer(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _boardWithBar(double width) {
    const handleWidth = 16.0;
    final boardSize = width - handleWidth - 2;
    final analysis = game.current.analysis;
    final showBar = _guidance && _evalVisible;
    return SizedBox(
      width: width,
      height: boardSize,
      child: Row(
        children: [
          SizedBox(
            width: handleWidth,
            height: boardSize,
            child: _guidance
                ? Semantics(
                    button: true,
                    label: showBar ? 'Hide momentum bar' : 'Show momentum bar',
                    child: GestureDetector(
                      key: const ValueKey('dojo-eval-toggle'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _evalVisible = !_evalVisible),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 2, right: 2),
                        child: showBar
                            ? DojoEvalBar(
                                whiteScore: analysis?.whiteScore,
                                whiteMate: analysis?.whiteMate,
                                whiteAtBottom: _orientation == dc.Side.white,
                                loading: _analysing.contains(game.currentId),
                              )
                            : const DojoEvalHandle(),
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 2),
          cg.Chessboard(
            key: const ValueKey('dojo-board'),
            size: boardSize,
            orientation: _orientation,
            controller: _board,
            onMove: _onMove,
            shapes: _bookArrow(),
            settings: boardPreferencesOf(context).interactiveSettings.copyWith(enablePremoves: false),
          ),
        ],
      ),
    );
  }

  Widget _playerBar({required bool opponent}) {
    final theme = Theme.of(context);
    final material = DojoChess.materialBalance(game.current.fen);
    // `opponent` means "top bar"; the top shows whoever sits at the top of the board.
    final showOpponent = opponent == (_orientation == game.playerSide);
    final whiteHere = showOpponent ? !game.playerIsWhite : game.playerIsWhite;
    final adv = whiteHere ? material : -material;
    final name = showOpponent ? game.opponent.label : 'You';
    final icon = showOpponent
        ? (game.opponent.kind == DojoOpponentKind.maia ? Icons.person_outline : Icons.memory)
        : Icons.person;
    final thinking = showOpponent && _opponentThinking;
    return SizedBox(
      height: 34,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: whiteHere ? Colors.white : Colors.black,
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Icon(icon, size: 18),
            const SizedBox(width: 4),
            Text(name, style: theme.textTheme.titleSmall),
            if (adv > 0) ...[
              const SizedBox(width: 6),
              Text('+$adv', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
            ],
            const Spacer(),
            if (thinking) ...[
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 6),
              Text('thinking…', style: theme.textTheme.labelMedium),
            ],
          ],
        ),
      ),
    );
  }

  Widget _moveStrip() {
    final theme = Theme.of(context);
    final line = game.lineThrough(game.currentId);
    if (line.length == 1) {
      return SizedBox(
        height: 38,
        child: Center(
          child: Text(
            game.playerIsWhite ? 'Your move — you play White' : '${game.opponent.name} opens — you play Black',
            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      );
    }
    return SizedBox(
      height: 38,
      child: ListView.builder(
        controller: _movesScroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: line.length - 1,
        itemBuilder: (context, i) {
          final node = line[i + 1];
          final parent = line[i];
          final current = node.id == game.currentId;
          final hasSiblings = parent.children.length > 1;
          final prefix = parent.turn == dc.Side.white
              ? '${parent.fullmove}. '
              : (i == 0 ? '${parent.fullmove}... ' : '');
          final quality = _guidance ? node.verdict?.quality : null;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _goTo(node.id),
              onLongPress: hasSiblings ? () => _chooseSibling(parent) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: current ? theme.colorScheme.primaryContainer : null,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasSiblings)
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: Icon(Icons.call_split, size: 12, color: theme.colorScheme.primary),
                      ),
                    Text(
                      '$prefix${node.san}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (quality != null && quality != MoveQuality.good)
                      Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Text(
                          quality.glyph,
                          style: TextStyle(color: quality.color(theme.colorScheme), fontWeight: FontWeight.w800),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _chooseSibling(DojoNode parent) async {
    final id = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Switch line'),
            ),
            for (final childId in parent.children)
              ListTile(
                leading: const Icon(Icons.call_split),
                title: Text(DojoChess.pvToSan(parent.fen, [
                  for (final n in game.lineThrough(childId).skip(game.pathTo(parent.id).length)) n.uci!,
                ], maxMoves: 6)),
                onTap: () => Navigator.pop(context, childId),
              ),
          ],
        ),
      ),
    );
    if (id != null) _goTo(id);
  }

  Widget _guidancePanel() {
    final theme = Theme.of(context);
    final children = <Widget>[];
    if (_engineError != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(_engineError!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
      ));
    }
    final node = game.current;
    final trainingCard = _trainingCard();
    if (trainingCard != null) children.add(trainingCard);
    final waitingForOpponent = node.turn != game.playerSide &&
        node.children.isEmpty &&
        !_opponentThinking &&
        !_isGameOverAt(node) &&
        !(game.isFinished && game.resultNodeId == node.id);
    if (game.isFinished) {
      children.add(Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.emoji_events_outlined),
          title: Text('${game.outcomeLabel} · ${game.result} by ${game.resultReason}'),
          subtitle: Text(game.postGame == null ? 'Tap to analyze the game' : 'Analysis ready'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openPostGame,
        ),
      ));
    }
    if (waitingForOpponent) {
      children.add(Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          onPressed: _continueOpponent,
          icon: const Icon(Icons.play_arrow),
          label: Text('Let ${game.opponent.name} move'),
        ),
      ));
    }
    if (!_guidance) {
      if (children.isEmpty) {
        children.add(Text(
          'Guidance is off. Turn it on in Dojo settings for move checks, the momentum bar and the coach.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        ));
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    }
    final move = _lastPlayerMove;
    final verdict = move?.verdict;
    final judging = move != null && verdict == null && _analysing.contains(move.id);
    children.add(Row(
      children: [
        Flexible(
          child: FilledButton.tonalIcon(
            key: const ValueKey('dojo-move-check'),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: move == null ? null : () => setState(() => _verdictOpen = !_verdictOpen),
            icon: Icon(_verdictOpen ? Icons.expand_less : Icons.fact_check_outlined, size: 18),
            label: Text(
              move == null ? 'Move check' : 'Move check: ${move.san}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 6),
        OutlinedButton.icon(
          key: const ValueKey('dojo-explain'),
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: move == null ? null : () => _explain(move),
          icon: const Icon(Icons.lightbulb_outline, size: 18),
          label: const Text('Explain'),
        ),
      ],
    ));
    if (_verdictOpen && move != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _VerdictCard(verdict: verdict, judging: judging || verdict == null),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Set<cg.Shape> _bookArrow() {
    if (!_showBookArrow) return const {};
    final node = game.current;
    final book = _bookMoveAt(node);
    if (book == null || node.turn != game.playerSide) return const {};
    final move = dc.Move.parse(DojoChess.play(node.fen, book.san)?.uci ?? '');
    if (move is! dc.NormalMove) return const {};
    return {cg.Arrow(color: const Color(0xC015781B), orig: move.from, dest: move.to)};
  }

  String? _openingName() {
    if (game.root.fen != dojoStartFen) return null;
    return OpeningNames.identifyPositions(game.pathTo(game.currentId).map((n) => n.fen));
  }

  void _hint() => unawaited(_openCoach(
    prompt: 'Give me a hint for this position. Don\'t tell me the move outright: point me at the idea or the piece to look at first.',
    kind: 'hint',
  ));

  /// Whether the line to [id] still follows the lesson's book moves.
  bool _followsBook(int id) {
    final lesson = game.training?.opening;
    if (lesson == null) return false;
    final path = game.pathTo(id);
    if (path.length - 1 > lesson.moves.length) return false;
    for (var i = 1; i < path.length; i++) {
      if (path[i].san != lesson.moves[i - 1].san) return false;
    }
    return true;
  }

  Widget? _trainingCard() {
    final training = game.training;
    if (training == null) return null;
    final theme = Theme.of(context);
    final node = game.current;
    if (training.endgame case final lesson?) {
      if (!_pointersOpen) {
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _pointersOpen = true),
            icon: const Icon(Icons.flag_outlined, size: 18),
            label: Text('Goal: ${lesson.goal} · show pointers'),
          ),
        );
      }
      return Card(
        key: const ValueKey('dojo-training-card'),
        margin: const EdgeInsets.only(bottom: 6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Goal: ${lesson.goal}', style: theme.textTheme.titleSmall)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _pointersOpen = false),
                  ),
                ],
              ),
              for (final p in lesson.pointers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2, right: 8),
                  child: Text('• $p', style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
      );
    }
    final lesson = training.opening;
    if (lesson == null) return null;
    final ply = game.plyOf(node.id);
    final onBook = _followsBook(node.id);
    final lastBook = onBook && ply > 0 ? lesson.moves[ply - 1] : null;
    final next = _bookMoveAt(node);
    final playerNext = next != null && node.turn == game.playerSide;
    final done = onBook && ply >= lesson.moves.length;
    return Card(
      key: const ValueKey('dojo-training-card'),
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${lesson.eco} · ${lesson.name}',
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${min(ply, lesson.moves.length)}/${lesson.moves.length}',
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (ply == 0) Text(lesson.summary, style: theme.textTheme.bodySmall),
            if (lastBook != null)
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: '${lastBook.san}: ', style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(text: lastBook.note),
                ]),
                key: const ValueKey('dojo-book-note'),
                style: theme.textTheme.bodySmall,
              ),
            if (_trainingMiss != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_trainingMiss!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
            if (playerNext)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Your move: ${next.note}',
                        style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('dojo-show-me'),
                      onPressed: () => setState(() => _showBookArrow = !_showBookArrow),
                      child: Text(_showBookArrow ? 'Hide' : 'Show me'),
                    ),
                  ],
                ),
              ),
            if (done)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Book complete! Now play it out against ${game.opponent.label}.',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            if (!onBook)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('You left the book line, so play on as a normal game.', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    final node = game.current;
    final canUndo = node.parentId != null;
    Widget button(IconData icon, String label, VoidCallback? onPressed, {Key? key}) => Expanded(
      child: InkResponse(
        key: key,
        onTap: onPressed,
        radius: 28,
        child: Opacity(
          opacity: onPressed == null ? 0.35 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22),
                const SizedBox(height: 2),
                Text(label, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ),
      ),
    );
    return Material(
      elevation: 2,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            button(Icons.chevron_left, 'Back', canUndo ? _back : null, key: const ValueKey('dojo-back')),
            button(Icons.chevron_right, 'Forward', node.children.isEmpty ? null : _forward),
            button(Icons.account_tree_outlined, 'Lines', _showLines),
            if (_guidance)
              button(
                Icons.tips_and_updates_outlined,
                'Hint',
                _playerToMove ? _hint : null,
                key: const ValueKey('dojo-hint'),
              ),
            if (_guidance && MediaQuery.sizeOf(context).width < 900)
              button(Icons.forum_outlined, 'Coach', () => _openCoach(), key: const ValueKey('dojo-coach')),
          ],
        ),
      ),
    );
  }
}

class _VerdictCard extends StatelessWidget {
  const _VerdictCard({required this.verdict, required this.judging});

  final MoveVerdict? verdict;
  final bool judging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = verdict;
    if (v == null) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Stockfish is checking your move…', style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      );
    }
    final color = v.quality.color(theme.colorScheme);
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MoveQualityBadge(v.quality, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${v.playedSan}: ${v.headline}',
                    key: const ValueKey('dojo-verdict-headline'),
                    style: theme.textTheme.titleSmall?.copyWith(color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(v.scoreLine, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// PGN-style tree of every explored line with tappable moves.
class DojoMoveTree extends StatelessWidget {
  const DojoMoveTree({
    required this.game,
    required this.onSelect,
    this.showQuality = true,
    super.key,
  });

  final DojoGame game;
  final void Function(int id) onSelect;
  final bool showQuality;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mainIds = {for (final n in game.lineThrough(0)) n.id};
    final spans = <InlineSpan>[];

    void moveSpan(DojoNode parent, DojoNode node, {required bool forceNumber, required int depth}) {
      final number = parent.turn == dc.Side.white
          ? '${parent.fullmove}. '
          : (forceNumber ? '${parent.fullmove}... ' : '');
      final current = node.id == game.currentId;
      final quality = showQuality ? node.verdict?.quality : null;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: InkWell(
          onTap: () => onSelect(node.id),
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            decoration: BoxDecoration(
              color: current ? theme.colorScheme.primaryContainer : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: number, style: TextStyle(color: theme.colorScheme.outline)),
                TextSpan(
                  text: node.san,
                  style: TextStyle(fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.w400),
                ),
                if (quality != null && quality.glyph.isNotEmpty)
                  TextSpan(
                    text: quality.glyph,
                    style: TextStyle(color: quality.color(theme.colorScheme), fontWeight: FontWeight.w800),
                  ),
              ]),
              style: (depth == 0 ? theme.textTheme.bodyMedium : theme.textTheme.bodySmall),
            ),
          ),
        ),
      ));
    }

    void line(DojoNode from, {required bool forceNumber, required int depth}) {
      var node = from;
      var needNumber = forceNumber;
      while (node.children.isNotEmpty) {
        final ordered = [...node.children]
          ..sort((a, b) => (mainIds.contains(b) ? 1 : 0) - (mainIds.contains(a) ? 1 : 0));
        final main = game.nodes[ordered.first]!;
        moveSpan(node, main, forceNumber: needNumber, depth: depth);
        needNumber = false;
        for (final alt in ordered.skip(1)) {
          spans.add(TextSpan(text: ' (', style: TextStyle(color: theme.colorScheme.outline)));
          final altNode = game.nodes[alt]!;
          moveSpan(node, altNode, forceNumber: true, depth: depth + 1);
          line(altNode, forceNumber: true, depth: depth + 1);
          spans.add(TextSpan(text: ') ', style: TextStyle(color: theme.colorScheme.outline)));
          needNumber = true;
        }
        node = main;
      }
    }

    line(game.root, forceNumber: false, depth: 0);
    if (spans.isEmpty) {
      return Text('No moves yet.', style: theme.textTheme.bodySmall);
    }
    if (game.isFinished) {
      spans.add(TextSpan(text: '  ${game.result}', style: const TextStyle(fontWeight: FontWeight.w700)));
    }
    return Text.rich(TextSpan(children: spans));
  }
}
