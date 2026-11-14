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

CoachSession dojoReviewSession(DojoGame game) => CoachSession(
  conversation: game.review,
  system: DojoPrompts.review,
  tools: CoachTools.chess,
  kind: 'review',
  onPersist: () => DojoStore.instance.save(game),
);

class DojoPostGamePage extends StatefulWidget {
  const DojoPostGamePage({required this.game, this.autoStart = true, super.key});

  final DojoGame game;
  final bool autoStart;

  @override
  State<DojoPostGamePage> createState() => _DojoPostGamePageState();
}

class _DojoPostGamePageState extends State<DojoPostGamePage> {
  DojoGame get game => widget.game;
  late final CoachSession _review = dojoReviewSession(game);
  bool _running = false;
  int _done = 0;
  int _total = 0;
  String? _error;
  int? _selectedPly;
  bool _disposed = false;
  DojoAnalysisDepth _depth = DojoSettings.instance.analysisDepth;

  @override
  void initState() {
    super.initState();
    if (game.postGame == null && widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _review.dispose();
    super.dispose();
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
      await DojoStore.instance.save(game);
    } catch (error) {
      if (!_disposed) _error = 'Analysis failed: $error';
    }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _openReview() {
    final first = game.review.isEmpty;
    return showCoachSheet(
      context,
      session: _review,
      title: 'AI game review',
      initialPrompt: first ? 'Please review my game.' : null,
      initialContext: first ? DojoReviewContext.gameReport(game) : null,
      suggestions: const [
        'What was my biggest mistake?',
        'How did the opening go?',
        'What should I practise?',
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = game.postGame;
    return Scaffold(
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
      ),
      floatingActionButton: report == null
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('dojo-ai-review'),
              onPressed: _openReview,
              icon: const Icon(Icons.psychology_alt_outlined),
              label: Text(game.review.isEmpty ? 'AI review' : 'AI review chat'),
            ),
      body: report == null ? _pending() : _report(report),
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
          Text('$_done / $_total positions', style: theme.textTheme.bodySmall),
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
              Text(
                '${game.outcomeLabel} vs ${game.opponent.label}',
                style: theme.textTheme.titleLarge,
              ),
              Text(
                '${game.result ?? 'Unfinished'}${game.resultReason == null ? '' : ' · ${game.resultReason}'}'
                ' · you played ${game.playerIsWhite ? 'White' : 'Black'}'
                '${game.undoCount > 0 ? ' · ${game.undoCount} undo${game.undoCount == 1 ? '' : 's'}' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _report(PostGameReport report) {
    final theme = Theme.of(context);
    final you = report.player;
    final them = report.opponent;
    final selected = _selectedPly == null ? null : report.moves[_selectedPly! - 1];
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final boardSize = min(MediaQuery.sizeOf(context).width - 32, wide ? 420.0 : 360.0);
    final comparison = you.estimatedElo >= game.opponent.nominalElo
        ? 'above'
        : (game.opponent.nominalElo - you.estimatedElo) < 150
        ? 'close to'
        : 'below';

    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                      _row('${q.label}s', '${you.counts[q] ?? 0}', '${them.counts[q] ?? 0}'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('Evaluation', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        SizedBox(
          height: 110,
          child: DojoEvalGraph(
            report: report,
            playerIsWhite: game.playerIsWhite,
            selectedPly: _selectedPly,
            onSelect: (ply) => setState(() => _selectedPly = ply),
          ),
        ),
      ],
    );

    final board = selected == null
        ? null
        : Column(
            children: [
              cg.StaticChessboard(
                size: boardSize,
                orientation: game.playerIsWhite ? dc.Side.white : dc.Side.black,
                fen: selected.fenBefore,
                lastMove: dc.Move.parse(selected.uci),
                settings: boardPreferencesOf(context).editorSettings,
                shapes: {
                  if (selected.quality.isError && selected.bestSan != null)
                    ..._bestArrow(selected),
                },
              ),
              const SizedBox(height: 4),
              Text(
                '${selected.moveLabel} — ${selected.quality.label}'
                '${selected.quality.isError && selected.bestSan != null ? '. Best: ${selected.bestLine ?? selected.bestSan}' : ''}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          );

    final moveList = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Moves', style: theme.textTheme.titleSmall),
        for (final m in report.moves)
          InkWell(
            onTap: () => setState(() => _selectedPly = m.ply),
            child: Container(
              color: _selectedPly == m.ply ? theme.colorScheme.primaryContainer : null,
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 92,
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
                      m.quality.isError && m.bestSan != null
                          ? '${m.quality.label} · best ${m.bestSan}'
                          : m.quality.label,
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
          ),
        const SizedBox(height: 80),
      ],
    );

    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [summary, const SizedBox(height: 12), ?board],
            ),
          ),
          SizedBox(
            width: 420,
            child: ListView(padding: const EdgeInsets.all(16), children: [moveList]),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        summary,
        const SizedBox(height: 12),
        if (board != null) ...[board, const SizedBox(height: 12)],
        moveList,
      ],
    );
  }

  Set<cg.Shape> _bestArrow(PostGameMove move) {
    final best = DojoChess.play(move.fenBefore, move.bestSan!);
    final parsed = best == null ? null : dc.Move.parse(best.uci);
    if (parsed is! dc.NormalMove) return {};
    return {cg.Arrow(color: const Color(0xC015781B), orig: parsed.from, dest: parsed.to)};
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

/// Evaluation graph (White advantage up), tap to select a move.
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
