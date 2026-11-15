part of '../../main.dart';

/// Chesster home: start a Dojo game, resume, progress, settings, classic app.
class DojoHome extends StatefulWidget {
  const DojoHome({super.key});

  @override
  State<DojoHome> createState() => _DojoHomeState();
}

class _DojoHomeState extends State<DojoHome> {
  DojoSettings get settings => DojoSettings.instance;
  DojoGame? _resume;

  @override
  void initState() {
    super.initState();
    settings.addListener(_changed);
    unawaited(settings.load());
    unawaited(_refresh());
  }

  @override
  void dispose() {
    settings.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final games = await DojoStore.instance.loadAll();
    if (!mounted) return;
    setState(() => _resume = games.where((g) => !g.isFinished).firstOrNull);
  }

  Future<void> _start() async {
    final side = settings.side == PlayerSide.random
        ? (Random().nextBool() ? PlayerSide.white : PlayerSide.black)
        : settings.side;
    final game = DojoGame.create(opponent: settings.opponent, playerIsWhite: side == PlayerSide.white);
    await DojoStore.instance.save(game);
    await _openGame(game);
  }

  Future<void> _openGame(DojoGame game) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DojoGamePage(game: game)));
    await _refresh();
  }

  Future<void> _openClassic() async {
    await DojoEngine.instance.close();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GamePage()));
    await StockfishAnalyzer.instance.close();
  }

  void _setOpponentKind(DojoOpponentKind kind) {
    final current = settings.opponent;
    if (current.kind == kind) return;
    final elo = kind == DojoOpponentKind.stockfish
        ? current.elo.clamp(dojoStockfishMinElo, dojoStockfishMaxElo)
        : normalizeMaiaRating(current.elo);
    unawaited(settings.setOpponent(DojoOpponent(kind: kind, elo: elo)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opponent = settings.opponent;
    final isStockfish = opponent.kind == DojoOpponentKind.stockfish;
    final minElo = isStockfish ? dojoStockfishMinElo : maiaMinimumRating;
    final maxElo = isStockfish ? dojoStockfishMaxElo : maiaMaximumRating;
    final step = isStockfish ? 50 : maiaRatingStep;
    final elo = opponent.elo.clamp(minElo, maxElo);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chesster'),
        actions: [
          IconButton(
            tooltip: 'Dojo settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DojoSettingsPage()),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              const DojoUpdateBanner(),
              if (_resume != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.play_circle_outline),
                    title: Text('Continue vs ${_resume!.opponent.label}'),
                    subtitle: Text(
                      '${(_resume!.lineThrough(_resume!.currentId).length) ~/ 2} moves · '
                      '${MaterialLocalizations.of(context).formatShortDate(_resume!.started)}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openGame(_resume!),
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('New game', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      SegmentedButton<DojoOpponentKind>(
                        segments: const [
                          ButtonSegment(
                            value: DojoOpponentKind.maia,
                            icon: Icon(Icons.person_outline),
                            label: Text('Maia'),
                          ),
                          ButtonSegment(
                            value: DojoOpponentKind.stockfish,
                            icon: Icon(Icons.memory),
                            label: Text('Stockfish'),
                          ),
                        ],
                        selected: {opponent.kind},
                        onSelectionChanged: (s) => _setOpponentKind(s.first),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isStockfish
                            ? 'Classic engine, strength-limited with UCI_Elo.'
                            : 'Human-like neural net trained on real games at that rating.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text('Strength', style: theme.textTheme.titleSmall),
                          const Spacer(),
                          Text(
                            isStockfish && opponent.fullStrength ? 'Maximum' : '$elo',
                            key: const ValueKey('dojo-elo-label'),
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                      Slider(
                        value: elo.toDouble(),
                        min: minElo.toDouble(),
                        max: maxElo.toDouble(),
                        divisions: (maxElo - minElo) ~/ step,
                        label: '$elo',
                        onChanged: isStockfish && opponent.fullStrength
                            ? null
                            : (v) {
                                final rounded = (minElo + ((v - minElo) / step).round() * step)
                                    .clamp(minElo, maxElo);
                                unawaited(settings.setOpponent(
                                  DojoOpponent(kind: opponent.kind, elo: rounded),
                                ));
                              },
                      ),
                      if (isStockfish)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('Full strength'),
                          value: opponent.fullStrength,
                          onChanged: (v) => unawaited(settings.setOpponent(
                            DojoOpponent(kind: opponent.kind, elo: elo, fullStrength: v),
                          )),
                        ),
                      const SizedBox(height: 4),
                      Text('You play', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      SegmentedButton<PlayerSide>(
                        segments: const [
                          ButtonSegment(value: PlayerSide.white, label: Text('White')),
                          ButtonSegment(value: PlayerSide.random, label: Text('Random')),
                          ButtonSegment(value: PlayerSide.black, label: Text('Black')),
                        ],
                        selected: {settings.side},
                        onSelectionChanged: (s) => unawaited(settings.setSide(s.first)),
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        key: const ValueKey('dojo-home-guidance'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Guidance'),
                        subtitle: const Text('Move checks, momentum bar and AI coach'),
                        value: settings.guidance,
                        onChanged: (v) => unawaited(settings.setGuidance(v)),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        key: const ValueKey('dojo-start'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: _start,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start game'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.show_chart),
                      title: const Text('Progress & games'),
                      subtitle: const Text('History, stats, reports and the progress coach'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => const DojoProgressPage()),
                        );
                        await _refresh();
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const ValueKey('dojo-training'),
                      leading: const Icon(Icons.school_outlined),
                      title: const Text('Training'),
                      subtitle: const Text('Guided openings, endgames and puzzles from your mistakes'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => const DojoTrainingPage()),
                        );
                        await _refresh();
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.grid_view),
                      title: const Text('Classic Maia'),
                      subtitle: const Text('Original app: clocks, analysis board, PGN import, e-boards'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openClassic,
                    ),
                  ],
                ),
              ),
              if (!settings.hasApiKey && settings.loaded)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Tip: add your Claude API key in settings to unlock Explain, the coach chat and AI reviews.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class DojoSettingsPage extends StatefulWidget {
  const DojoSettingsPage({super.key});

  @override
  State<DojoSettingsPage> createState() => _DojoSettingsPageState();
}

class _DojoSettingsPageState extends State<DojoSettingsPage> {
  DojoSettings get settings => DojoSettings.instance;
  late final TextEditingController _key = TextEditingController(text: settings.apiKey);
  late final TextEditingController _stockfish = TextEditingController(text: settings.stockfishPath);
  bool _obscure = true;
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    settings.addListener(_changed);
  }

  @override
  void dispose() {
    settings.removeListener(_changed);
    _key.dispose();
    _stockfish.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _test() async {
    await settings.setApiKey(_key.text);
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final messages = <Map<String, Object?>>[
      {
        'role': 'user',
        'content': 'Reply with exactly: Chesster coach ready.',
      },
    ];
    final text = StringBuffer();
    String? error;
    await for (final event in ClaudeClient.fromSettings().converse(
      system: 'You are a connectivity check.',
      messages: messages,
      maxTokens: 2000,
    )) {
      if (event is CoachTextDelta) text.write(event.text);
      if (event is CoachError) error = event.message;
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = error ?? 'OK — ${text.toString().trim()}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Dojo settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              SwitchListTile(
                key: const ValueKey('dojo-settings-guidance'),
                title: const Text('Guidance'),
                subtitle: const Text(
                  'Move check, momentum bar, Explain and the in-game coach. '
                  'Off = play without help; post-game analysis stays available.',
                ),
                value: settings.guidance,
                onChanged: settings.setGuidance,
              ),
              const Divider(),
              _header('Claude coach'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _key,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Anthropic API key',
                    helperText: 'Stored in the device keystore. Only sent to api.anthropic.com.',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onChanged: (v) => unawaited(settings.setApiKey(v)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.wifi_tethering),
                      label: const Text('Test connection'),
                    ),
                    const SizedBox(width: 12),
                    if (_testResult != null)
                      Expanded(child: Text(_testResult!, style: theme.textTheme.bodySmall)),
                  ],
                ),
              ),
              ListTile(
                title: const Text('Model'),
                trailing: DropdownButton<String>(
                  value: dojoClaudeModels.any((m) => m.$1 == settings.model) ? settings.model : null,
                  items: [
                    for (final m in dojoClaudeModels) DropdownMenuItem(value: m.$1, child: Text(m.$2)),
                  ],
                  onChanged: (v) => v == null ? null : unawaited(settings.setModel(v)),
                ),
              ),
              ListTile(
                title: const Text('Thinking effort'),
                subtitle: const Text('Higher = deeper answers, slower and more tokens'),
                trailing: DropdownButton<String>(
                  value: settings.effort,
                  items: [
                    for (final e in dojoEffortLevels) DropdownMenuItem(value: e, child: Text(e)),
                  ],
                  onChanged: (v) => v == null ? null : unawaited(settings.setEffort(v)),
                ),
              ),
              SwitchListTile(
                title: const Text('Send voice messages automatically'),
                subtitle: const Text('Otherwise review the transcript before sending'),
                value: settings.voiceAutoSend,
                onChanged: settings.setVoiceAutoSend,
              ),
              const Divider(),
              _header('Stockfish'),
              ListTile(
                title: const Text('Analysis strength'),
                subtitle: const Text('Time per position for move checks, the coach and reports'),
                trailing: DropdownButton<DojoAnalysisDepth>(
                  value: settings.analysisDepth,
                  items: [
                    for (final d in DojoAnalysisDepth.values)
                      DropdownMenuItem(value: d, child: Text('${d.label} (${d.movetimeMs} ms)')),
                  ],
                  onChanged: (v) => v == null ? null : unawaited(settings.setAnalysisDepth(v)),
                ),
              ),
              if (isDesktopPlatform)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    controller: _stockfish,
                    decoration: const InputDecoration(
                      labelText: 'Stockfish executable (optional)',
                      helperText: 'Leave empty to use the bundled stockfish.exe',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) async {
                      await settings.setStockfishPath(v);
                      await DojoEngine.instance.close();
                    },
                  ),
                ),
              const Divider(),
              _header('Updates'),
              const DojoUpdateTile(),
              const Divider(),
              _header('Sync'),
              const DojoSyncTile(),
              const Divider(),
              _header('Data'),
              FutureBuilder<String>(
                future: DojoStore.instance.gamesFolder(),
                builder: (context, snapshot) => ListTile(
                  title: const Text('Game logs folder'),
                  subtitle: SelectableText(snapshot.data ?? '…'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
  );
}
