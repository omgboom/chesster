part of '../../main.dart';

/// Stockfish move judgement shared by live guidance, the coach tools and the
/// post-game report.
abstract final class DojoGuidance {
  static int get _movetime => DojoSettings.instance.analysisDepth.movetimeMs;

  /// Judges [uci] played in [fenBefore]. [before] can be a cached analysis.
  static Future<MoveVerdict> judge(
    String fenBefore,
    String uci, {
    EngineAnalysis? before,
    EngineAnalysis? after,
  }) async {
    final engine = DojoEngine.instance;
    final analysisBefore =
        before != null && before.lines.length >= 2
            ? before
            : await engine.analyze(fenBefore, multiPv: 3, movetimeMs: _movetime);
    final played = DojoChess.play(fenBefore, uci)!;
    final bestLine = analysisBefore.lines.firstOrNull;
    final bestScore = bestLine?.score ?? 0;
    // Prefer the score of the played move from the same search if present.
    final sameSearch = analysisBefore.lines.where((l) => l.move == uci).firstOrNull;
    int afterScore;
    EngineAnalysis? analysisAfter = after;
    if (sameSearch != null) {
      afterScore = sameSearch.score;
    } else {
      analysisAfter ??= await engine.analyze(played.fen, multiPv: 1, movetimeMs: _movetime);
      afterScore = -analysisAfter.score;
    }
    final isBest = bestLine?.move == uci;
    final quality = MoveVerdict.classify(bestScore, afterScore, best: isBest);
    String? alternative;
    for (final line in analysisBefore.lines) {
      final move = line.move;
      if (move == null || move == uci || move == bestLine?.move && !isBest) continue;
      if (winPercent(bestScore) - winPercent(line.score) < 5) {
        alternative = DojoChess.sanOf(fenBefore, move);
        break;
      }
    }
    final moverIsWhite = fenBefore.split(' ').elementAtOrNull(1) != 'b';
    return MoveVerdict(
      quality: quality,
      playedUci: uci,
      playedSan: played.san,
      bestUci: bestLine?.move,
      bestSan: bestLine?.move == null ? null : DojoChess.sanOf(fenBefore, bestLine!.move!),
      scoreBefore: bestScore,
      scoreAfter: afterScore,
      alternativeSan: isBest || quality.index <= MoveQuality.good.index ? alternative : null,
      whiteEvalAfter: formatWhiteEval(moverIsWhite ? afterScore : -afterScore),
    );
  }
}

/// Vertical evaluation ("momentum") bar. White's share grows from the bottom
/// when White is at the bottom of the board.
class DojoEvalBar extends StatelessWidget {
  const DojoEvalBar({
    required this.whiteScore,
    required this.whiteMate,
    required this.whiteAtBottom,
    required this.loading,
    super.key,
  });

  final int? whiteScore;
  final int? whiteMate;
  final bool whiteAtBottom;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final score = whiteScore ?? 0;
    final whiteShare = whiteMate != null
        ? (whiteMate! > 0 || (whiteMate == 0 && score > 0) ? 1.0 : 0.0)
        : winPercent(score) / 100;
    final label = whiteScore == null ? '' : formatWhiteEval(score, whiteMate: whiteMate);
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        final whiteHeight = h * whiteShare;
        return ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Stack(
            children: [
              Container(color: const Color(0xFF3A3A3A)),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                left: 0,
                right: 0,
                height: whiteHeight,
                top: whiteAtBottom ? null : 0,
                bottom: whiteAtBottom ? 0 : null,
                child: Container(color: const Color(0xFFF2F2F2)),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: h / 2 - 0.5,
                child: Container(height: 1, color: Colors.redAccent.withValues(alpha: 0.6)),
              ),
              if (label.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  top: (score >= 0) == whiteAtBottom ? null : 2,
                  bottom: (score >= 0) == whiteAtBottom ? 2 : null,
                  child: RotatedBox(
                    quarterTurns: 0,
                    child: Text(
                      label.replaceAll('+', ''),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w700,
                        color: (score >= 0) ? const Color(0xFF333333) : const Color(0xFFEEEEEE),
                      ),
                    ),
                  ),
                ),
              if (loading)
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Collapsed handle shown beside the board when the momentum bar is hidden.
class DojoEvalHandle extends StatelessWidget {
  const DojoEvalHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 4,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 3),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }
}

/// Small coloured badge for a move quality.
class MoveQualityBadge extends StatelessWidget {
  const MoveQualityBadge(this.quality, {this.size = 18, super.key});

  final MoveQuality quality;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = switch (quality) {
      MoveQuality.best => Icons.star_rounded,
      MoveQuality.excellent => Icons.thumb_up_alt_rounded,
      MoveQuality.good => Icons.check_rounded,
      MoveQuality.inaccuracy => Icons.help_outline_rounded,
      MoveQuality.mistake => Icons.error_outline_rounded,
      MoveQuality.blunder => Icons.close_rounded,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: quality.color(Theme.of(context).colorScheme),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: size * 0.72, color: Colors.white),
    );
  }
}
