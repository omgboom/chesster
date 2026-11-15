part of '../../main.dart';

/// One book move with a short coaching note.
class BookMove {
  const BookMove(this.san, this.note);
  final String san;
  final String note;
}

/// A guided opening: the computer walks you through [moves], then you play on.
class OpeningLesson {
  const OpeningLesson({
    required this.id,
    required this.name,
    required this.eco,
    required this.playerIsWhite,
    required this.level,
    required this.summary,
    required this.moves,
  });

  final String id;
  final String name;
  final String eco;
  final bool playerIsWhite;

  /// Recommended order within its colour (1 = start here).
  final int level;
  final String summary;
  final List<BookMove> moves;
}

/// A guided endgame: a few pointers, then you figure it out.
class EndgameLesson {
  const EndgameLesson({
    required this.id,
    required this.name,
    required this.fen,
    required this.goal,
    required this.level,
    required this.pointers,
  });

  final String id;
  final String name;
  final String fen;

  /// "Checkmate", "Win", "Draw" …
  final String goal;
  final int level;
  final List<String> pointers;

  bool get playerIsWhite => fen.split(' ').elementAtOrNull(1) != 'b';
}

abstract final class DojoTrainingCatalog {
  static OpeningLesson? opening(String id) => openings.where((o) => o.id == id).firstOrNull;
  static EndgameLesson? endgame(String id) => endgames.where((e) => e.id == id).firstOrNull;

  static List<OpeningLesson> forColour(bool white) =>
      openings.where((o) => o.playerIsWhite == white).toList()..sort((a, b) => a.level.compareTo(b.level));

