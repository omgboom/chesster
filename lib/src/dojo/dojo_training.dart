part of '../../main.dart';

/// Starts a training game and opens it.
Future<void> startDojoTraining(
  BuildContext context, {
  OpeningLesson? opening,
  EndgameLesson? endgame,
}) async {
  final settings = DojoSettings.instance;
  final DojoGame game;
  if (opening != null) {
    game = DojoGame.create(
      opponent: settings.opponent,
      playerIsWhite: opening.playerIsWhite,
      training: DojoTraining(kind: 'opening', lessonId: opening.id),
    );
  } else {
    game = DojoGame.create(
      opponent: const DojoOpponent(kind: DojoOpponentKind.stockfish, elo: dojoStockfishMaxElo, fullStrength: true),
      playerIsWhite: endgame!.playerIsWhite,
      training: DojoTraining(kind: 'endgame', lessonId: endgame.id),
      startFen: endgame.fen,
    );
  }
  await DojoStore.instance.save(game);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DojoGamePage(game: game)));
}

class DojoTrainingPage extends StatelessWidget {
  const DojoTrainingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Training'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Openings'),
              Tab(text: 'Endgames'),
              Tab(key: ValueKey('dojo-tab-drills'), text: 'My mistakes'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_OpeningsTab(), _EndgamesTab(), DojoMistakeDrills()],
        ),
      ),
    );
  }
}

class _OpeningsTab extends StatelessWidget {
  const _OpeningsTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opponent = DojoSettings.instance.opponent;
    Widget section(String title, bool white) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(title, style: theme.textTheme.titleMedium),
        ),
        for (final lesson in DojoTrainingCatalog.forColour(white))
          ListTile(
            key: ValueKey('dojo-opening-${lesson.id}'),
            leading: CircleAvatar(child: Text('${lesson.level}')),
            title: Text(lesson.name),
            subtitle: Text('${lesson.eco} · ${lesson.summary}', maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => startDojoTraining(context, opening: lesson),
          ),
      ],
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'The coach walks you through each opening move by move with short explanations. '
            'Then you play the rest of the game against ${opponent.label} (change it on the home screen). '
            'Numbers show the recommended learning order.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        section('As White', true),
        section('As Black', false),
      ],
    );
  }
}

class _EndgamesTab extends StatelessWidget {
  const _EndgamesTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lessons = [...DojoTrainingCatalog.endgames]..sort((a, b) => a.level.compareTo(b.level));
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'A few pointers, then you are on your own against full-strength Stockfish. '
            'Back/Forward and branching work as usual, so retry freely.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final lesson in lessons)
          ListTile(
            key: ValueKey('dojo-endgame-${lesson.id}'),
            leading: CircleAvatar(child: Text('${lesson.level}')),
            title: Text(lesson.name),
            subtitle: Text('Goal: ${lesson.goal} · you play ${lesson.playerIsWhite ? 'White' : 'Black'}'),
            onTap: () => startDojoTraining(context, endgame: lesson),
          ),
      ],
    );
  }
}

/// A position from one of your games where you went wrong.
class DojoDrill {
  const DojoDrill({required this.game, required this.move});
  final DojoGame game;
  final PostGameMove move;
}

/// "Find the better move" puzzles built from your analysed games.
class DojoMistakeDrills extends StatefulWidget {
  const DojoMistakeDrills({super.key});

  @override
  State<DojoMistakeDrills> createState() => _DojoMistakeDrillsState();
}

