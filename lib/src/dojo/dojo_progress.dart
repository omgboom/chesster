part of '../../main.dart';

/// Text block describing all games, sent with progress-coach requests.
String dojoProgressContext(List<DojoGameSummary> games) {
  final analysed = games.where((g) => g.playerElo != null).toList();
  final finished = games.where((g) => g.result != null).toList();
  final wins = finished.where((g) => g.playerScore == 1).length;
  final draws = finished.where((g) => g.playerScore == 0.5).length;
  final losses = finished.where((g) => g.playerScore == 0).length;
  final buffer = StringBuffer()
    ..writeln('[Training summary as of ${DateTime.now().toIso8601String().substring(0, 10)}]')
    ..writeln('${games.length} games stored, ${finished.length} finished: $wins wins, $draws draws, $losses losses. '
        '${analysed.length} analysed with Stockfish.')
    ..writeln('Games, oldest first:');
  for (final g in games.reversed) {
    buffer.writeln('- ${g.describe()}');
  }
  buffer.write('[/Training summary]');
  return buffer.toString();
}

class DojoProgressPage extends StatefulWidget {
  const DojoProgressPage({super.key});

  @override
  State<DojoProgressPage> createState() => _DojoProgressPageState();
}

class _DojoProgressPageState extends State<DojoProgressPage> {
  List<DojoGame>? _games;
  CoachSession? _coach;
  bool _batchRunning = false;
  String? _batchStatus;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    _coach?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final games = await DojoStore.instance.loadAll();
    final conversation = await DojoStore.instance.loadProgressChat();
    if (!mounted) return;
    _coach ??= CoachSession(
      conversation: conversation,
      system: DojoPrompts.progress,
      tools: [
        ...CoachTools.chess,
        CoachTools.getGame(DojoStore.instance.load),
      ],
      kind: 'progress',
      onPersist: () => DojoStore.instance.saveProgressChat(conversation),
    );
    setState(() => _games = games);
  }

  List<DojoGameSummary> get _summaries => [for (final g in _games ?? const <DojoGame>[]) DojoGameSummary.of(g)];

  Future<void> _askCoach({bool analyse = false}) async {
    final coach = _coach;
    if (coach == null) return;
    final summaries = _summaries;
    final first = coach.conversation.isEmpty;
    await showCoachSheet(
      context,
      session: coach,
      title: 'Progress coach',
      initialPrompt: analyse || first
          ? 'Analyse my progress and give me a training plan.'
          : null,
      initialContext: analyse || first ? dojoProgressContext(summaries) : null,
      suggestions: const [
        'What is my biggest weakness?',
        'Which opponent level should I play next?',
        'Am I improving?',
      ],
    );
  }

  Future<void> _analyseAll() async {
    final pending = (_games ?? const <DojoGame>[]).where((g) => g.isFinished && g.postGame == null).toList();
    if (pending.isEmpty) return;
    setState(() => _batchRunning = true);
    for (final (i, game) in pending.indexed) {
      if (_disposed) return;
      setState(() => _batchStatus = 'Analysing game ${i + 1} of ${pending.length}…');
      try {
        game.postGame = await analyseDojoGame(
          game,
          movetimeMs: DojoAnalysisDepth.quick.movetimeMs,
          isCancelled: () => _disposed,
        );
        await DojoStore.instance.save(game);
      } catch (_) {
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _batchRunning = false;
      _batchStatus = null;
    });
  }

  Future<void> _open(DojoGame game) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => game.isFinished ? DojoPostGamePage(game: game) : DojoGamePage(game: game),
      ),
    );
    await _load();
  }

  Future<void> _delete(DojoGame game) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this game?'),
        content: const Text('Its moves, analysis and chats are permanently removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await DojoStore.instance.delete(game.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    return Scaffold(
      appBar: AppBar(title: const Text('Progress')),
      floatingActionButton: games == null || games.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('dojo-progress-coach'),
              onPressed: () => _askCoach(analyse: true),
              icon: const Icon(Icons.psychology_alt_outlined),
              label: const Text('Analyze my progress'),
            ),
      body: games == null
          ? const Center(child: CircularProgressIndicator())
          : games.isEmpty
          ? const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Play some Dojo games and your progress will appear here.', textAlign: TextAlign.center),
            ))
          : _content(games),
    );
  }

  Widget _content(List<DojoGame> games) {
    final theme = Theme.of(context);
    final summaries = _summaries;
    final finished = summaries.where((g) => g.result != null).toList();
    final analysed = summaries.where((g) => g.playerElo != null).toList();
    final recent = analysed.take(10).toList();
    double avg(Iterable<num> values) => values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;
    final unanalysed = games.where((g) => g.isFinished && g.postGame == null).length;
    final byOpponent = <String, List<DojoGameSummary>>{};
    for (final g in finished) {
      final key = '${g.opponent.name} ${g.opponent.fullStrength ? 'max' : '${(g.opponent.elo ~/ 100) * 100}s'}';
      byOpponent.putIfAbsent(key, () => []).add(g);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _tile('Games', '${summaries.length}'),
            _tile(
              'Record',
              '${finished.where((g) => g.playerScore == 1).length}W '
                  '${finished.where((g) => g.playerScore == 0.5).length}D '
                  '${finished.where((g) => g.playerScore == 0).length}L',
            ),
            _tile('Accuracy (last 10)', recent.isEmpty ? '–' : '${avg(recent.map((g) => g.playerAccuracy!)).round()}%'),
            _tile('Performance (last 10)', recent.isEmpty ? '–' : '~${avg(recent.map((g) => g.playerElo!)).round()}'),
          ],
        ),
        const SizedBox(height: 16),
        if (analysed.length >= 2) ...[
          Text('Performance rating over time', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          SizedBox(height: 160, child: DojoProgressChart(games: analysed.reversed.toList())),
          const SizedBox(height: 4),
          Text(
            'Dots: green win · grey draw · red loss. Line: 5-game average.',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 16),
        ],
        if (unanalysed > 0)
          Card(
            child: ListTile(
              leading: _batchRunning
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.insights),
              title: Text(_batchStatus ?? '$unanalysed finished game${unanalysed == 1 ? '' : 's'} not analysed yet'),
              subtitle: const Text('Quick Stockfish pass so they count in your stats'),
              trailing: _batchRunning ? null : TextButton(onPressed: _analyseAll, child: const Text('Analyze')),
            ),
          ),
        if (byOpponent.isNotEmpty) ...[
          Text('By opponent', style: theme.textTheme.titleSmall),
          for (final entry in byOpponent.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(entry.key)),
                  Text(
                    '${entry.value.where((g) => g.playerScore == 1).length}W '
                    '${entry.value.where((g) => g.playerScore == 0.5).length}D '
                    '${entry.value.where((g) => g.playerScore == 0).length}L',
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            Expanded(child: Text('Games', style: theme.textTheme.titleSmall)),
            if (_coach != null && !_coach!.conversation.isEmpty)
              TextButton.icon(
                onPressed: () => _askCoach(),
                icon: const Icon(Icons.forum_outlined, size: 18),
                label: const Text('Coach chat'),
              ),
          ],
        ),
        for (final (i, game) in games.indexed)
          _GameTile(
            game: game,
            summary: summaries[i],
            onTap: () => _open(game),
            onLongPress: () => _delete(game),
          ),
      ],
    );
  }

  Widget _tile(String label, String value) {
    final theme = Theme.of(context);
    return SizedBox(
      width: (MediaQuery.sizeOf(context).width - 40) / 2 > 220 ? 200 : (MediaQuery.sizeOf(context).width - 40) / 2,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: 2),
              Text(value, style: theme.textTheme.titleLarge),
            ],
          ),
        ),
      ),
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({required this.game, required this.summary, required this.onTap, required this.onLongPress});

  final DojoGame game;
  final DojoGameSummary summary;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (summary.playerScore) {
      1 => const Color(0xFF2E9E5B),
      0 => const Color(0xFFD03030),
      0.5 => Colors.grey,
      _ => theme.colorScheme.outline,
    };
    final date = MaterialLocalizations.of(context).formatShortDate(summary.started);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Text(
          switch (summary.playerScore) { 1 => 'W', 0 => 'L', 0.5 => 'D', _ => '…' },
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
      ),
      title: Text('vs ${summary.opponent.label} · ${summary.playerIsWhite ? 'White' : 'Black'}'),
      subtitle: Text([
        date,
        '${summary.moveCount} moves',
        if (summary.playerAccuracy != null) '${summary.playerAccuracy!.round()}%',
        if (summary.playerElo != null) '~${summary.playerElo}',
        if (summary.hasAiReview) 'AI review',
      ].join(' · ')),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class DojoProgressChart extends StatelessWidget {
  const DojoProgressChart({required this.games, super.key});

  /// Analysed games, oldest first.
  final List<DojoGameSummary> games;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _ProgressPainter(games, Theme.of(context)), size: Size.infinite);
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter(this.games, this.theme);

  final List<DojoGameSummary> games;
  final ThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    if (games.isEmpty) return;
    final values = [for (final g in games) g.playerElo!.toDouble()];
    final lo = ((values.reduce(min) - 100) / 100).floor() * 100.0;
    final hi = ((values.reduce(max) + 100) / 100).ceil() * 100.0;
    const left = 36.0;
    final width = size.width - left - 6;
    final height = size.height - 14;
    double x(int i) => left + (games.length == 1 ? width / 2 : width * i / (games.length - 1));
    double y(double v) => 4 + height * (1 - (v - lo) / max(1, hi - lo));
    final grid = Paint()
      ..color = theme.colorScheme.outlineVariant
      ..strokeWidth = 0.5;
    final label = theme.textTheme.labelSmall!.copyWith(color: theme.colorScheme.outline);
    for (var v = lo; v <= hi; v += max(100, ((hi - lo) / 4 / 100).round() * 100)) {
      canvas.drawLine(Offset(left, y(v)), Offset(size.width, y(v)), grid);
      final tp = TextPainter(text: TextSpan(text: v.round().toString(), style: label), textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(0, y(v) - tp.height / 2));
    }
    final avgPath = Path();
    for (var i = 0; i < games.length; i++) {
      final window = values.sublist(max(0, i - 4), i + 1);
      final avg = window.reduce((a, b) => a + b) / window.length;
      i == 0 ? avgPath.moveTo(x(i), y(avg)) : avgPath.lineTo(x(i), y(avg));
    }
    canvas.drawPath(
      avgPath,
      Paint()
        ..color = theme.colorScheme.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    for (final (i, g) in games.indexed) {
      final color = switch (g.playerScore) {
        1 => const Color(0xFF2E9E5B),
        0 => const Color(0xFFD03030),
        _ => Colors.grey,
      };
      canvas.drawCircle(Offset(x(i), y(values[i])), 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _ProgressPainter old) => old.games != games;
}