  static const openings = <OpeningLesson>[
    // ---------------- White ----------------
    OpeningLesson(
      id: 'italian',
      name: 'Italian Game (Giuoco Piano)',
      eco: 'C50',
      playerIsWhite: true,
      level: 1,
      summary: 'The classic first opening: fast development, bishop aimed at f7, castle early, then a slow build-up with c3 and d3/d4.',
      moves: [
        BookMove('e4', 'Grab the centre and open lines for your queen and light-squared bishop.'),
        BookMove('e5', 'Black mirrors you and claims a share of the centre.'),
        BookMove('Nf3', 'Develop with tempo: the knight attacks the e5 pawn.'),
        BookMove('Nc6', 'Black defends e5 while developing.'),
        BookMove('Bc4', 'The Italian bishop: it eyes f7, the weakest square near Black\'s king.'),
        BookMove('Bc5', 'Black copies the idea — the Giuoco Piano ("quiet game").'),
        BookMove('c3', 'Prepares d4 to build a big centre, and gives the bishop a retreat square on c2.'),
        BookMove('Nf6', 'Black counter-attacks e4 and gets ready to castle.'),
        BookMove('d3', 'The modern, solid choice: protect e4 and keep the tension for later.'),
        BookMove('d6', 'Black supports e5 and opens the c8 bishop.'),
        BookMove('O-O', 'King to safety. Plans: Re1, Nbd2-f1-g3, a4 and a later d4.'),
        BookMove('O-O', 'Both sides are developed — now it\'s a real game.'),
      ],
    ),
    OpeningLesson(
      id: 'queens-gambit',
      name: "Queen's Gambit Declined",
      eco: 'D53',
      playerIsWhite: true,
      level: 2,
      summary: 'A 1.d4 classic: offer the c-pawn to pull Black away from the centre, then develop smoothly and pressure d5.',
      moves: [
        BookMove('d4', 'Take the centre with the queen\'s pawn — it is already protected by the queen.'),
        BookMove('d5', 'Black blocks your pawn and stakes a central claim.'),
        BookMove('c4', 'The gambit: you challenge d5 from the side. Taking it gives you the centre.'),
        BookMove('e6', 'Declined: Black keeps d5 solidly protected.'),
        BookMove('Nc3', 'Add pressure on d5 and control e4.'),
        BookMove('Nf6', 'Black defends d5 a second time.'),
        BookMove('Bg5', 'Pin the knight that guards d5 — a typical QGD move.'),
        BookMove('Be7', 'Black unpins and prepares to castle.'),
        BookMove('e3', 'Open the f1 bishop and keep a rock-solid centre.'),
        BookMove('O-O', 'Black castles.'),
        BookMove('Nf3', 'Finish development. Next ideas: Rc1, Bd3 and castling, or cxd5 for a minority attack.'),
      ],
    ),
    OpeningLesson(
      id: 'london',
      name: 'London System',
      eco: 'D02',
      playerIsWhite: true,
      level: 3,
      summary: 'A system you can play against almost anything: d4, Bf4, e3, c3 and a sturdy pyramid of pawns.',
      moves: [
        BookMove('d4', 'Central pawn first.'),
        BookMove('d5', 'Black mirrors.'),
        BookMove('Bf4', 'The London bishop goes out early, before e3 locks it in.'),
        BookMove('Nf6', 'Natural development.'),
        BookMove('e3', 'Now open the other bishop and support d4.'),
        BookMove('c5', 'Black hits your centre — the most testing reply.'),
        BookMove('c3', 'Keep the d4 pawn solid with the c3-d4-e3 triangle.'),
        BookMove('Nc6', 'More pressure on d4.'),
        BookMove('Nd2', 'This knight supports e4 later and doesn\'t block the c-pawn.'),
        BookMove('e6', 'Black solidifies d5.'),
        BookMove('Ngf3', 'Develop and defend d4.'),
        BookMove('Bd6', 'Black challenges your dark-squared bishop.'),
        BookMove('Bg3', 'Keep the bishop; if Black takes, the h-file can open for your rook.'),
        BookMove('O-O', 'Black castles.'),
        BookMove('Bd3', 'Bishop to the attacking diagonal. Next: castle, then Ne5 or e4.'),
      ],
    ),
    OpeningLesson(
      id: 'ruy-lopez',
      name: 'Ruy Lopez (Closed)',
      eco: 'C84',
      playerIsWhite: true,
      level: 4,
      summary: 'The "Spanish torture": pressure the knight that defends e5 and build a long-term initiative.',
      moves: [
        BookMove('e4', 'Centre pawn.'),
        BookMove('e5', 'Symmetrical reply.'),
        BookMove('Nf3', 'Attack e5.'),
        BookMove('Nc6', 'Defend e5.'),
        BookMove('Bb5', 'The Spanish bishop pressures the defender of e5.'),
        BookMove('a6', 'The Morphy Defence: ask the bishop what it wants.'),
        BookMove('Ba4', 'Keep the pin-like pressure; Bxc6 is a different, quieter idea.'),
        BookMove('Nf6', 'Counter-attack e4.'),
        BookMove('O-O', 'Castle — e4 is indirectly defended because Nxe4 runs into Re1.'),
        BookMove('Be7', 'Black prepares to castle (the Closed Ruy Lopez).'),
        BookMove('Re1', 'Now e4 is protected for real.'),
        BookMove('b5', 'Black gains space and chases the bishop.'),
        BookMove('Bb3', 'The bishop settles on the a2-g8 diagonal, still aiming at f7.'),
        BookMove('d6', 'Black supports e5.'),
        BookMove('c3', 'Make room for the bishop on c2 and prepare d4. Then h3 stops ...Bg4.'),
        BookMove('O-O', 'Both castled — a rich middlegame awaits.'),
      ],
    ),
    OpeningLesson(
      id: 'english',
      name: 'English Opening',
      eco: 'A29',
      playerIsWhite: true,
      level: 5,
      summary: 'A flexible flank opening: control d5 from the side and fianchetto your bishop on g2.',
      moves: [
        BookMove('c4', 'Control d5 without committing your centre pawns.'),
        BookMove('e5', 'A reversed Sicilian: Black takes the centre.'),
        BookMove('Nc3', 'More control of d5.'),
        BookMove('Nf6', 'Black develops.'),
        BookMove('g3', 'Prepare the fianchetto — the g2 bishop will rake the long diagonal.'),
        BookMove('d5', 'Black grabs the centre.'),
        BookMove('cxd5', 'Trade a wing pawn for a centre pawn.'),
        BookMove('Nxd5', 'Black recaptures.'),
        BookMove('Bg2', 'The bishop now hits the knight on d5 and the b7 pawn behind it.'),
        BookMove('Nb6', 'Black retreats out of the pressure.'),
        BookMove('Nf3', 'Develop and attack e5.'),
        BookMove('Nc6', 'Defend e5.'),
        BookMove('O-O', 'Castle. Plans: a3, b4 and queenside expansion.'),
      ],
    ),
    // ---------------- Black ----------------
    OpeningLesson(
      id: 'two-knights',
      name: 'Two Knights Defence (vs 1.e4 e5)',
      eco: 'C55',
      playerIsWhite: false,
      level: 1,
      summary: 'Meet the Italian with fast, active development. A natural first defence with 1...e5.',
      moves: [
        BookMove('e4', 'White opens with the king\'s pawn.'),
        BookMove('e5', 'Answer in kind and claim your share of the centre.'),
        BookMove('Nf3', 'White attacks e5.'),
        BookMove('Nc6', 'Defend e5 while developing.'),
        BookMove('Bc4', 'White aims at f7.'),
        BookMove('Nf6', 'The Two Knights: counter-attack e4 instead of copying with ...Bc5.'),
        BookMove('d3', 'White calmly defends e4 (Ng5 is the sharp alternative).'),
        BookMove('Be7', 'A solid square for the bishop; prepares castling.'),
        BookMove('O-O', 'White castles.'),
        BookMove('O-O', 'You castle too.'),
        BookMove('Re1', 'White prepares Nbd2-f1.'),
        BookMove('d6', 'Support e5 and open the c8 bishop. Plans: ...Na5 to trade the Italian bishop, ...c6 and ...d5.'),
      ],
    ),
    OpeningLesson(
      id: 'caro-kann',
      name: 'Caro-Kann Defence',
      eco: 'B18',
      playerIsWhite: false,
      level: 2,
      summary: 'Rock-solid vs 1.e4: prepare ...d5 with ...c6 and develop the light-squared bishop outside the pawn chain.',
      moves: [
        BookMove('e4', 'White opens with the king\'s pawn.'),
        BookMove('c6', 'Prepare ...d5, keeping your c8 bishop free (unlike the French).'),
        BookMove('d4', 'White takes the full centre.'),
        BookMove('d5', 'Challenge e4 right away.'),
        BookMove('Nc3', 'White defends e4.'),
        BookMove('dxe4', 'Release the tension...'),
        BookMove('Nxe4', 'White recaptures.'),
        BookMove('Bf5', '...and develop the bishop with tempo on the knight. This is the Classical Caro-Kann.'),
        BookMove('Ng3', 'White chases the bishop.'),
        BookMove('Bg6', 'Keep the bishop on the good diagonal.'),
        BookMove('h4', 'White threatens h5 to trap or harass the bishop.'),
        BookMove('h6', 'Give the bishop a home on h7.'),
        BookMove('Nf3', 'White develops.'),
        BookMove('Nd7', 'Prepare ...Ngf6 and ...e6; your structure is very sound.'),
      ],
    ),
    OpeningLesson(
      id: 'qgd-black',
      name: "Queen's Gambit Declined (vs 1.d4)",
      eco: 'D53',
      playerIsWhite: false,
      level: 3,
      summary: 'The trusted answer to 1.d4: hold d5 with ...e6, develop, castle, then free your game with ...b6/...Bb7 or ...c5.',
      moves: [
        BookMove('d4', 'White opens with the queen\'s pawn.'),
        BookMove('d5', 'Meet it head-on.'),
        BookMove('c4', 'The Queen\'s Gambit.'),
        BookMove('e6', 'Decline: keep d5 solid.'),
        BookMove('Nc3', 'White adds pressure on d5.'),
        BookMove('Nf6', 'Defend d5 again.'),
        BookMove('Bg5', 'White pins your knight.'),
        BookMove('Be7', 'Break the pin and prepare to castle.'),
        BookMove('e3', 'White opens the f1 bishop.'),
        BookMove('O-O', 'King safety first.'),
        BookMove('Nf3', 'White develops.'),
        BookMove('h6', 'Ask the bishop a question.'),
        BookMove('Bh4', 'White keeps the pin.'),
        BookMove('b6', 'The Tartakower: your c8 bishop will come to b7 and ...c5 frees your position.'),
      ],
    ),
    OpeningLesson(
      id: 'french',
      name: 'French Defence (Steinitz)',
      eco: 'C11',
      playerIsWhite: false,
      level: 4,
      summary: 'Solid and strategic: let White build a big centre with e5, then attack its base with ...c5 and ...f6.',
      moves: [
        BookMove('e4', 'King\'s pawn opening.'),
        BookMove('e6', 'Prepare ...d5 with a sturdy pawn chain.'),
        BookMove('d4', 'White takes the centre.'),
        BookMove('d5', 'Strike at e4.'),
        BookMove('Nc3', 'White defends e4.'),
        BookMove('Nf6', 'Add a second attacker on e4.'),
        BookMove('e5', 'White gains space and kicks your knight.'),
        BookMove('Nfd7', 'Retreat, ready to support ...c5.'),
        BookMove('f4', 'White reinforces e5.'),
        BookMove('c5', 'Attack the base of White\'s chain on d4 — the key French idea.'),
        BookMove('Nf3', 'White defends d4.'),
        BookMove('Nc6', 'More pressure on d4. Plans: ...Qb6, ...cxd4 and later ...f6.'),
        BookMove('Be3', 'White props up d4.'),
      ],
    ),
    OpeningLesson(
      id: 'kings-indian',
      name: "King's Indian Defence",
      eco: 'E92',
      playerIsWhite: false,
      level: 5,
      summary: 'Dynamic vs 1.d4: let White build a big centre, then hit it with ...e5 and attack on the kingside.',
      moves: [
        BookMove('d4', 'Queen\'s pawn.'),
        BookMove('Nf6', 'Flexible: control e4 without committing a pawn.'),
        BookMove('c4', 'White gains space.'),
        BookMove('g6', 'Prepare the fianchetto.'),
        BookMove('Nc3', 'White prepares e4.'),
        BookMove('Bg7', 'Your bishop on the long diagonal is the soul of the King\'s Indian.'),
        BookMove('e4', 'White builds a huge centre.'),
        BookMove('d6', 'Stop e5 and prepare ...e5 yourself.'),
        BookMove('Nf3', 'White develops.'),
        BookMove('O-O', 'Castle before striking.'),
        BookMove('Be2', 'The Classical main line.'),
        BookMove('e5', 'The key break: challenge d4.'),
        BookMove('O-O', 'White castles.'),
        BookMove('Nc6', 'Pressure d4. If d5, play ...Ne7 and ...f5 with a kingside attack.'),
      ],
    ),
    OpeningLesson(
      id: 'sicilian-najdorf',
      name: 'Sicilian Najdorf',
      eco: 'B92',
      playerIsWhite: false,
      level: 6,
      summary: 'The most ambitious reply to 1.e4: unbalance the position and fight for the win.',
      moves: [
        BookMove('e4', 'King\'s pawn.'),
        BookMove('c5', 'The Sicilian: fight for d4 from the side and create an imbalance.'),
        BookMove('Nf3', 'White prepares d4.'),
        BookMove('d6', 'Control e5 and prepare ...Nf6.'),
        BookMove('d4', 'White opens the centre.'),
        BookMove('cxd4', 'Trade a wing pawn for a centre pawn — your long-term trump.'),
        BookMove('Nxd4', 'White recaptures with the knight.'),
        BookMove('Nf6', 'Hit e4 with tempo.'),
        BookMove('Nc3', 'White defends.'),
        BookMove('a6', 'The Najdorf: control b5 and keep options like ...e5 and ...b5.'),
        BookMove('Be2', 'A calm, positional line.'),
        BookMove('e5', 'Kick the knight and grab central space.'),
        BookMove('Nb3', 'White retreats.'),
        BookMove('Be7', 'Develop and castle; your d5 square is the key battleground.'),
      ],
    ),
  ];

