import 'dart:io';

import 'package:chessground/chessground.dart' as cg;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maia_chess/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dojo_support.dart';

/// Layout checks for the Dojo screens on a Pixel 8a (412×915 dp) and a desktop
/// window. With CHESSTER_SCREENSHOTS=1 and --update-goldens, PNGs are written
/// to docs/screenshots/dojo/ for review.
final _shots = Platform.environment['CHESSTER_SCREENSHOTS'] == '1';

DojoGame sampleGame() {
  final game = DojoGame.create(
    opponent: const DojoOpponent(kind: DojoOpponentKind.stockfish, elo: 1500),
    playerIsWhite: true,
  );
  var id = 0;
  final evals = [30, 35, 30, 40, 35, 45, 50, -120];
  for (final (i, uci) in ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'c6d4', 'f3e5', 'd8g5'].indexed) {
    final node = game.addMove(id, uci, byPlayer: i.isEven);
    final white = evals[i];
    final whiteToMove = node.turn.name == 'white';
    node.analysis = EngineAnalysis(fen: node.fen, lines: [
      EngineLine(pv: const [], cp: whiteToMove ? white : -white, depth: 18),
    ]);
    if (i.isEven) {
      node.verdict = i == 6
          ? const MoveVerdict(
              quality: MoveQuality.mistake,
              playedUci: 'f3e5',
              playedSan: 'Nxe5',
              bestUci: 'f3d4',
              bestSan: 'Nxd4',
              scoreBefore: 50,
              scoreAfter: -120,
            )
          : MoveVerdict(
              quality: MoveQuality.best,
              playedUci: uci,
              playedSan: node.san!,
              bestUci: uci,
              bestSan: node.san,
              scoreBefore: 30,
              scoreAfter: 30,
            );
    }
    id = node.id;
  }
  game.root.analysis = EngineAnalysis(fen: dojoStartFen, lines: const [EngineLine(pv: [], cp: 25)]);
  // An explored side line: 3. Bb5.
  final nc6 = game.lineThrough(0)[4];
  final bb5 = game.addMove(nc6.id, 'f1b5', byPlayer: true);
  bb5.analysis = EngineAnalysis(fen: bb5.fen, lines: const [EngineLine(pv: [], cp: -35)]);
  game.select(id);
  game.coach.entries.addAll([
    DojoChatEntry(role: 'user', text: 'Why was Nxe5 bad?'),
    DojoChatEntry(
      role: 'assistant',
      text: '**Nxe5 walks into a double attack.** After 4...Qg5 Black hits both your knight on e5 and the pawn on g2.\n\n'
          '- Best was **4. Nxd4**, removing the annoying knight first.\n'
          '- Now try **5. Nxf7** — Stockfish says it keeps you close to equal.',
      toolNotes: const ['Stockfish: analysing the position', 'Stockfish: checking Nxe5'],
    ),
  ]);
  return game;
}

PostGameReport sampleReport(DojoGame game) {
  final line = game.finalLine;
  final whiteEvals = [25, 30, 35, 30, 40, 35, 45, 50, -120, -110, -140, -300, -280, -650, -700];
  final moves = <PostGameMove>[];
  for (var i = 1; i < line.length; i++) {
    final byPlayer = line[i - 1].turn == game.playerSide;
    final before = whiteEvals[i - 1];
    final after = whiteEvals[i];
    final mover = byPlayer ? 1 : -1;
    final q = MoveVerdict.classify(before * mover, after * mover, best: false);
    moves.add(PostGameMove(
      ply: i,
      san: line[i].san!,
      uci: line[i].uci!,
      byPlayer: byPlayer,
      fenBefore: line[i - 1].fen,
      whiteEvalBefore: before,
      whiteEvalAfter: after,
      quality: q,
      accuracy: moveAccuracy(winPercent(before * mover), winPercent(after * mover)),
      centipawnLoss: (before * mover - after * mover).clamp(0, 1000),
      bestSan: q.isError ? 'Nxd4' : null,
      bestLine: q.isError ? '4. Nxd4 exd4 5. O-O' : null,
    ));
  }
  return PostGameReport(moves: moves, analyzedAt: DateTime(2026, 11, 14), movetimeMs: 800);
}

Widget app(Widget home, {Size? size}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF5B6C3B), fontFamily: 'Roboto'),
  home: home,
);

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final widget = element.widget as Image;
      await precacheImage(widget.image, element);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> shot(WidgetTester tester, String name) async {
  if (!_shots) return;
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../../docs/screenshots/dojo/$name.png'));
}

