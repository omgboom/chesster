part of '../../main.dart';

/// Drives one persistent coach conversation (game coach, review or progress).
class CoachSession extends ChangeNotifier {
  CoachSession({
    required this.conversation,
    required this.system,
    required this.tools,
    required this.kind,
    required this.onPersist,
    this.contextBuilder,
  });

  final DojoConversation conversation;
  final String system;
  final List<ClaudeTool> tools;
  final String kind;
  final Future<void> Function() onPersist;

  /// Optional hidden context (e.g. the current game state) prepended to each
  /// user message sent to Claude. Returns (context, nodeId).
  final (String, int?) Function()? contextBuilder;

  bool busy = false;
  String? toolNote;

  /// The assistant message currently being streamed (tools attach scenes).
  DojoChatEntry? currentReply;

  List<DojoChatEntry> get entries => conversation.entries;

  Future<void> send(String text, {String? extraContext, String? kindOverride}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || busy) return;
    final context = contextBuilder?.call();
    final parts = [
      if (context != null && context.$1.isNotEmpty) context.$1,
      ?extraContext,
      trimmed,
    ];
    final entryKind = kindOverride ?? kind;
    conversation.entries.add(
      DojoChatEntry(role: 'user', text: trimmed, nodeId: context?.$2, kind: entryKind),
    );
    conversation.apiMessages.add({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': parts.join('\n\n')},
      ],
    });
    final reply = DojoChatEntry(role: 'assistant', text: '', nodeId: context?.$2, kind: entryKind);
    conversation.entries.add(reply);
    currentReply = reply;
    busy = true;
    toolNote = null;
    notifyListeners();
    final sentLength = conversation.apiMessages.length;
    var failed = false;
    try {
      await for (final event in ClaudeClient.fromSettings().converse(
        system: system,
        messages: conversation.apiMessages,
        tools: tools,
      )) {
        switch (event) {
          case CoachTextDelta(:final text):
            reply.text += text;
            toolNote = null;
          case CoachToolNote(:final note):
            toolNote = note;
            reply.toolNotes = [...reply.toolNotes, note];
          case CoachDone(:final truncated):
            if (truncated) reply.text += '\n\n(Answer cut off — ask me to continue.)';
          case CoachError(:final message):
            failed = true;
            conversation.entries.remove(reply);
            conversation.entries.add(DojoChatEntry(role: 'error', text: message, kind: entryKind));
        }
        notifyListeners();
      }
    } finally {
      if (failed && conversation.apiMessages.length == sentLength) {
        // The user turn never got an answer; drop it from the API thread so
        // the next request starts from a valid state.
        conversation.apiMessages.removeLast();
      }
      busy = false;
      toolNote = null;
      currentReply = null;
      notifyListeners();
      await onPersist();
    }
  }
}

/// Speech-to-text wrapper (Android recogniser / Windows speech).
class DojoVoice {
  DojoVoice._();
  static final instance = DojoVoice._();

  final SpeechToText _speech = SpeechToText();
  bool? _available;
  String? lastError;

  bool get isListening => _speech.isListening;

  Future<bool> ensureReady() async {
    if (_available == true) return true;
    try {
      _available = await _speech.initialize(
        onError: (error) => lastError = error.errorMsg,
      );
    } catch (error) {
      lastError = '$error';
      _available = false;
    }
    return _available!;
  }

  Future<void> listen({
    required void Function(String words, bool isFinal) onWords,
  }) async {
    await _speech.listen(
      onResult: (result) => onWords(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> stop() => _speech.stop();
}

/// Opens a chat sheet for [session]. If [initialPrompt] is given it is sent
/// immediately (used by the Explain / AI review buttons).
Future<void> showCoachSheet(
  BuildContext context, {
  required CoachSession session,
  required String title,
  String? initialPrompt,
  String? initialContext,
  String? initialKind,
  List<String> suggestions = const [],
}) {
  if (initialPrompt != null) {
    unawaited(session.send(initialPrompt, extraContext: initialContext, kindOverride: initialKind));
  }
  final wide = MediaQuery.sizeOf(context).width >= 900;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 820),
          child: CoachChatView(session: session, title: title, suggestions: suggestions),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scroll) => CoachChatView(
        session: session,
        title: title,
        suggestions: suggestions,
        scrollController: scroll,
      ),
    ),
  );
}