class _DojoMistakeDrillsState extends State<DojoMistakeDrills> {
  List<DojoDrill>? _drills;
  int _index = 0;
  String? _feedback;
  bool _solved = false;
  bool _revealed = false;
  cg.ChessboardController? _board;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final games = await DojoStore.instance.loadAll();
    final drills = <DojoDrill>[
      for (final g in games)
        for (final m in g.postGame?.moves ?? const <PostGameMove>[])
          if (m.byPlayer &&
              (m.quality == MoveQuality.mistake || m.quality == MoveQuality.blunder) &&
              m.bestSan != null)
            DojoDrill(game: g, move: m),
    ]..shuffle(Random());
    if (!mounted) return;
    setState(() {
      _drills = drills;
      _index = 0;
    });
    _setup();
  }

  DojoDrill? get _drill => (_drills == null || _drills!.isEmpty) ? null : _drills![_index % _drills!.length];

  cg.GameData _data(String fen, {required bool interactive, String? lastUci}) {
    final pos = DojoChess.position(fen);
    return cg.GameData(
      fen: fen,
      playerSide: interactive ? (pos.turn == dc.Side.white ? cg.PlayerSide.white : cg.PlayerSide.black) : cg.PlayerSide.none,
      sideToMove: pos.turn,
      validMoves: dc.makeLegalMoves(pos),
      kingSquareInCheck: pos.isCheck ? pos.board.kingOf(pos.turn) : null,
      lastMove: lastUci == null ? null : dc.Move.parse(lastUci),
    );
  }

  void _setup() {
    final drill = _drill;
    if (drill == null) return;
    final data = _data(drill.move.fenBefore, interactive: true);
    if (_board == null) {
      _board = cg.ChessboardController(game: data);
    } else {
      _board!.updatePosition(data, animate: false, resetPremove: true);
    }
    setState(() {
      _feedback = null;
      _solved = false;
      _revealed = false;
    });
  }

  void _onMove(dc.Move move, {bool? viaDragAndDrop}) {
    final drill = _drill!;
    final fen = drill.move.fenBefore;
    final best = DojoChess.play(fen, drill.move.bestSan!);
    final played = DojoChess.sanOf(fen, move.uci) ?? move.uci;
    if (best != null && best.uci == move.uci) {
      _board!.updatePosition(_data(best.fen, interactive: false, lastUci: move.uci));
      setState(() {
        _solved = true;
        _feedback = 'Correct! ${drill.move.bestSan} is what Stockfish wanted. Line: ${drill.move.bestLine ?? drill.move.bestSan}';
      });
    } else {
      _board!.updatePosition(_data(fen, interactive: true), animate: false, resetPremove: true);
      setState(() => _feedback = played == drill.move.san
          ? 'That\'s the move you played in the game (${drill.move.quality.label.toLowerCase()}). Look for something better.'
          : '$played isn\'t it. Try again.');
    }
  }

  void _next() {
    setState(() => _index++);
    _setup();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final drills = _drills;
    if (drills == null) return const Center(child: CircularProgressIndicator());
    final drill = _drill;
    if (drill == null || _board == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Mistakes and blunders from your analysed games show up here as puzzles. Play and analyse a few games first.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final white = drill.move.fenBefore.split(' ')[1] == 'w';
    return LayoutBuilder(
      builder: (context, c) {
        final size = min(c.maxWidth - 24, c.maxHeight - 190).clamp(200.0, 560.0);
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text(
              'Puzzle ${_index % drills.length + 1} of ${drills.length} · ${white ? 'White' : 'Black'} to move',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              'From your game vs ${drill.game.opponent.label} '
              '(${MaterialLocalizations.of(context).formatShortDate(drill.game.started)}). '
              'You played ${drill.move.moveLabel}, a ${drill.move.quality.label.toLowerCase()}. Find a better move.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Center(
              child: cg.Chessboard(
                key: const ValueKey('dojo-drill-board'),
                size: size,
                controller: _board!,
                orientation: white ? dc.Side.white : dc.Side.black,
                onMove: _solved ? null : _onMove,
                settings: boardPreferencesOf(context).interactiveSettings.copyWith(enablePremoves: false),
              ),
            ),
            const SizedBox(height: 8),
            if (_feedback != null)
              Text(
                _feedback!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _solved ? const Color(0xFF2E9E5B) : theme.colorScheme.error,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (!_solved)
                  TextButton(
                    onPressed: () => setState(() {
                      _revealed = true;
                      _feedback = 'Stockfish: ${drill.move.bestLine ?? drill.move.bestSan}';
                    }),
                    child: const Text('Reveal'),
                  ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _next,
                  icon: const Icon(Icons.skip_next),
                  label: Text(_solved || _revealed ? 'Next puzzle' : 'Skip'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