void setSize(WidgetTester tester, Size logical, double dpr) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUpAll(() async {
    if (_shots) await loadDojoTestFonts();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('dojo_test');
    DojoStore.overrideRoot = temp;
    Directory('${temp.path}/games').createSync();
    DojoEngine.instance = DojoEngine(factory: () async => FakeUciHandle());
    final s = DojoSettings.instance;
    s.guidance = true;
    s.loaded = true;
  });

  tearDown(() {
    DojoStore.overrideRoot = null;
  });

  const pixel = Size(412, 915);
  const pixelDpr = 2.625;

  testWidgets('home fits a Pixel 8a', (tester) async {
    setSize(tester, pixel, pixelDpr);
    await tester.pumpWidget(app(const DojoHome()));
    await settle(tester);
    expect(find.byKey(const ValueKey('dojo-start')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'pixel8a_home');
  });

  testWidgets('game screen: guidance, momentum bar, move check', (tester) async {
    setSize(tester, pixel, pixelDpr);
    final game = sampleGame();
    await tester.pumpWidget(app(DojoGamePage(game: game)));
    await settle(tester);
    expect(tester.takeException(), isNull);
    // Board + controls are all on screen.
    for (final key in ['dojo-board', 'dojo-back', 'dojo-hint', 'dojo-move-check', 'dojo-explain', 'dojo-eval-toggle']) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      expect(rect.bottom, lessThanOrEqualTo(pixel.height), reason: key);
      expect(rect.right, lessThanOrEqualTo(pixel.width), reason: key);
    }
    await shot(tester, 'pixel8a_game_hidden');
    await tester.tap(find.byKey(const ValueKey('dojo-eval-toggle')));
    await tester.tap(find.byKey(const ValueKey('dojo-move-check')));
    await settle(tester);
    expect(find.textContaining('Mistake — best was Nxd4'), findsOneWidget);
    await shot(tester, 'pixel8a_game_guidance');

    // Back steps through the line without deleting anything.
    final nodesBefore = game.nodes.length;
    await tester.tap(find.byKey(const ValueKey('dojo-back')));
    await settle(tester);
    expect(game.current.san, 'Nxe5');
    expect(game.nodes.length, nodesBefore);
  });

  testWidgets('guidance off hides help', (tester) async {
    setSize(tester, pixel, pixelDpr);
    DojoSettings.instance.guidance = false;
    await tester.pumpWidget(app(DojoGamePage(game: sampleGame())));
    await settle(tester);
    expect(find.byKey(const ValueKey('dojo-move-check')), findsNothing);
    expect(find.byKey(const ValueKey('dojo-coach')), findsNothing);
    expect(find.byKey(const ValueKey('dojo-eval-toggle')), findsNothing);
  });

  testWidgets('coach chat sheet', (tester) async {
    setSize(tester, pixel, pixelDpr);
    await tester.pumpWidget(app(DojoGamePage(game: sampleGame())));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('dojo-coach')));
    await settle(tester);
    expect(find.textContaining('double attack'), findsOneWidget);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'pixel8a_coach_chat');
  });

  testWidgets('post-game report', (tester) async {
    setSize(tester, pixel, pixelDpr);
    final game = sampleGame();
    final last = game.lineThrough(game.currentId).last;
    var id = last.id;
    for (final uci in ['e5f7', 'g5g2', 'h1f1', 'g2e4', 'c4e2', 'd4f3']) {
      id = game.addMove(id, uci, byPlayer: game.nodes[id]!.turn == game.playerSide).id;
    }
    game.select(id);
    game.finish('0-1', 'resignation', id);
    game.postGame = sampleReport(game);
    await tester.pumpWidget(app(DojoPostGamePage(game: game, autoStart: false)));
    await settle(tester);
    // Moves tab: board, caption, graph and a scrollable move list all fit.
    expect(find.byType(cg.StaticChessboard), findsOneWidget);
    expect(find.byKey(const ValueKey('dojo-report-moves')), findsOneWidget);
    expect(find.byKey(const ValueKey('dojo-report-caption')), findsOneWidget);
    final list = tester.getRect(find.byKey(const ValueKey('dojo-report-moves')));
    expect(list.height, greaterThan(120));
    expect(list.bottom, lessThanOrEqualTo(pixel.height));
    await tester.tap(find.byKey(const ValueKey('dojo-show-best')));
    await settle(tester);
    expect(find.textContaining('Best: '), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'pixel8a_postgame');

    await tester.tap(find.byKey(const ValueKey('dojo-tab-summary')));
    await settle(tester);
    expect(find.byKey(const ValueKey('dojo-perf-elo')), findsOneWidget);
    await shot(tester, 'pixel8a_postgame_summary');

    // AI coach tab: nothing is sent automatically; one quick-review button.
    game.review.entries.addAll([
      DojoChatEntry(role: 'user', text: 'Please give me a quick review of this game.'),
      DojoChatEntry(
        role: 'assistant',
        text: '**Turning point: 4. Nxe5?** The knight grab walks into ...Qg5, hitting e5 and g2.',
        scenes: [
          DojoBoardScene(
            title: 'Better: 4. Nxd4',
            fen: game.finalLine[6].fen,
            moves: const ['Nxd4', 'exd4', 'O-O'],
            actual: CoachTools.actualMovesFrom(game, game.finalLine[6].fen, 4),
          ),
        ],
      ),
    ]);
    await tester.tap(find.byKey(const ValueKey('dojo-ai-review')));
    await settle(tester);
    expect(find.byKey(const ValueKey('dojo-quick-review')), findsOneWidget);
    expect(find.text('Better: 4. Nxd4'), findsOneWidget);
    await tester.ensureVisible(find.text('Better: 4. Nxd4'));
    await settle(tester);
    await tester.tap(find.text('Better: 4. Nxd4'));
    await settle(tester);
    expect(find.textContaining('Better: 4. Nxd4 · Nxd4'), findsOneWidget);
    await tester.tap(find.text('Game'));
    await settle(tester);
    expect(find.textContaining('Better: 4. Nxd4 · Nxe5'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'pixel8a_ai_coach_tab');
  });

  testWidgets('opening training: the book plays and explains', (tester) async {
    setSize(tester, pixel, pixelDpr);
    final lesson = DojoTrainingCatalog.opening('two-knights')!;
    final game = DojoGame.create(
      opponent: const DojoOpponent(kind: DojoOpponentKind.stockfish, elo: 1500),
      playerIsWhite: false,
      training: DojoTraining(kind: 'opening', lessonId: lesson.id),
    );
    await tester.pumpWidget(app(DojoGamePage(game: game)));
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(game.current.san, 'e4');
    expect(find.byKey(const ValueKey('dojo-training-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('dojo-book-note')), findsOneWidget);
    expect(find.textContaining('Your move:'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dojo-show-me')));
    await settle(tester);
    expect(tester.takeException(), isNull);
    await shot(tester, 'pixel8a_opening_training');
  });

  testWidgets('training hub lists openings and endgames', (tester) async {
    setSize(tester, pixel, pixelDpr);
    await tester.pumpWidget(app(const DojoTrainingPage()));
    await settle(tester);
    expect(find.byKey(const ValueKey('dojo-opening-italian')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'pixel8a_training');
  });

  testWidgets('progress page', (tester) async {
    setSize(tester, pixel, pixelDpr);
    final base = sampleGame();
    await tester.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        final g = DojoGame.fromJson(base.toJson());
        final copy = DojoGame(
          id: 'g$i',
          opponent: DojoOpponent(kind: i.isEven ? DojoOpponentKind.maia : DojoOpponentKind.stockfish, elo: 1300 + i * 50),
          playerIsWhite: i.isEven,
          started: DateTime(2026, 11, 1 + i),
          nodes: g.nodes,
          currentId: g.currentId,
        );
        copy.finish(i % 3 == 0 ? '0-1' : '1-0', 'checkmate', copy.currentId);
        final report = sampleReport(copy);
        copy.postGame = PostGameReport(
          moves: [
            for (final m in report.moves)
              PostGameMove(
                ply: m.ply,
                san: m.san,
                uci: m.uci,
                byPlayer: m.byPlayer,
                fenBefore: m.fenBefore,
                whiteEvalBefore: m.whiteEvalBefore,
                whiteEvalAfter: m.whiteEvalAfter,
                quality: m.quality,
                accuracy: (m.accuracy + i * 4).clamp(0, 100),
                centipawnLoss: (m.centipawnLoss - i * 8).clamp(0, 1000),
              ),
          ],
          analyzedAt: DateTime(2026, 11, 1 + i),
          movetimeMs: 800,
        );
        await DojoStore.instance.save(copy);
      }
    });
    await tester.pumpWidget(app(const DojoProgressPage()));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await settle(tester);
    expect(find.text('Performance rating over time'), findsOneWidget);
    expect(find.byKey(const ValueKey('dojo-progress-coach')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'pixel8a_progress');
  });

  testWidgets('desktop game layout', (tester) async {
    setSize(tester, const Size(1400, 860), 1);
    await tester.pumpWidget(app(DojoGamePage(game: sampleGame())));
    await settle(tester);
    expect(find.byType(CoachChatView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'desktop_game');
  });
}