class CoachChatView extends StatefulWidget {
  const CoachChatView({
    required this.session,
    required this.title,
    this.suggestions = const [],
    this.scrollController,
    this.embedded = false,
    this.onScene,
    this.headerAction,
    super.key,
  });

  /// Called when the student taps a board scene attached to a message.
  final void Function(DojoBoardScene scene)? onScene;

  /// Extra widget in the header (e.g. a "Quick review" button).
  final Widget? headerAction;

  final CoachSession session;
  final String title;
  final List<String> suggestions;
  final ScrollController? scrollController;

  /// Embedded in a side panel (desktop) rather than a sheet.
  final bool embedded;

  @override
  State<CoachChatView> createState() => _CoachChatViewState();
}

class _CoachChatViewState extends State<CoachChatView> {
  final _input = TextEditingController();
  late final ScrollController _scroll = widget.scrollController ?? ScrollController();
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(jump: true));
  }

  @override
  void didUpdateWidget(CoachChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_changed);
      widget.session.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _toBottom();
  }

  void _toBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    if (_listening) unawaited(DojoVoice.instance.stop());
    if (widget.scrollController == null) _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send([String? text]) async {
    final message = text ?? _input.text;
    if (message.trim().isEmpty) return;
    _input.clear();
    if (_listening) await _stopListening();
    await widget.session.send(message);
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _stopListening();
      return;
    }
    final voice = DojoVoice.instance;
    if (!await voice.ensureReady()) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Voice input is unavailable${voice.lastError == null ? '' : ': ${voice.lastError}'}. '
            'Check microphone permission.',
          ),
        ),
      );
      return;
    }
    setState(() => _listening = true);
    final prefix = _input.text.trim().isEmpty ? '' : '${_input.text.trim()} ';
    await voice.listen(
      onWords: (words, isFinal) {
        if (!mounted) return;
        _input.text = '$prefix$words';
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
        if (isFinal) {
          setState(() => _listening = false);
          if (DojoSettings.instance.voiceAutoSend && _input.text.trim().isNotEmpty) {
            unawaited(_send());
          }
        }
      },
    );
  }

  Future<void> _stopListening() async {
    await DojoVoice.instance.stop();
    if (mounted) setState(() => _listening = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = widget.session;
    final entries = session.entries;
    return Material(
      color: widget.embedded ? Colors.transparent : null,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, widget.embedded ? 8 : 0, 4, 4),
            child: Row(
              children: [
                const Icon(Icons.psychology_alt_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title, style: theme.textTheme.titleMedium),
                      Text(
                        '${DojoSettings.instance.modelLabel.split(' (').first} · ${DojoSettings.instance.effort} effort · Stockfish tools',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
                ?widget.headerAction,
                if (!widget.embedded)
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        DojoSettings.instance.hasApiKey
                            ? 'Ask anything about the position or your play. You can also use the microphone.'
                            : 'Add your Claude API key in Dojo settings to talk to the coach.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    itemCount: entries.length + (session.busy && session.toolNote != null ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == entries.length) {
                        return _ToolStatus(session.toolNote!);
                      }
                      return _ChatBubble(
                        entry: entries[index],
                        streaming: session.busy && index == entries.length - 1,
                        onScene: widget.onScene,
                      );
                    },
                  ),
          ),
          if (widget.suggestions.isNotEmpty && !session.busy)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final s in widget.suggestions)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(s, style: theme.textTheme.labelMedium),
                        onPressed: () => _send(s),
                      ),
                    ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                8,
                6,
                8,
                6 + (widget.embedded ? 0 : MediaQuery.viewInsetsOf(context).bottom),
              ),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: _listening ? 'Stop listening' : 'Speak',
                    isSelected: _listening,
                    icon: Icon(_listening ? Icons.mic : Icons.mic_none),
                    onPressed: session.busy ? null : _toggleMic,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: _listening ? 'Listening…' : 'Ask the coach…',
                        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    tooltip: 'Send',
                    icon: session.busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.arrow_upward),
                    onPressed: session.busy ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolStatus extends StatelessWidget {
  const _ToolStatus(this.note);
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(note, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
          ),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.entry, required this.streaming, this.onScene});

  final DojoChatEntry entry;
  final bool streaming;
  final void Function(DojoBoardScene scene)? onScene;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isUser = entry.role == 'user';
    final isError = entry.role == 'error';
    final background = isUser
        ? scheme.primaryContainer
        : isError
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final foreground = isUser
        ? scheme.onPrimaryContainer
        : isError
        ? scheme.onErrorContainer
        : scheme.onSurface;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * (isUser ? 0.8 : 0.92)),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry.text.isEmpty && streaming)
              const SizedBox(width: 24, height: 14, child: LinearProgressIndicator())
            else
              SelectionArea(
                child: DojoMarkdown(entry.text, style: theme.textTheme.bodyMedium?.copyWith(color: foreground)),
              ),
            if (entry.scenes.isNotEmpty && onScene != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final scene in entry.scenes)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(Icons.grid_on, size: 16),
                        label: Text(scene.title, style: theme.textTheme.labelMedium),
                        onPressed: () => onScene!(scene),
                      ),
                  ],
                ),
              ),
            if (!isUser && entry.toolNotes.isNotEmpty && !streaming)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${entry.toolNotes.length} Stockfish check${entry.toolNotes.length == 1 ? '' : 's'}',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tiny Markdown subset renderer: headings, bullets, numbered lists, **bold**.
