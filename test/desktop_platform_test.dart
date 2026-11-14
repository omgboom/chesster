import 'dart:io';
import 'dart:typed_data';

import 'package:chess/chess.dart' as chess;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maia_chess/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Desktop code paths. flutter_tester runs on the host OS, so on Windows and
/// Linux these exercise the real desktop branches.
///
/// Optional real-binary tests (skipped unless the variables are set):
///   CHESSTER_STOCKFISH=C:\path\to\stockfish.exe
///   CHESSTER_ORT_DLL=C:\path\to\onnxruntime.dll   (uses assets/models/...)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDesktopFallbacksOverride = null);

  test('desktop fallbacks stay off under flutter test by default', () {
    expect(Platform.environment['FLUTTER_TEST'], isNotNull);
    expect(desktopFallbacksEnabled, isFalse);
    debugDesktopFallbacksOverride = true;
    expect(desktopFallbacksEnabled, isTrue);
  });

  group('locateStockfishExecutable', () {
    late Directory root;
    final name = Platform.isWindows ? 'stockfish.exe' : 'stockfish';

    setUp(() async {
      root = await Directory.systemTemp.createTemp('chesster-sf-');
    });
    tearDown(() => root.delete(recursive: true));

    Future<String> touch(String relative) async {
      final file = File('${root.path}${Platform.pathSeparator}$relative');
      await file.parent.create(recursive: true);
      await file.writeAsString('');
      return file.absolute.path;
    }

    String dir(String relative) =>
        '${root.path}${Platform.pathSeparator}$relative';

    test(
      'prefers the app folder, then stockfish/, then preference, then PATH',
      () async {
        await Directory(dir('app')).create();
        final onPath = await touch('bin$sep$name');
        final preferred = await touch('chosen$sep$name');
        Future<String?> locate() => locateStockfishExecutable(
          executableDirectory: dir('app'),
          preferencePath: preferred,
          environment: {'PATH': dir('bin')},
        );

        expect(await locate(), preferred);
        final nested = await touch('app${sep}stockfish$sep$name');
        expect(await locate(), nested);
        // Off Windows the executable is also named "stockfish", the same as
        // the subfolder, so only Windows can have both side by side.
        if (Platform.isWindows) {
          final beside = await touch('app$sep$name');
          expect(await locate(), beside);
        }

        expect(
          await locateStockfishExecutable(
            executableDirectory: dir('empty'),
            preferencePath: '',
            environment: {'PATH': dir('bin')},
          ),
          onPath,
        );
      },
    );

    test(
      'reads the stored preference and returns null when nothing exists',
      () async {
        final stored = await touch('stored$sep$name');
        SharedPreferences.setMockInitialValues({
          dojoStockfishPathPreferenceKey: stored,
        });
        expect(
          await locateStockfishExecutable(
            executableDirectory: dir('none'),
            environment: const {},
          ),
          stored,
        );
        SharedPreferences.setMockInitialValues({});
        expect(
          await locateStockfishExecutable(
            executableDirectory: dir('none'),
            environment: const {},
          ),
          isNull,
        );
      },
    );
  });

  group('desktop channel fallbacks', () {
    test('Android-only channels report unsupported on desktop', () async {
      debugDesktopFallbacksOverride = true;
      const channel = AndroidOnlyMethodChannel('test/android-only', 'nope');
      await expectLater(
        channel.invokeMethod<void>('discover'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
      const events = AndroidOnlyEventChannel('test/android-only/events');
      final subscription = events.receiveBroadcastStream().listen((_) {});
      await subscription.cancel();
    });

    test(
      'engine channel still uses platform mocks when fallbacks are off',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          maiaEngineChannel,
          (call) async => 'mocked-${call.method}',
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(maiaEngineChannel, null),
        );
        expect(
          await maiaEngineChannel.invokeMethod<String>('dataDirectory'),
          'mocked-dataDirectory',
        );
      },
    );

    test('engine channel is answered in Dart on desktop', () async {
      final documents = await Directory.systemTemp.createTemp('chesster-doc-');
      addTearDown(() => documents.delete(recursive: true));
      final previous = DesktopEngineHost.instance;
      DesktopEngineHost.instance = DesktopEngineHost(
        documentsDirectoryOverride: documents,
      );
      addTearDown(() => DesktopEngineHost.instance = previous);
      debugDesktopFallbacksOverride = true;

      expect(
        await maiaEngineChannel.invokeMethod<bool>('previousProcessFailed'),
        isFalse,
      );
      expect(
        await maiaEngineChannel.invokeMethod<String>('getPendingPgn'),
        isNull,
      );
      expect(
        await maiaEngineChannel.invokeMethod<Object?>('setKeepScreenOn', {
          'enabled': true,
        }),
        isNull,
      );
      final metadata = await maiaEngineChannel.invokeMapMethod<String, Object?>(
        'samplingMetadata',
      );
      expect(metadata!['provider'], 'CPU');

      expect(
        await maiaEngineChannel.invokeMethod<Object>('savePgnFile', {
          'pgn': '1. e4 e5 *',
        }),
        isTrue,
      );
      final saved = documents.listSync().whereType<File>().toList();
      expect(saved, hasLength(1));
      expect(saved.single.path, endsWith('.pgn'));
      expect(saved.single.readAsStringSync(), '1. e4 e5 *');

      await expectLater(
        maiaEngineChannel.invokeMethod<void>('openUrl', {
          'url': 'file:///C:/Windows/System32/calc.exe',
        }),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'bad_arguments',
          ),
        ),
      );
      await expectLater(
        maiaEngineChannel.invokeMethod<Object>('predict', {'tokens': 1}),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'bad_arguments',
          ),
        ),
      );
      await expectLater(
        maiaEngineChannel.invokeMethod<Object>('noSuchMethod'),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });

  final stockfishPath = Platform.environment['CHESSTER_STOCKFISH'];
  group(
    'real Stockfish process',
    () {
      test('process handle speaks UCI and powers StockfishAnalyzer', () async {
        SharedPreferences.setMockInitialValues({
          dojoStockfishPathPreferenceKey: stockfishPath!,
        });
        final handle = await createPlatformStockfishHandle();
        expect(handle, isA<ProcessStockfishHandle>());
        final lines = <String>[];
        final subscription = handle.stdout.listen(lines.add);
        Future<void> waitFor(String prefix) async {
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (!lines.any((line) => line.startsWith(prefix))) {
            if (DateTime.now().isAfter(deadline)) {
              fail('Timed out waiting for "$prefix"; got $lines');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        handle.stdin = 'uci';
        await waitFor('uciok');
        handle.stdin = 'isready';
        await waitFor('readyok');
        handle.stdin = 'position startpos moves e2e4';
        handle.stdin = 'go depth 8';
        await waitFor('bestmove');
        await subscription.cancel();
        await handle.dispose();

        final analyzer = StockfishAnalyzer.withFactory(
          createPlatformStockfishHandle,
        );
        addTearDown(analyzer.close);
        final review = await analyzer.evaluate(
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        );
        expect(
          review.bestMove,
          matches(RegExp(r'^[a-h][1-8][a-h][1-8][qrbn]?$')),
        );
        expect(review.evaluation.abs(), lessThan(150));
      }, timeout: const Timeout(Duration(minutes: 2)));
    },
    skip: stockfishPath == null || !File(stockfishPath).existsSync()
        ? 'Set CHESSTER_STOCKFISH to a stockfish executable'
        : false,
  );

  final ortPath = Platform.environment['CHESSTER_ORT_DLL'];
  final modelPath =
      Platform.environment['CHESSTER_MAIA_MODEL'] ??
      'assets/models/maia3-79m.onnx';
  group(
    'real ONNX Runtime Maia inference',
    () {
      test('predicts finite logits for the starting position', () async {
        final runtime = DesktopMaiaRuntime(
          libraryPath: ortPath,
          modelPath: File(modelPath).absolute.path,
        );
        addTearDown(runtime.release);
        const start =
            'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
        final tokens = MaiaEncoding.historicalTokens([start]);
        final logits = await runtime.predict(
          tokens: tokens,
          selfElo: 1500,
          opponentElo: 1500,
        ) as Float32List;
        expect(logits, hasLength(4352));
        expect(logits.every((value) => value.isFinite), isTrue);

        final probabilities = MaiaEncoding.legalMoveProbabilities(
          chess.Chess.fromFEN(start),
          logits,
        );
        expect(probabilities, hasLength(20));
        // Humans at 1500 open with a central pawn or knight move.
        expect([
          'e2e4',
          'd2d4',
          'c2c4',
          'g1f3',
        ], contains(probabilities.first.uci));

        final analysis = await runtime.predict(
          tokens: tokens,
          selfElo: 1900,
          opponentElo: 1900,
          includeValue: true,
        ) as Map;
        expect(analysis['move_logits'], hasLength(4352));
        expect(analysis['value_logits'], hasLength(3));
        expect(MaiaInferenceResult.decode(analysis)?.outcome, isNotNull);
      }, timeout: const Timeout(Duration(minutes: 3)));
    },
    skip: ortPath == null || !File(ortPath).existsSync()
        ? 'Set CHESSTER_ORT_DLL to an onnxruntime shared library'
        : !File(modelPath).existsSync() ||
              File(modelPath).lengthSync() < 1000000
        ? 'Maia model not materialized (git lfs pull)'
        : false,
  );
}

final sep = Platform.pathSeparator;
