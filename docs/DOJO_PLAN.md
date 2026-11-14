# Chesster — private chess dojo (plan)

Fork of [Dash1971/maia-chess-android](https://github.com/Dash1971/maia-chess-android) (AGPL-3.0),
kept private for personal use. Upstream stays available as the `upstream` git remote.

Target devices: Google Pixel 8a (Android, ~412×915 dp) and a Windows PC.

## What already exists upstream (kept as "Classic Maia")

- Play vs Maia-3 (ONNX, on-device), clocks, premoves, takebacks, electronic boards
- Analysis board, post-game review (Maia + Stockfish via `multistockfish`), PGN import/export

## New: the Dojo (new home screen)

| # | Feature | Where |
|---|---------|-------|
| 1 | Opponent picker: **Maia** (600–2600) or **Stockfish** (UCI_Elo 1320–3190 or full strength) | `lib/src/dojo/dojo_home.dart` |
| 2 | **Free undo / branching**: move tree; undo any time, replay from any earlier position, switch between lines | `dojo_models.dart`, `dojo_game_page.dart` |
| 3 | **One Guidance setting** (on/off). When off, all in-game help is hidden | `dojo_settings.dart` |
| 4a | **Move check** button: Stockfish verdict on your last move ("Good move — Nxc6 was better (−0.6)", "Blunder — best was Bg7") with eval | `dojo_guidance.dart` |
| 4b | **Momentum bar**: hidden handle beside the board, tap to show the eval bar, tap again to hide | `dojo_guidance.dart` |
| 4c | **Explain** button next to the verdict: Claude explains in plain English, using Stockfish as a tool | `dojo_ai.dart`, `dojo_coach_tools.dart` |
| 4d | **Post-game analysis** (Stockfish): accuracy, centipawn loss, blunders/mistakes, eval graph, **estimated performance Elo** vs the engine's Elo; **AI review** button | `dojo_postgame.dart` |
| 4e | **Logs**: every game is a JSON file holding PGN, move tree, move checks, explanations, chat, post-game analysis and AI summary | `dojo_store.dart` |
| 4f | **Progress** section: Elo/accuracy trend over time, record by opponent, AI progress analysis + persistent chat | `dojo_progress.dart` |
| 4g | **Coach chat** during a game (Claude + Stockfish tools) | `dojo_chat.dart` |
| 4h | **Microphone** input for every chat (`speech_to_text`) | `dojo_chat.dart` |
| 4i | Layout fits a Pixel 8a in portrait; side panel layout on wide screens | all pages |
| 5 | **Windows desktop** build (Stockfish as a process, Maia via ONNX Runtime FFI) | `windows/`, `lib/src/desktop/` |

## Claude integration

- Raw HTTPS to `POST /v1/messages` (no official Dart SDK), streaming SSE, `anthropic-version: 2026-10-21`.
- Settings: API key (secure storage), model (default `claude-haiku-5-5`), effort (default `medium`),
  adaptive thinking. Thinking/tool blocks are echoed back unchanged in tool loops.
- Client tools backed by the local Stockfish: `analyze_position`, `evaluate_move`, `play_moves`,
  `legal_moves`. The model never needs to compute lines itself.

## Engine sharing

`multistockfish` allows one native engine per process on Android. The Dojo owns a `DojoEngine`
(UCI wrapper) and the Classic analyzer is closed when the Dojo starts its engine (and vice versa).
On desktop each is a separate `stockfish.exe` process.

## Builds / distribution

- GitHub Actions (private repo): `flutter analyze` + tests, signed release APK (stable keystore in
  repo secrets so updates install over the previous version), Windows zip with `stockfish.exe` and
  `onnxruntime.dll`. Tagged builds publish a GitHub Release.

## Task list

1. Fork → private repo `omgboom/chesster`, upstream remote ✔
2. Plan (this file) ✔
3. DojoEngine (UCI, analysis + strength-limited play), desktop process backend
4. Dojo data model, move tree, JSON store
5. Dojo game screen (board, branching, opponents, guidance UI, momentum bar)
6. Claude client (streaming, tools), Explain, Coach chat, voice input
7. Post-game analysis + AI review; Progress section + chat
8. Settings page; new Dojo home with link to Classic Maia
9. Desktop: Windows runner, Maia ONNX FFI, platform-channel fallbacks
10. CI: analyze/test, signed APK, Windows zip, releases
11. Verify (tests, golden screenshots at Pixel 8a + desktop sizes), push