class DojoMarkdown extends StatelessWidget {
  const DojoMarkdown(this.text, {this.style, super.key});

  final String text;
  final TextStyle? style;

  List<InlineSpan> _inline(String line, TextStyle? base) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final match in pattern.allMatches(line)) {
      if (match.start > last) spans.add(TextSpan(text: line.substring(last, match.start)));
      if (match.group(1) != null) {
        spans.add(TextSpan(text: match.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else {
        spans.add(TextSpan(text: match.group(2), style: const TextStyle(fontFamily: 'monospace')));
      }
      last = match.end;
    }
    if (last < line.length) spans.add(TextSpan(text: line.substring(last)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final children = <Widget>[];
    for (final raw in text.trimRight().split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }
      final heading = RegExp(r'^#{1,6}\s+(.*)').firstMatch(line);
      final bullet = RegExp(r'^(\s*)[-*•]\s+(.*)').firstMatch(line);
      final numbered = RegExp(r'^(\s*)(\d+[.)])\s+(.*)').firstMatch(line);
      if (heading != null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text.rich(
            TextSpan(children: _inline(heading.group(1)!, base)),
            style: base.copyWith(fontWeight: FontWeight.w700),
          ),
        ));
      } else if (bullet != null || numbered != null) {
        final indent = ((bullet?.group(1) ?? numbered!.group(1))!.length / 2).clamp(0, 3) * 12.0;
        final marker = bullet != null ? '•' : numbered!.group(2)!;
        final body = bullet?.group(2) ?? numbered!.group(3)!;
        children.add(Padding(
          padding: EdgeInsets.only(left: indent, top: 1, bottom: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 18, child: Text(marker, style: base)),
              Expanded(child: Text.rich(TextSpan(children: _inline(body, base)), style: base)),
            ],
          ),
        ));
      } else {
        children.add(Text.rich(TextSpan(children: _inline(line, base)), style: base));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}
