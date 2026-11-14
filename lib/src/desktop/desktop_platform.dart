part of '../../main.dart';

/// Platform seam for desktop support. On Android/iOS the native
/// `multistockfish` engine is used; desktop builds run Stockfish as a process.
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Creates a fresh UCI engine handle for the current platform.
Future<StockfishEngineHandle> createPlatformStockfishHandle() async =>
    _MultistockfishHandle(await Stockfish.create());
