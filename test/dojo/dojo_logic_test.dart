import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maia_chess/main.dart';

import 'dojo_support.dart';

DojoGame _game({bool white = true}) => DojoGame.create(
  opponent: const DojoOpponent(kind: DojoOpponentKind.stockfish, elo: 1500),
  playerIsWhite: white,
);

void main() {
  group('move tree', () {
    test('adds moves, reuses identical children and branches', () {
      final game = _game();
      final e4 = game.addMove(0, 'e2e4', byPlayer: true);
      final e5 = game.addMove(e4.id, 'e7e5', byPlayer: false);
      expect(e4.san, 'e4');
      expect(e5.san, 'e5');
      expect(game.addMove(0, 'e2e4', byPlayer: true).id, e4.id);
      final d4 = game.addMove(0, 'd2d4', byPlayer: true);
      expect(game.root.children, [e4.id, d4.id]);
      expect(game.root.preferredChild, d4.id);
      game.select(e5.id);
      expect(game.lineThrough(0).map((n) => n.san).skip(1), ['e4', 'e5']);
    });

    test('PGN keeps explored variations', () {
      final game = _game();
      final e4 = game.addMove(0, 'e2e4', byPlayer: true);
      final e5 = game.addMove(e4.id, 'e7e5', byPlayer: false);
      game.addMove(e5.id, 'g1f3', byPlayer: true);
      game.addMove(e5.id, 'f1c4', byPlayer: true);
      game.select(game.nodes.values.last.id);
      final pgn = game.toPgn();
      expect(pgn, contains('1. e4 e5 2. Bc4 (2. Nf3)'));
      final restored = DojoGame.fromJson(jsonDecode(jsonEncode(game.toJson())) as Map<String, Object?>);
      expect(restored.toPgn(), pgn);
      expect(restored.nodes.length, game.nodes.length);
    });

    test('detects checkmate and repetition', () {
      final game = _game();
      var id = 0;
      for (final uci in ['f2f3', 'e7e5', 'g2g4', 'd8h4']) {
        id = game.addMove(id, uci, byPlayer: game.nodes[id]!.turn == game.playerSide).id;
      }
      expect(game.naturalOutcome(id), (result: '0-1', reason: 'checkmate'));

      final rep = _game();
      var r = 0;
      for (var i = 0; i < 2; i++) {
        for (final uci in ['g1f3', 'g8f6', 'f3g1', 'f6g8']) {
          r = rep.addMove(r, uci, byPlayer: true).id;
        }
      }
      expect(rep.naturalOutcome(r)?.reason, 'threefold repetition');
    });
  });

  group('training catalogue', () {
    test('every opening line is legal and alternates sides correctly', () {
      for (final lesson in DojoTrainingCatalog.openings) {
        var fen = dojoStartFen;
        for (final (i, move) in lesson.moves.indexed) {
          final step = DojoChess.play(fen, move.san);
          expect(step, isNotNull, reason: '${lesson.id} move ${i + 1} ${move.san}');
          expect(step!.san, move.san, reason: '${lesson.id}: SAN must be canonical');
          fen = step.fen;
        }
      }
      expect(DojoTrainingCatalog.forColour(true).map((o) => o.level), [1, 2, 3, 4, 5]);
      expect(DojoTrainingCatalog.forColour(false).first.id, 'two-knights');
    });

    test('endgame positions are valid', () {
      for (final lesson in DojoTrainingCatalog.endgames) {
        expect(() => DojoChess.position(lesson.fen), returnsNormally, reason: lesson.id);
        expect(DojoChess.position(lesson.fen).isGameOver, isFalse, reason: lesson.id);
      }
    });

    test('real Stockfish agrees with each endgame goal', () async {
      final path = localStockfish();
      if (path == null) {
        markTestSkipped('no local stockfish.exe');
        return;
      }
      final engine = DojoEngine(factory: () => ProcessUciHandle.start(path));
      for (final lesson in DojoTrainingCatalog.endgames) {
        final analysis = await engine.analyze(lesson.fen, multiPv: 1, movetimeMs: 1500);
        final forPlayer = analysis.score; // side to move = the student
        if (lesson.goal == 'Draw') {
          expect(forPlayer.abs(), lessThan(150), reason: lesson.id);
        } else {
          expect(forPlayer, greaterThan(300), reason: lesson.id);
        }
      }
      await engine.close();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('takebacks on a line are described for the coach', () {
      final game = _game();
      final e4 = game.addMove(0, 'e2e4', byPlayer: true);
      game.addMove(0, 'd2d4', byPlayer: true);
      game.undoCount = 1;
      final e5 = game.addMove(e4.id, 'e7e5', byPlayer: false);
      game.select(e5.id);
      final notes = game.takebacksOnLine(e5.id);
      expect(notes.single, contains('first tried d4'));
      expect(notes.single, contains('chose e4'));
      expect(dojoGameStateBlock(game, game.current), contains('Takebacks on this line'));
    });

    test('engine runs foreground work before queued background analysis', () async {
      final fake = FakeUciHandle();
      final engine = DojoEngine(factory: () async => fake);
      final order = <String>[];
      final futures = [
        engine.analyze(dojoStartFen, movetimeMs: 10, background: true).then((_) => order.add('bg1')),
        engine.analyze(dojoStartFen, movetimeMs: 10, background: true).then((_) => order.add('bg2')),
        engine.chooseMove(dojoStartFen, movetimeMs: 10).then((_) => order.add('fg')),
      ];
      await Future.wait(futures);
      expect(order.indexOf('fg'), lessThan(order.indexOf('bg2')));
      await engine.close();
    });
  });

  group('verdicts', () {
    test('classification thresholds follow win-percent loss', () {
      expect(MoveVerdict.classify(50, 50, best: true), MoveQuality.best);
      expect(MoveVerdict.classify(50, 35, best: false), MoveQuality.excellent);
      expect(MoveVerdict.classify(50, 10, best: false), MoveQuality.good);
      expect(MoveVerdict.classify(50, -20, best: false), MoveQuality.inaccuracy);
      expect(MoveVerdict.classify(50, -100, best: false), MoveQuality.mistake);
      expect(MoveVerdict.classify(50, -250, best: false), MoveQuality.blunder);
    });

    test('headlines read like a coach', () {
      MoveVerdict v(MoveQuality q, {String? best = 'Nxc6', String played = 'b1c3', String? alt}) => MoveVerdict(
        quality: q,
        playedUci: played,
        playedSan: 'Nc3',
        bestUci: best == null ? null : 'd4c6',
        bestSan: best,
        scoreBefore: 100,
        scoreAfter: 40,
        alternativeSan: alt,
      );
      expect(v(MoveQuality.good).headline, 'Good move, but Nxc6 is better');
      expect(v(MoveQuality.blunder).headline, 'Blunder — best was Nxc6');
      expect(v(MoveQuality.good, played: 'd4c6', alt: 'Nxc6').headline, 'Good move — another option was Nxc6');
      expect(v(MoveQuality.good).scoreLine, contains('+1.0 → +0.4 (−0.6)'));
    });

    test('Elo estimate falls with centipawn loss', () {
      expect(estimateEloFromAcpl(10), greaterThan(estimateEloFromAcpl(50)));
      expect(estimateEloFromAcpl(50), inInclusiveRange(1600, 2100));
    });
  });

  group('engine wrapper', () {
    test('parses multi-PV output from a UCI engine', () async {
      final fake = FakeUciHandle();
      final engine = DojoEngine(factory: () async => fake);
      final analysis = await engine.analyze(dojoStartFen, multiPv: 3, movetimeMs: 50);
      expect(analysis.lines, hasLength(3));
      expect(analysis.lines.first.cp, 30);
      expect(analysis.whiteScore, 30);
      expect(await engine.chooseMove(dojoStartFen, elo: 1500), analysis.bestMove);
      expect(fake.commands, contains('setoption name UCI_Elo value 1500'));
      await engine.close();
    });

    test('real Stockfish: analysis and strength-limited play', () async {
      final path = localStockfish();
      if (path == null) {
        markTestSkipped('no local stockfish.exe');
        return;
      }
      final engine = DojoEngine(factory: () => ProcessUciHandle.start(path));
      DojoEngine.instance = engine;
      final analysis = await engine.analyze(dojoStartFen, multiPv: 3, movetimeMs: 300);
      expect(analysis.lines.length, 3);
      expect(analysis.whiteScore.abs(), lessThan(100));
      final move = await engine.chooseMove(dojoStartFen, elo: 1400, movetimeMs: 200);
      expect(DojoChess.play(dojoStartFen, move!), isNotNull);
      // 1.e4 e5 2.Nf3 Qh4?? — the queen hangs to Nxh4; ignoring it is a blunder.
      const fen = 'rnb1kbnr/pppp1ppp/8/4p3/4P2q/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';
      final verdict = await DojoGuidance.judge(fen, 'a2a3');
      expect(verdict.quality, MoveQuality.blunder);
      expect(verdict.bestSan, isNotNull);
      final good = await DojoGuidance.judge(fen, DojoChess.play(fen, verdict.bestSan!)!.uci);
      expect(good.quality, MoveQuality.best);
      await engine.close();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('Claude client', () {
    String sse(List<Map<String, Object?>> events) =>
        events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

    test('streams text, runs Stockfish tools and echoes thinking blocks', () async {
      DojoEngine.instance = DojoEngine(factory: () async => FakeUciHandle());
      final requests = <Map<String, Object?>>[];
      final client = MockClient.streaming((request, body) async {
        final json = jsonDecode(await body.bytesToString()) as Map<String, Object?>;
        requests.add(json);
        expect(request.headers['x-api-key'], 'test-key');
        expect(request.headers['anthropic-version'], '2026-10-21');
        final first = requests.length == 1;
        final events = first
            ? [
                {'type': 'message_start', 'message': {'id': 'm1'}},
                {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'thinking', 'thinking': ''}},
                {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'thinking_delta', 'thinking': 'Let me check.'}},
                {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta', 'signature': 'sig123'}},
                {'type': 'content_block_stop', 'index': 0},
                {'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'text', 'text': ''}},
                {'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'text_delta', 'text': 'Checking.'}},
                {'type': 'content_block_stop', 'index': 1},
                {'type': 'content_block_start', 'index': 2, 'content_block': {'type': 'tool_use', 'id': 'tu1', 'name': 'analyze_position', 'input': {}}},
                {'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': '{"fen": "$dojoStartFen",'}},
                {'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': ' "lines": 2}'}},
                {'type': 'content_block_stop', 'index': 2},
                {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use'}},
                {'type': 'message_stop'},
              ]
            : [
                {'type': 'message_start', 'message': {'id': 'm2'}},
                {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}},
                {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'Play e4.'}},
                {'type': 'content_block_stop', 'index': 0},
                {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}},
                {'type': 'message_stop'},
              ];
        return http.StreamedResponse(Stream.value(utf8.encode(sse(events))), 200);
      });
      final claude = ClaudeClient(apiKey: 'test-key', model: 'claude-haiku-5-5', effort: 'medium', httpClient: client);
      final messages = <Map<String, Object?>>[
        {'role': 'user', 'content': 'What now?'},
      ];
      final events = await claude.converse(system: 'coach', messages: messages, tools: CoachTools.chess).toList();
      expect(events.whereType<CoachToolNote>().single.note, contains('Stockfish'));
      final done = events.whereType<CoachDone>().single;
      expect(done.text, 'Checking.\n\nPlay e4.');
      expect(requests.first['model'], 'claude-haiku-5-5');
      expect(requests.first['thinking'], {'type': 'adaptive'});
      expect(requests.first['output_config'], {'effort': 'medium'});
      expect(requests.first.containsKey('fallbacks'), isFalse);
      // Second request carries the thinking block unchanged plus the tool result.
      final second = requests[1]['messages'] as List;
      final assistant = second[1] as Map;
      expect((assistant['content'] as List).first, {'type': 'thinking', 'thinking': 'Let me check.', 'signature': 'sig123'});
      final toolResult = ((second[2] as Map)['content'] as List).single as Map;
      expect(toolResult['tool_use_id'], 'tu1');
      expect(toolResult['content'], contains('Depth 12'));
      expect(messages, hasLength(4));
    });

    test('API errors roll the thread back and explain the problem', () async {
      final client = MockClient((request) async => http.Response(
        jsonEncode({'type': 'error', 'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}}),
        401,
      ));
      final claude = ClaudeClient(apiKey: 'bad', model: 'claude-opus-5-5', effort: 'high', httpClient: client);
      final messages = <Map<String, Object?>>[
        {'role': 'user', 'content': 'hi'},
      ];
      final events = await claude.converse(system: 's', messages: messages).toList();
      expect((events.single as CoachError).message, contains('API key'));
      expect(messages, hasLength(1));
    });
  });
}
