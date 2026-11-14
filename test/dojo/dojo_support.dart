import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart' as dc;
import 'package:flutter/services.dart';
import 'package:maia_chess/main.dart';

/// Deterministic fake UCI engine: legal moves in a fixed order, descending
/// scores, so tests never need a native Stockfish.
class FakeUciHandle implements StockfishEngineHandle {
  final _out = StreamController<String>.broadcast();
  String _fen = dojoStartFen;
  int _multiPv = 1;
  final List<String> commands = [];

  @override
  Stream<String> get stdout => _out.stream;

  @override
  set stdin(String command) {
    commands.add(command);
    scheduleMicrotask(() => _handle(command));
  }

  void _handle(String command) {
    if (command == 'uci') {
      _out.add('uciok');
    } else if (command == 'isready') {
      _out.add('readyok');
    } else if (command.startsWith('setoption name MultiPV value ')) {
      _multiPv = int.parse(command.split(' ').last);
    } else if (command.startsWith('position fen ')) {
      _fen = command.substring('position fen '.length);
    } else if (command.startsWith('go')) {
      final pos = dc.Chess.fromSetup(dc.Setup.parseFen(_fen));
      final moves = <String>[];
      for (final entry in pos.legalMoves.entries) {
        for (final to in entry.value.squares) {
          moves.add(dc.NormalMove(from: entry.key, to: to).uci);
        }
      }
      moves.sort();
      for (var i = 0; i < _multiPv && i < moves.length; i++) {
        _out.add('info depth 12 multipv ${i + 1} score cp ${30 - i * 40} nodes 1000 pv ${moves[i]}');
      }
      _out.add('bestmove ${moves.isEmpty ? '(none)' : moves.first}');
    }
  }

  @override
  Future<void> dispose() async => _out.close();
}

/// Runs a real Stockfish executable (used when one is available locally).
class ProcessUciHandle implements StockfishEngineHandle {
  ProcessUciHandle._(this._process)
    : _lines = _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();

  static Future<ProcessUciHandle> start(String path) async =>
      ProcessUciHandle._(await Process.start(path, const []));

  final Process _process;
  final Stream<String> _lines;

  @override
  Stream<String> get stdout => _lines;

  @override
  set stdin(String command) => _process.stdin.writeln(command);

  @override
  Future<void> dispose() async {
    _process.stdin.writeln('quit');
    await _process.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      _process.kill();
      return -1;
    });
  }
}

/// Local Stockfish for optional real-engine tests.
String? localStockfish() {
  final candidates = [
    Platform.environment['CHESSTER_STOCKFISH'],
    r'C:\Users\matth\dev\desktop-deps\sf\stockfish.exe',
  ];
  for (final c in candidates) {
    if (c != null && File(c).existsSync()) return c;
  }
  return null;
}

/// Loads Roboto + Material Icons so golden screenshots show real text.
Future<void> loadDojoTestFonts() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\Users\matth\dev\flutter';
  final dir = '$flutterRoot/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String name) async {
    final bytes = await File('$dir/$name').readAsBytes();
    return ByteData.view(bytes.buffer);
  }

  final roboto = FontLoader('Roboto')
    ..addFont(read('roboto-regular.ttf'))
    ..addFont(read('roboto-medium.ttf'))
    ..addFont(read('roboto-bold.ttf'));
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(read('materialicons-regular.otf'));
  await icons.load();
}