  static const endgames = <EndgameLesson>[
    EndgameLesson(
      id: 'two-rooks',
      name: 'Two-rook ladder mate',
      fen: '8/8/8/3k4/8/8/8/R3K2R w - - 0 1',
      goal: 'Checkmate',
      level: 1,
      pointers: [
        'Use the rooks like a ladder: one rook checks along a rank, the other cuts off the next rank.',
        'Push the king step by step to the edge, alternating rooks.',
        'If the king attacks a rook, move it far away along the same rank.',
      ],
    ),
    EndgameLesson(
      id: 'queen-mate',
      name: 'King and queen vs king',
      fen: '8/8/8/4k3/8/8/8/3QK3 w - - 0 1',
      goal: 'Checkmate',
      level: 2,
      pointers: [
        'Use the queen a knight\'s move away from the king to shrink its box — no need to check.',
        'When the king is on the edge, bring your own king closer to help mate.',
        'Watch out for stalemate: always leave the king at least one square until you mate.',
      ],
    ),
    EndgameLesson(
      id: 'rook-mate',
      name: 'King and rook vs king',
      fen: '8/8/8/4k3/8/8/8/R3K3 w - - 0 1',
      goal: 'Checkmate',
      level: 3,
      pointers: [
        'The rook cuts the enemy king off along a rank or file; your king does the pushing.',
        'Use opposition: when the kings face each other, a rook check drives the king back one line.',
        'Use a waiting rook move to hand over the move when needed.',
      ],
    ),
    EndgameLesson(
      id: 'pawn-opposition',
      name: 'King and pawn: opposition',
      fen: '4k3/8/4K3/4P3/8/8/8/8 w - - 0 1',
      goal: 'Promote and win',
      level: 4,
      pointers: [
        'Your king in front of the pawn on the 6th rank wins no matter who moves.',
        'Use the opposition: put your king directly opposite the enemy king with them to move.',
        'Escort the pawn — don\'t rush it ahead of your king.',
      ],
    ),
    EndgameLesson(
      id: 'lucena',
      name: 'Lucena position (build a bridge)',
      fen: '1K1k4/1P6/8/8/8/8/r7/2R5 w - - 0 1',
      goal: 'Promote and win',
      level: 5,
      pointers: [
        'First cut the defending king further away with a rook check on the d-file.',
        'Bring your rook to the 4th rank ("build a bridge") so it can block checks later.',
        'Then walk the king out; when the checks come, interpose the rook.',
      ],
    ),
    EndgameLesson(
      id: 'philidor',
      name: 'Philidor position (defend the draw)',
      fen: '3k4/8/r7/3PK3/8/8/8/4R3 b - - 0 1',
      goal: 'Draw',
      level: 6,
      pointers: [
        'You are Black: keep your rook on the 6th rank so the white king cannot come forward.',
        'Only when the pawn advances to the 6th, drop your rook to the 1st rank and check from behind.',
        'Keep your king on the queening square or right next to it.',
      ],
    ),
  ];
}
