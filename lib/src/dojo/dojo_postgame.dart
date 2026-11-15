part of '../../main.dart';

/// Runs Stockfish over the deciding line of [game] and stores the report.
Future<PostGameReport> analyseDojoGame(
  DojoGame game, {
  required int movetimeMs,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final line = game.finalLine;
  final engine = DojoEngine.instance;
  final evals = <int, EngineAnalysis>{};
  for (final (i, node) in line.indexed) {
    if (isCancelled?.call() == true) throw StateError('cancelled');
    final cached = node.analysis;
    evals[node.id] = cached != null && cached.lines.isNotEmpty
        ? cached
        : await engine.analyze(node.fen, multiPv: 1, movetimeMs: movetimeMs);
    onProgress?.call(i + 1, line.length);
  }
  final moves = <PostGameMove>[];
  for (var i = 1; i < line.length; i++) {
    final parent = line[i - 1];
    final node = line[i];
    final before = evals[parent.id]!;
    final after = evals[node.id]!;
    final bestUci = before.bestMove;
    final isBest = bestUci == node.uci;
    final moverBefore = before.score;
    final moverAfter = isBest ? max(moverBefore, -after.score) : -after.score;
    final quality = MoveVerdict.classify(moverBefore, moverAfter, best: isBest);
    final byPlayer = parent.turn == game.playerSide;
    moves.add(PostGameMove(
      ply: i,
      san: node.san!,
      uci: node.uci!,
      byPlayer: byPlayer,
      fenBefore: parent.fen,
      whiteEvalBefore: before.whiteScore,
      whiteEvalAfter: isBest ? before.whiteScore : after.whiteScore,
      quality: quality,
      accuracy: moveAccuracy(winPercent(moverBefore), winPercent(moverAfter)),
      centipawnLoss: max(0, moverBefore.clamp(-1000, 1000) - moverAfter.clamp(-1000, 1000)),
      bestSan: bestUci == null ? null : DojoChess.sanOf(parent.fen, bestUci),
      bestLine: before.lines.isEmpty ? null : DojoChess.pvToSan(parent.fen, before.lines.first.pv, maxMoves: 6),
    ));
    if (byPlayer && node.verdict == null && bestUci != null) {
      node.verdict = MoveVerdict(
        quality: quality,
        playedUci: node.uci!,
        playedSan: node.san!,
        bestUci: bestUci,
        bestSan: DojoChess.sanOf(parent.fen, bestUci),
        scoreBefore: moverBefore,
        scoreAfter: moverAfter,
      );
    }
  }
  return PostGameReport(moves: moves, analyzedAt: DateTime.now(), movetimeMs: movetimeMs);
}

CoachSession dojoReviewSession(
  DojoGame game, {
  void Function(DojoBoardScene scene)? onScene,
}) {
  late final CoachSession session;
  session = CoachSession(
    conversation: game.review,
    system: DojoPrompts.review,
    tools: [
      ...CoachTools.chess,
      CoachTools.showOnBoard(
        game: game,
        onScene: (scene) {
          session.currentReply?.scenes.add(scene);
          onScene?.call(scene);
        },
      ),
    ],
    kind: 'review',
    onPersist: () => DojoStore.instance.save(game),
    // The full Stockfish report goes with the first message of the thread.
    contextBuilder: () => (
      game.review.apiMessages.isEmpty ? DojoReviewContext.gameReport(game) : '',
      null,
    ),
  );
  return session;
}

/// One board position shown in the coach tab.
class _BoardStep {
  const _BoardStep(this.fen, this.uci, this.san);
  final String fen;
  final String? uci;
  final String? san;
}

class DojoPostGamePage extends StatefulWidget {
  const DojoPostGamePage({required this.game, this.autoStart = true, this.initialTab = 0, super.key});

  final DojoGame game;
  final bool autoStart;
  final int initialTab;

  @override
  State<DojoPostGamePage> createState() => _DojoPostGamePageState();
}

class _DojoPostGamePageState extends State<DojoPostGamePage> {
  DojoGame get game => widget.game;
  late final CoachSession _review = dojoReviewSession(game, onScene: _showScene);
  final ScrollController _movesScroll = ScrollController();
  static const _rowHeight = 34.0;
  bool _running = false;
  int _done = 0;
  int _total = 0;
  String? _error;
  int _selectedPly = 1;
  bool _showBest = false;
  bool _disposed = false;
  DojoAnalysisDepth _depth = DojoSettings.instance.analysisDepth;

  // Coach-tab board.
  DojoBoardScene? _scene;
  bool _sceneActual = false;
  int _sceneStep = 0;

  @override
  void initState() {
    super.initState();
    if (game.postGame == null && widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
    final report = game.postGame;
    if (report != null) _selectedPly = _firstErrorPly(report);
    _scene = _latestScene();
  }

  @override
  void dispose() {
    _disposed = true;
    _review.dispose();
    _movesScroll.dispose();
    super.dispose();
  }

  int _firstErrorPly(PostGameReport report) =>
      report.moves.where((m) => m.byPlayer && m.quality.isError).firstOrNull?.ply ?? 1;

  DojoBoardScene? _latestScene() {
    for (final entry in game.review.entries.reversed) {
      if (entry.scenes.isNotEmpty) return entry.scenes.last;
    }
    return null;
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _done = 0;
    });
    try {
      final report = await analyseDojoGame(
        game,
        movetimeMs: _depth.movetimeMs,
        isCancelled: () => _disposed,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      game.postGame = report;
      _selectedPly = _firstErrorPly(report);
      await DojoStore.instance.save(game);
    } catch (error) {
      if (!_disposed) _error = 'Analysis failed: $error';
    }
    if (mounted) setState(() => _running = false);
  }

  void _select(int ply) {
    final report = game.postGame;
    if (report == null || report.moves.isEmpty) return;
    final next = ply.clamp(1, report.moves.length);
    setState(() {
      _selectedPly = next;
      _showBest = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_movesScroll.hasClients) return;
      final target = ((next - 1) * _rowHeight - _movesScroll.position.viewportDimension / 2 + _rowHeight)
          .clamp(0.0, _movesScroll.position.maxScrollExtent);
      _movesScroll.animateTo(target, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    });
  }

  void _showScene(DojoBoardScene scene) {
    if (!mounted) return;
    setState(() {
      _scene = scene;
      _sceneActual = false;
      _sceneStep = scene.moves.isEmpty ? 0 : 1;
    });
  }

  void _quickReview() => unawaited(_review.send('Please give me a quick review of this game.'));

  String? _bestUci(PostGameMove m) =>
      m.bestSan == null ? null : DojoChess.play(m.fenBefore, m.bestSan!)?.uci;

  @override
  Widget build(BuildContext context) {
    final report = game.postGame;
    return DefaultTabController(
      length: 3,
      initialIndex: report == null ? 0 : widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Game report'),
          actions: [
            IconButton(
              tooltip: 'Copy PGN',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: game.toPgn()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PGN copied')));
                }
              },
            ),
          ],
          bottom: report == null
              ? null
              : const TabBar(
                  tabs: [
                    Tab(key: ValueKey('dojo-tab-moves'), text: 'Moves'),
                    Tab(key: ValueKey('dojo-tab-summary'), text: 'Summary'),
                    Tab(key: ValueKey('dojo-ai-review'), text: 'AI coach'),
                  ],
                ),
        ),
        body: report == null
            ? _pending()
            : TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [_movesTab(report), _summaryTab(report), _coachTab()],
              ),
      ),
    );
  }

  Widget _pending() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _resultHeader(),
        const SizedBox(height: 16),
        if (_running) ...[
          Text('Stockfish is analysing every move…', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
          const SizedBox(height: 4),
          Text(
            '$_done / $_total positions (positions analysed during the game are reused)',
            style: theme.textTheme.bodySmall,
          ),
        ] else ...[
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          SegmentedButton<DojoAnalysisDepth>(
            segments: [
              for (final d in DojoAnalysisDepth.values) ButtonSegment(value: d, label: Text(d.label)),
            ],
            selected: {_depth},
            onSelectionChanged: (s) => setState(() => _depth = s.first),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _run,
            icon: const Icon(Icons.insights),
            label: const Text('Analyze with Stockfish'),
          ),
        ],
      ],
    );
  }

  Widget _resultHeader() {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          switch (game.playerScore) {
            1 => Icons.emoji_events,
            0 => Icons.sentiment_dissatisfied_outlined,
            0.5 => Icons.handshake_outlined,
            _ => Icons.hourglass_empty,
          },
          size: 32,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${game.outcomeLabel} vs ${game.opponent.label}', style: theme.textTheme.titleLarge),
              Text(
                '${game.result ?? 'Unfinished'}${game.resultReason == null ? '' : ' · ${game.resultReason}'}'
                ' · you played ${game.playerIsWhite ? 'White' : 'Black'}'
                '${game.takebackCount > 0 ? ' · ${game.takebackCount} takeback${game.takebackCount == 1 ? '' : 's'}' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Board size that leaves [reserve] logical pixels for everything else.
  double _boardSize(BoxConstraints c, {required double reserve, double minSize = 180}) =>
      min(c.maxWidth - 24, c.maxHeight - reserve).clamp(minSize, 560.0);

  Widget _board(double size, {required String fen, String? lastUci, Set<cg.Shape> shapes = const {}}) =>
      cg.StaticChessboard(
        size: size,
        orientation: game.playerIsWhite ? dc.Side.white : dc.Side.black,
        fen: fen,
        lastMove: lastUci == null ? null : dc.Move.parse(lastUci),
        settings: boardPreferencesOf(context).editorSettings,
        shapes: shapes,
      );

  Widget _movesTab(PostGameReport report) {
    final theme = Theme.of(context);
    if (report.moves.isEmpty) return const Center(child: Text('No moves to show.'));
    final m = report.moves[_selectedPly - 1];
    final canShowBest = m.bestSan != null && _bestUci(m) != m.uci;
    final showBest = _showBest && canShowBest;
    final fenAfter = DojoChess.play(m.fenBefore, m.uci)?.fen ?? m.fenBefore;
    return LayoutBuilder(
      builder: (context, c) {
        final size = _boardSize(c, reserve: 8 + 52 + 64 + 170);
        return Column(
          children: [
            const SizedBox(height: 8),
            _board(
              size,
              fen: showBest ? m.fenBefore : fenAfter,
              lastUci: showBest ? null : m.uci,
              shapes: showBest ? _errorArrows(m) : const {},
            ),
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Previous move',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: _selectedPly > 1 ? () => _select(_selectedPly - 1) : null,
                  ),
                  MoveQualityBadge(m.quality, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      showBest && m.bestLine != null
                          ? 'Best: ${m.bestLine}'
                          : '${m.moveLabel} · ${m.quality.label}'
                                '${m.bestSan != null && m.quality.isError ? ' · best ${m.bestSan}' : ''}',
                      key: const ValueKey('dojo-report-caption'),
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (canShowBest)
                    FilterChip(
                      key: const ValueKey('dojo-show-best'),
                      visualDensity: VisualDensity.compact,
                      label: const Text('Best'),
                      selected: _showBest,
                      onSelected: (v) => setState(() => _showBest = v),
                    ),
                  IconButton(
                    tooltip: 'Next move',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: _selectedPly < report.moves.length ? () => _select(_selectedPly + 1) : null,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SizedBox(
                height: 56,
                child: DojoEvalGraph(
                  report: report,
                  playerIsWhite: game.playerIsWhite,
                  selectedPly: _selectedPly,
                  onSelect: _select,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('dojo-report-moves'),
                controller: _movesScroll,
                itemExtent: _rowHeight,
                itemCount: report.moves.length,
                itemBuilder: (context, i) => _moveRow(report.moves[i]),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _moveRow(PostGameMove m) {
    final theme = Theme.of(context);
    final selected = _selectedPly == m.ply;
    return InkWell(
      onTap: () => _select(m.ply),
      child: Container(
        color: selected ? theme.colorScheme.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Text(
                m.moveLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: m.byPlayer ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            MoveQualityBadge(m.quality, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                m.quality.isError && m.bestSan != null ? '${m.quality.label} · best ${m.bestSan}' : m.quality.label,
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              formatWhiteEval(m.whiteEvalAfter),
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryTab(PostGameReport report) {
    final theme = Theme.of(context);
    final you = report.player;
    final them = report.opponent;
    final comparison = you.estimatedElo >= game.opponent.nominalElo
        ? 'above'
        : (game.opponent.nominalElo - you.estimatedElo) < 150
        ? 'close to'
        : 'below';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _resultHeader(),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You played at roughly ${you.estimatedElo} strength',
                  key: const ValueKey('dojo-perf-elo'),
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  'That is $comparison your opponent (${game.opponent.label}'
                  '${game.opponent.fullStrength ? ', ~3500' : ''}). Estimate from average centipawn loss — rough on short games.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                Table(
                  columnWidths: const {0: FlexColumnWidth(1.3)},
                  children: [
                    TableRow(children: [
                      const SizedBox(),
                      Text('You', style: theme.textTheme.labelLarge),
                      Text(game.opponent.name, style: theme.textTheme.labelLarge),
                    ]),
                    _row('Accuracy', '${you.accuracy.round()}%', '${them.accuracy.round()}%'),
                    _row('Avg. centipawn loss', '${you.acpl.round()}', '${them.acpl.round()}'),
                    _row('Performance', '~${you.estimatedElo}', '~${them.estimatedElo}'),
                    for (final q in [MoveQuality.blunder, MoveQuality.mistake, MoveQuality.inaccuracy])
                      _row(q.plural, '${you.counts[q] ?? 0}', '${them.counts[q] ?? 0}'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('Evaluation (tap to open that move)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Builder(
          builder: (context) => SizedBox(
            height: 110,
            child: DojoEvalGraph(
              report: report,
              playerIsWhite: game.playerIsWhite,
              selectedPly: _selectedPly,
              onSelect: (ply) {
                _select(ply);
                DefaultTabController.of(context).animateTo(0);
              },
            ),
          ),
        ),
      ],
    );
  }

  List<_BoardStep> _sceneSteps(DojoBoardScene scene, {required bool actual}) {
    final line = actual ? scene.actual : scene.moves;
    final steps = [_BoardStep(scene.fen, null, null)];
    var fen = scene.fen;
    for (final move in line) {
      final step = DojoChess.play(fen, move);
      if (step == null) break;
      fen = step.fen;
      steps.add(_BoardStep(fen, step.uci, step.san));
    }
    return steps;
  }

  Widget _coachTab() {
    final theme = Theme.of(context);
    final scene = _scene;
    return LayoutBuilder(
      builder: (context, c) {
        final size = _boardSize(c, reserve: max(300.0, c.maxHeight * 0.5) + 50, minSize: 150);
        final steps = scene == null ? const <_BoardStep>[] : _sceneSteps(scene, actual: _sceneActual);
        final index = steps.isEmpty ? 0 : _sceneStep.clamp(0, steps.length - 1);
        final step = steps.isEmpty ? null : steps[index];
        final last = game.finalLine.last;
        return Column(
          children: [
            const SizedBox(height: 6),
            _board(size, fen: step?.fen ?? last.fen, lastUci: step == null ? last.uci : step.uci),
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Step back',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: step == null || index == 0 ? null : () => setState(() => _sceneStep = index - 1),
                  ),
                  Expanded(
                    child: Text(
                      scene == null
                          ? 'Final position · lines the coach shows appear here'
                          : '${scene.title}${step?.san == null ? '' : ' · ${step!.san}'}',
                      key: const ValueKey('dojo-scene-title'),
                      style: theme.textTheme.labelLarge,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (scene != null && scene.actual.isNotEmpty)
                    SegmentedButton<bool>(
                      key: const ValueKey('dojo-scene-toggle'),
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: false, label: Text('Coach')),
                        ButtonSegment(value: true, label: Text('Game')),
                      ],
                      selected: {_sceneActual},
                      onSelectionChanged: (v) => setState(() {
                        _sceneActual = v.first;
                        _sceneStep = 1;
                      }),
                    ),
                  IconButton(
                    tooltip: 'Step forward',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: step == null || index >= steps.length - 1
                        ? null
                        : () => setState(() => _sceneStep = index + 1),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: CoachChatView(
                session: _review,
                title: 'AI coach',
                embedded: true,
                onScene: _showScene,
                headerAction: FilledButton.tonalIcon(
                  key: const ValueKey('dojo-quick-review'),
                  style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: _review.busy ? null : _quickReview,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Quick review'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Set<cg.Shape> _errorArrows(PostGameMove move) {
    final shapes = <cg.Shape>{};
    final played = dc.Move.parse(move.uci);
    if (played is dc.NormalMove) {
      shapes.add(cg.Arrow(color: const Color(0xB0D03030), orig: played.from, dest: played.to));
    }
    final best = _bestUci(move);
    final parsed = best == null ? null : dc.Move.parse(best);
    if (parsed is dc.NormalMove) {
      shapes.add(cg.Arrow(color: const Color(0xC015781B), orig: parsed.from, dest: parsed.to));
    }
    return shapes;
  }

  TableRow _row(String label, String you, String them) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return TableRow(children: [
      Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(label, style: style)),
      Text(you, style: style?.copyWith(fontWeight: FontWeight.w600)),
      Text(them, style: style),
    ]);
  }
}

// Evaluation graph (White advantage up), tap to select a move.
class DojoEvalGraph extends StatelessWidget {
  const DojoEvalGraph({
    required this.report,
    required this.playerIsWhite,
    required this.onSelect,
    this.selectedPly,
    super.key,
  });

  final PostGameReport report;
  final bool playerIsWhite;
  final int? selectedPly;
  final void Function(int ply) onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onTapDown: (d) => _select(d.localPosition.dx, constraints.maxWidth),
        onHorizontalDragUpdate: (d) => _select(d.localPosition.dx, constraints.maxWidth),
        child: CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _EvalGraphPainter(report, selectedPly, scheme),
        ),
      ),
    );
  }

  void _select(double x, double width) {
    final n = report.moves.length;
    if (n == 0) return;
    final ply = ((x / width) * n).floor().clamp(0, n - 1) + 1;
    onSelect(ply);
  }
}

class _EvalGraphPainter extends CustomPainter {
  _EvalGraphPainter(this.report, this.selected, this.scheme);

  final PostGameReport report;
  final int? selected;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final moves = report.moves;
    final background = Paint()..color = const Color(0xFF3A3A3A);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)), background);
    if (moves.isEmpty) return;
    double y(int whiteCp) => size.height * (1 - winPercent(whiteCp) / 100);
    final step = size.width / moves.length;
    final path = Path()..moveTo(0, size.height);
    path.lineTo(0, y(moves.first.whiteEvalBefore));
    for (final (i, m) in moves.indexed) {
      path.lineTo((i + 1) * step, y(m.whiteEvalAfter));
    }
    path
      ..lineTo(size.width, size.height)
      ..close();
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)));
    canvas.drawPath(path, Paint()..color = const Color(0xFFEDEDED));
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()
        ..color = Colors.grey
        ..strokeWidth = 0.5,
    );
    for (final (i, m) in moves.indexed) {
      if (!m.byPlayer || !m.quality.isError) continue;
      final x = (i + 1) * step;
      canvas.drawCircle(Offset(x, y(m.whiteEvalAfter)), 3.5, Paint()..color = m.quality.color(scheme));
    }
    if (selected != null) {
      final x = selected! * step;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = scheme.primary
          ..strokeWidth = 2,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EvalGraphPainter old) =>
      old.report != report || old.selected != selected;
}
