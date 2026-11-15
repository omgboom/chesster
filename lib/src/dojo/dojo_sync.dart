part of '../../main.dart';

// Sync of Dojo data through a private GitHub repository owned by the user.
//
// Remote layout: games/<id>.json, progress_chat.json, settings.json.
// The local manifest (<dojo root>/sync_manifest.json, never uploaded) keeps the
// git blob SHA of every file as of the last sync. Git blob SHAs can be computed
// locally, so unchanged files are skipped in both directions without
// downloading anything. All uploads and remote deletions of one sync go into a
// single commit (git trees API), so the repository is never half-updated and
// GitHub's content-creation rate limits are not an issue.

const dojoSyncTokenUrl = 'https://github.com/settings/personal-access-tokens/new';
const dojoSyncNewRepoUrl = 'https://github.com/new';
const dojoSyncDefaultRepo = 'chesster-data';

/// What one sync did.
class DojoSyncSummary {
  int uploaded = 0;
  int downloaded = 0;
  int deletedRemote = 0;
  int deletedLocal = 0;
  int conflicts = 0;
  int unchanged = 0;
  String? error;

  /// Local copies of the losing side of each conflict (relative to the Dojo root).
  final List<String> conflictCopies = [];

  int get deleted => deletedRemote + deletedLocal;
  bool get ok => error == null;

  String describe() {
    if (error != null) return error!;
    final parts = [
      if (uploaded > 0) '$uploaded uploaded',
      if (downloaded > 0) '$downloaded downloaded',
      if (deleted > 0) '$deleted deleted',
      if (conflicts > 0) '$conflicts conflict${conflicts == 1 ? '' : 's'} (newer kept)',
    ];
    return parts.isEmpty ? 'Everything up to date' : parts.join(', ');
  }

  @override
  String toString() => describe();
}

class DojoSyncException implements Exception {
  const DojoSyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Result of [DojoSync.testConnection].
class DojoSyncCheck {
  const DojoSyncCheck(this.ok, this.message, {this.repoMissing = false});
  final bool ok;
  final String message;
  final bool repoMissing;
}

enum DojoSyncAction { none, upload, download, deleteRemote, deleteLocal, conflict }

/// Git's blob id: `sha1("blob <length>\0" + bytes)`.
String dojoGitBlobSha(List<int> bytes) {
  final builder = BytesBuilder(copy: false)
    ..add(utf8.encode('blob ${bytes.length}\u0000'))
    ..add(bytes);
  return crypto.sha1.convert(builder.takeBytes()).toString();
}

class _SyncManifest {
  _SyncManifest(this.repo);

  final String repo;
  final Map<String, String> files = {};
  final Map<String, String> tombstones = {};

  static _SyncManifest fromJson(Object? json, String repo) {
    final manifest = _SyncManifest(repo);
    if (json is! Map) return manifest;
    // Last-synced SHAs only describe the repository they came from; recorded
    // deletions stay valid for any repository (they only act on a match).
    if (json['repo'] == repo) {
      for (final e in (json['files'] as Map? ?? const {}).entries) {
        manifest.files['${e.key}'] = '${e.value}';
      }
    }
    for (final e in (json['tombstones'] as Map? ?? const {}).entries) {
      manifest.tombstones['${e.key}'] = '${e.value}';
    }
    return manifest;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'repo': repo,
    'files': files,
    'tombstones': tombstones,
  };
}

class _LocalFile {
  _LocalFile(this.bytes) : sha = dojoGitBlobSha(bytes);
  final Uint8List bytes;
  final String sha;
}

/// Keeps the Dojo folder in sync with `<owner>/<repo>` on GitHub.
class DojoSync extends ChangeNotifier {
  DojoSync({http.Client? client, this.includeSettings = true, this.persistConfig = true})
    : _clientOverride = client;

  static DojoSync instance = DojoSync();

  static const _repoKey = 'dojoSyncRepoV1';
  static const _lastSyncKey = 'dojoSyncLastV1';
  static const _statusKey = 'dojoSyncStatusV1';
  static const _settingsUpdatedKey = 'dojoSyncSettingsUpdatedV1';
  static const _tokenName = 'dojoGithubTokenV1';
  static const _api = 'api.github.com';
  static const _settingsPath = 'settings.json';
  static const _progressPath = 'progress_chat.json';
  static final _gamePath = RegExp(r'^games/[A-Za-z0-9_-]+\.json$');
  static final _epoch = DateTime.utc(1970);
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// Upload content per tree request; larger syncs are split into several
  /// chained commits and published with one ref update.
  @visibleForTesting
  static int maxChunkChars = 3 * 1024 * 1024;

  final http.Client? _clientOverride;
  http.Client? _defaultClient;
  http.Client get _client => _clientOverride ?? (_defaultClient ??= http.Client());

  /// Sync non-secret Dojo settings (tests may turn this off).
  final bool includeSettings;

  /// Persist owner/repo/token (secure storage) and status.
  final bool persistConfig;

  String owner = '';
  String repo = dojoSyncDefaultRepo;
  String _token = '';
  bool syncing = false;
  DateTime? lastSync;
  String status = 'Not set up';
  DojoSyncSummary? lastSummary;

  bool _started = false;
  bool _configLoaded = false;
  Timer? _timer;
  bool _again = false;
  Future<DojoSyncSummary>? _running;
  Future<void> _lock = Future.value();
  final Map<String, String> _pendingTombstones = {};
  AppLifecycleListener? _lifecycle;
  bool _applyingSettings = false;
  String? _settingsSnapshot;
  DateTime? _settingsUpdated;

  bool get hasToken => _token.isNotEmpty;
  bool get isConfigured => owner.isNotEmpty && repo.isNotEmpty && _token.isNotEmpty;
  String get repoLabel => '$owner/$repo';

  // ---------------------------------------------------------------- lifecycle

  /// Called once after runApp: loads the configuration, hooks settings and app
  /// lifecycle, and runs a first sync shortly after start-up.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await loadConfig();
      await DojoSettings.instance.load();
      _settingsSnapshot = jsonEncode(_settingsContent());
      DojoSettings.instance.addListener(_settingsChanged);
      _lifecycle = AppLifecycleListener(
        onHide: () => _schedule(const Duration(milliseconds: 300)),
        onPause: () => _schedule(const Duration(milliseconds: 300)),
      );
      _schedule(const Duration(seconds: 3));
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-start', error, stackTrace));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    DojoSettings.instance.removeListener(_settingsChanged);
    _defaultClient?.close();
    super.dispose();
  }

  Future<void> loadConfig() async {
    if (_configLoaded || !persistConfig) return;
    _configLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_repoKey) ?? '';
      final slash = saved.indexOf('/');
      if (slash > 0) {
        owner = saved.substring(0, slash);
        repo = saved.substring(slash + 1);
      }
      lastSync = DateTime.tryParse(prefs.getString(_lastSyncKey) ?? '');
      status = prefs.getString(_statusKey) ?? status;
      _settingsUpdated = DateTime.tryParse(prefs.getString(_settingsUpdatedKey) ?? '');
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-config', error, stackTrace));
    }
    try {
      _token = await _secure.read(key: _tokenName) ?? '';
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-token-read', error, stackTrace));
    }
    if (!isConfigured && status == 'Not set up' && owner.isNotEmpty) status = 'Token missing';
    notifyListeners();
  }

  /// Sets the repository and token. An empty [token] keeps the saved one.
  Future<void> configure({required String owner, required String repo, String? token}) async {
    this.owner = owner.trim();
    this.repo = repo.trim().isEmpty ? dojoSyncDefaultRepo : repo.trim();
    if (token != null && token.trim().isNotEmpty) _token = token.trim();
    status = isConfigured ? 'Ready to sync' : 'Not set up';
    notifyListeners();
    if (!persistConfig) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_repoKey, '${this.owner}/${this.repo}');
      await prefs.setString(_statusKey, status);
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-config-save', error, stackTrace));
    }
    try {
      await _secure.write(key: _tokenName, value: _token);
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-token-write', error, stackTrace));
    }
  }

  /// Forgets the token and repository. Local data and the remote repository
  /// are left untouched.
  Future<void> disconnect() async {
    _timer?.cancel();
    _token = '';
    owner = '';
    repo = dojoSyncDefaultRepo;
    status = 'Not set up';
    notifyListeners();
    if (!persistConfig) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_repoKey);
      await prefs.setString(_statusKey, status);
      await _secure.delete(key: _tokenName);
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-disconnect', error, stackTrace));
    }
  }

  // -------------------------------------------------------- change triggers

  /// DojoStore.save hook. Finished games (end of game, report, AI review) sync
  /// soon; moves of a game in progress wait for the app to go to background.
  void noteGameSaved(DojoGame game) {
    if (game.isFinished) _schedule(const Duration(seconds: 8));
  }

  /// DojoStore hook for other saved files (progress chat).
  void noteLocalChange() => _schedule(const Duration(seconds: 15));

  /// DojoStore.delete hook: remembers the deletion so it reaches the remote.
  Future<void> noteGameDeleted(String id) async {
    try {
      _pendingTombstones['games/$id.json'] = DateTime.now().toUtc().toIso8601String();
      // During a sync the pending entry is merged when that sync saves.
      if (!syncing) await _locked(_flushTombstones);
      _schedule(const Duration(seconds: 5));
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-tombstone', error, stackTrace));
    }
  }

  /// Adds pending deletions to the manifest file as-is, so its synced SHAs
  /// survive even while sync is disconnected.
  Future<void> _flushTombstones() async {
    if (_pendingTombstones.isEmpty) return;
    final file = await _manifestFile();
    if (!await file.exists() && !isConfigured) return; // never synced: nothing to delete remotely
    Map<String, Object?> json = {'version': 1, 'repo': repoLabel, 'files': <String, Object?>{}};
    if (await file.exists()) json = (jsonDecode(await file.readAsString()) as Map).cast();
    json['tombstones'] = {...(json['tombstones'] as Map? ?? const {}), ..._pendingTombstones};
    _pendingTombstones.clear();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(json));
    await tmp.rename(file.path);
  }

  void _settingsChanged() {
    if (_applyingSettings || _settingsSnapshot == null) return;
    final snapshot = jsonEncode(_settingsContent());
    if (snapshot == _settingsSnapshot) return;
    _settingsSnapshot = snapshot;
    _settingsUpdated = DateTime.now().toUtc();
    unawaited(_saveSettingsUpdated());
    _schedule(const Duration(seconds: 20));
  }

  Future<void> _saveSettingsUpdated() async {
    if (!persistConfig) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_settingsUpdatedKey, (_settingsUpdated ?? _epoch).toIso8601String());
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-settings-time', error, stackTrace));
    }
  }

  void _schedule(Duration delay) {
    if (!_started || !isConfigured) return;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(syncNow()));
  }

  // ------------------------------------------------------------ connection

  Future<DojoSyncCheck> testConnection() async {
    if (_token.isEmpty) return const DojoSyncCheck(false, 'Paste a GitHub token first.');
    try {
      final user = await _request('GET', ['user']);
      if (user.statusCode == 401) {
        return const DojoSyncCheck(false, 'GitHub rejected the token. Is it expired or mistyped?');
      }
      _check(user, 'Checking the token');
      final login = '${(jsonDecode(user.body) as Map)['login'] ?? ''}';
      if (owner.isEmpty && login.isNotEmpty) await configure(owner: login, repo: repo);
      final info = await _request('GET', ['repos', owner, repo]);
      if (info.statusCode == 404) {
        return DojoSyncCheck(
          false,
          'Signed in as $login, but $repoLabel was not found or the token has no access to it.',
          repoMissing: true,
        );
      }
      _check(info, 'Opening $repoLabel');
      final json = jsonDecode(info.body) as Map;
      if (json['private'] != true) {
        return DojoSyncCheck(false, '$repoLabel is public. Make it private before syncing your games.');
      }
      return DojoSyncCheck(true, 'Connected to $repoLabel (private) as $login.');
    } on DojoSyncException catch (e) {
      return DojoSyncCheck(false, e.message);
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-test', error, stackTrace));
      return DojoSyncCheck(false, 'Could not reach GitHub: $error');
    }
  }

  /// Creates `<owner>/<repo>` as a private repository. Works only with tokens
  /// that may create repositories (a token limited to one repository cannot).
  Future<DojoSyncCheck> createRepository() async {
    try {
      final response = await _request('POST', ['user', 'repos'], body: {
        'name': repo,
        'private': true,
        'description': 'Chesster Dojo sync data (games, coach chats, settings)',
        'auto_init': true,
      });
      if (response.statusCode == 201) {
        final json = jsonDecode(response.body) as Map;
        final createdOwner = '${(json['owner'] as Map?)?['login'] ?? owner}';
        await configure(owner: createdOwner, repo: '${json['name'] ?? repo}');
        return DojoSyncCheck(true, 'Created private repository $repoLabel.');
      }
      if (response.statusCode == 422) {
        return DojoSyncCheck(false, 'A repository named $repo already exists. Give the token access to it.');
      }
      return DojoSyncCheck(
        false,
        'This token cannot create repositories (normal for a token limited to one repository). '
        'Create a private repository named $repo at github.com/new, then give the token access to it.',
      );
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-create', error, stackTrace));
      return DojoSyncCheck(false, 'Could not reach GitHub: $error');
    }
  }

  // ------------------------------------------------------------------ sync

  /// Runs one sync (or joins the one in progress). Never throws.
  Future<DojoSyncSummary> syncNow() {
    _timer?.cancel();
    if (_running != null) {
      _again = true;
      return _running!;
    }
    final run = _syncGuarded();
    _running = run;
    return run.whenComplete(() {
      _running = null;
      if (_again) {
        _again = false;
        _schedule(const Duration(seconds: 2));
      }
    });
  }

  Future<DojoSyncSummary> _syncGuarded() async {
    final summary = DojoSyncSummary();
    if (!isConfigured) {
      summary.error = 'Sync is not set up';
      return summary;
    }
    syncing = true;
    status = 'Syncing…';
    notifyListeners();
    try {
      await _locked(() => _sync(summary));
      lastSync = DateTime.now();
      status = 'Synced: ${summary.describe()}';
    } catch (error, stackTrace) {
      summary.error = error is DojoSyncException ? error.message : 'Sync failed: $error';
      status = summary.error!;
      unawaited(AppDiagnostics.record('dojo-sync', error, stackTrace));
    } finally {
      syncing = false;
      lastSummary = summary;
      notifyListeners();
      unawaited(_saveStatus());
    }
    return summary;
  }

  Future<void> _saveStatus() async {
    if (!persistConfig) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_statusKey, status);
      if (lastSync != null) await prefs.setString(_lastSyncKey, lastSync!.toIso8601String());
    } catch (_) {
      // Status display only.
    }
  }

  Future<T> _locked<T>(Future<T> Function() body) {
    final result = _lock.then((_) => body());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Three-way decision from the local, remote and last-synced blob SHAs.
  /// A local file that disappeared without a recorded deletion is restored
  /// from the remote rather than deleting the remote copy.
  @visibleForTesting
  static DojoSyncAction decide({
    required String? local,
    required String? remote,
    required String? base,
    bool tombstone = false,
  }) {
    if (local == remote) return DojoSyncAction.none;
    if (local == null) {
      return tombstone && base != null && remote == base ? DojoSyncAction.deleteRemote : DojoSyncAction.download;
    }
    if (remote == null) {
      return base != null && local == base ? DojoSyncAction.deleteLocal : DojoSyncAction.upload;
    }
    if (remote == base) return DojoSyncAction.upload;
    if (local == base) return DojoSyncAction.download;
    return DojoSyncAction.conflict;
  }

  Future<void> _sync(DojoSyncSummary summary) async {
    final repoInfo = await _request('GET', ['repos', owner, repo]);
    _check(repoInfo, 'Opening $repoLabel');
    final info = jsonDecode(repoInfo.body) as Map;
    if (info['private'] != true) {
      throw DojoSyncException('$repoLabel is public. Make it private before syncing.');
    }
    final branch = '${info['default_branch'] ?? 'main'}';

    var head = await _headCommit(branch);
    if (head == null) {
      await _initializeEmptyRepo();
      head = await _headCommit(branch);
      if (head == null) throw const DojoSyncException('Could not initialise the empty repository.');
    }

    final treeResponse = await _request('GET', ['repos', owner, repo, 'git', 'trees', head], query: {'recursive': '1'});
    _check(treeResponse, 'Listing files');
    final tree = jsonDecode(treeResponse.body) as Map;
    if (tree['truncated'] == true) throw const DojoSyncException('The repository has too many files to list.');
    final baseTree = '${tree['sha']}';
    final remote = <String, String>{
      for (final entry in (tree['tree'] as List? ?? const []))
        if (entry is Map && entry['type'] == 'blob' && _isSyncPath('${entry['path']}'))
          '${entry['path']}': '${entry['sha']}',
    };

    final manifest = await _loadManifest();
    _mergePendingTombstones(manifest);
    final local = await _scanLocal();
    final uploads = <String, Uint8List>{};
    final remoteDeletes = <String>{};

    final paths = {...local.keys, ...remote.keys, ...manifest.files.keys, ...manifest.tombstones.keys}.toList()..sort();
    for (final path in paths) {
      final l = local[path];
      final r = remote[path];
      final base = manifest.files[path];
      if (l != null) manifest.tombstones.remove(path); // saved again after a delete
      final action = decide(local: l?.sha, remote: r, base: base, tombstone: manifest.tombstones.containsKey(path));
      switch (action) {
        case DojoSyncAction.none:
          if (l != null) {
            manifest.files[path] = l.sha;
            if (base == l.sha) summary.unchanged++;
          } else {
            manifest.files.remove(path);
          }
          manifest.tombstones.remove(path);
        case DojoSyncAction.upload:
          uploads[path] = l!.bytes;
        case DojoSyncAction.deleteRemote:
          remoteDeletes.add(path);
        case DojoSyncAction.download:
          final bytes = await _downloadBlob(r!);
          if (await _writeLocal(path, bytes, expectedSha: l?.sha)) {
            manifest.files[path] = r;
            manifest.tombstones.remove(path);
            summary.downloaded++;
          }
        case DojoSyncAction.deleteLocal:
          if (await _deleteLocal(path, expectedSha: l!.sha)) {
            manifest.files.remove(path);
            summary.deletedLocal++;
          }
        case DojoSyncAction.conflict:
          final remoteBytes = await _downloadBlob(r!);
          final localWins = _updatedOf(l!.bytes).isAfter(_updatedOf(remoteBytes));
          if (path != _settingsPath) summary.conflicts++;
          if (localWins) {
            if (path != _settingsPath) summary.conflictCopies.add(await _keepConflictCopy(path, remoteBytes));
            uploads[path] = l.bytes;
          } else {
            if (path != _settingsPath) summary.conflictCopies.add(await _keepConflictCopy(path, l.bytes));
            if (await _writeLocal(path, remoteBytes, expectedSha: l.sha)) {
              manifest.files[path] = r;
              summary.downloaded++;
            }
          }
      }
    }
    // Downloads are already applied; record them even if the upload fails.
    await _saveManifest(manifest);

    if (uploads.isNotEmpty || remoteDeletes.isNotEmpty) {
      await _commit(branch, head, baseTree, uploads, remoteDeletes);
      for (final e in uploads.entries) {
        manifest.files[e.key] = dojoGitBlobSha(e.value);
        manifest.tombstones.remove(e.key);
      }
      for (final path in remoteDeletes) {
        manifest.files.remove(path);
        manifest.tombstones.remove(path);
      }
      summary.uploaded = uploads.length;
      summary.deletedRemote = remoteDeletes.length;
    }
    _mergePendingTombstones(manifest);
    await _saveManifest(manifest);
  }

  void _mergePendingTombstones(_SyncManifest manifest) {
    manifest.tombstones.addAll(_pendingTombstones);
    _pendingTombstones.clear();
  }

  bool _isSyncPath(String path) =>
      _gamePath.hasMatch(path) || path == _progressPath || (includeSettings && path == _settingsPath);

  Future<String?> _headCommit(String branch) async {
    final response = await _request('GET', ['repos', owner, repo, 'git', 'ref', 'heads', branch]);
    // An empty repository has no branch yet: 409 (empty) or 404 (no ref).
    if (response.statusCode == 404 || response.statusCode == 409) return null;
    _check(response, 'Reading $branch');
    return '${((jsonDecode(response.body) as Map)['object'] as Map)['sha']}';
  }

  Future<void> _initializeEmptyRepo() async {
    const readme = '# Chesster data\n\nPrivate sync data for the Chesster Dojo. Managed by the app.\n';
    final response = await _request('PUT', ['repos', owner, repo, 'contents', 'README.md'], body: {
      'message': 'Initialise Chesster sync',
      'content': base64Encode(utf8.encode(readme)),
    });
    _check(response, 'Initialising the repository');
  }

  Future<Uint8List> _downloadBlob(String sha) async {
    final response = await _request(
      'GET',
      ['repos', owner, repo, 'git', 'blobs', sha],
      accept: 'application/vnd.github.raw+json',
    );
    _check(response, 'Downloading');
    return response.bodyBytes;
  }

  Future<void> _commit(
    String branch,
    String head,
    String baseTree,
    Map<String, Uint8List> uploads,
    Set<String> deletes,
  ) async {
    final chunks = <List<Map<String, Object?>>>[[]];
    var size = 0;
    for (final e in uploads.entries) {
      final Map<String, Object?> entry = {'path': e.key, 'mode': '100644', 'type': 'blob'};
      String? text;
      try {
        text = utf8.decode(e.value);
      } on FormatException {
        text = null;
      }
      if (text != null) {
        entry['content'] = text;
      } else {
        final blob = await _request('POST', ['repos', owner, repo, 'git', 'blobs'],
            body: {'content': base64Encode(e.value), 'encoding': 'base64'});
        _check(blob, 'Uploading ${e.key}');
        entry['sha'] = (jsonDecode(blob.body) as Map)['sha'];
      }
      final length = text?.length ?? 64;
      if (size > 0 && size + length > maxChunkChars) {
        chunks.add([]);
        size = 0;
      }
      chunks.last.add(entry);
      size += length;
    }
    for (final path in deletes) {
      chunks.last.add({'path': path, 'mode': '100644', 'type': 'blob', 'sha': null});
    }

    var tree = baseTree;
    var parent = head;
    final device = isDesktopPlatform ? Platform.operatingSystem : 'phone';
    for (final chunk in chunks) {
      final treeResponse = await _request('POST', ['repos', owner, repo, 'git', 'trees'],
          body: {'base_tree': tree, 'tree': chunk});
      _check(treeResponse, 'Uploading');
      tree = '${(jsonDecode(treeResponse.body) as Map)['sha']}';
      final commit = await _request('POST', ['repos', owner, repo, 'git', 'commits'], body: {
        'message': 'Chesster sync from $device: ${uploads.length} updated, ${deletes.length} deleted',
        'tree': tree,
        'parents': [parent],
      });
      _check(commit, 'Committing');
      parent = '${(jsonDecode(commit.body) as Map)['sha']}';
    }
    final ref = await _request('PATCH', ['repos', owner, repo, 'git', 'refs', 'heads', branch],
        body: {'sha': parent, 'force': false});
    if (ref.statusCode == 422 || ref.statusCode == 409) {
      throw const DojoSyncException('Another device synced at the same time. Try again.');
    }
    _check(ref, 'Publishing the commit');
  }

  // ---------------------------------------------------------- local files

  Future<File> _manifestFile() async =>
      File('${(await DojoStore.instance.root()).path}${Platform.pathSeparator}sync_manifest.json');

  Future<_SyncManifest> _loadManifest() async {
    final file = await _manifestFile();
    try {
      if (await file.exists()) return _SyncManifest.fromJson(jsonDecode(await file.readAsString()), repoLabel);
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-manifest', error, stackTrace));
    }
    return _SyncManifest(repoLabel);
  }

  Future<void> _saveManifest(_SyncManifest manifest) async {
    final file = await _manifestFile();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(manifest.toJson()));
    await tmp.rename(file.path);
  }

  Future<File> _fileFor(String path) async {
    final root = (await DojoStore.instance.root()).path;
    return File([root, ...path.split('/')].join(Platform.pathSeparator));
  }

  Future<Map<String, _LocalFile>> _scanLocal() async {
    final result = <String, _LocalFile>{};
    final games = Directory('${(await DojoStore.instance.root()).path}${Platform.pathSeparator}games');
    if (await games.exists()) {
      await for (final entity in games.list()) {
        if (entity is! File) continue;
        final path = 'games/${entity.uri.pathSegments.last}';
        if (!_gamePath.hasMatch(path)) continue;
        result[path] = _LocalFile(await entity.readAsBytes());
      }
    }
    final progress = await _fileFor(_progressPath);
    if (await progress.exists()) result[_progressPath] = _LocalFile(await progress.readAsBytes());
    if (includeSettings) result[_settingsPath] = _LocalFile(_settingsBytes());
    return result;
  }

  /// Writes a downloaded file unless the local copy changed during this sync.
  Future<bool> _writeLocal(String path, Uint8List bytes, {String? expectedSha}) async {
    final Map<String, Object?> json;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const FormatException('not a JSON object');
      json = decoded.cast<String, Object?>();
      if (_gamePath.hasMatch(path)) {
        final game = DojoGame.fromJson(json);
        if ('games/${game.id}.json' != path) throw const FormatException('game id does not match file name');
      }
    } catch (error, stackTrace) {
      unawaited(AppDiagnostics.record('dojo-sync-invalid-$path', error, stackTrace));
      return false;
    }
    if (path == _settingsPath) {
      await _applySettings(json);
      return true;
    }
    final file = await _fileFor(path);
    if (!await _matches(file, expectedSha)) return false;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return true;
  }

  Future<bool> _deleteLocal(String path, {required String expectedSha}) async {
    if (path == _settingsPath) return false;
    final file = await _fileFor(path);
    if (!await _matches(file, expectedSha)) return false;
    await file.delete();
    return true;
  }

  Future<bool> _matches(File file, String? expectedSha) async {
    final exists = await file.exists();
    if (expectedSha == null) return !exists;
    return exists && dojoGitBlobSha(await file.readAsBytes()) == expectedSha;
  }

  Future<String> _keepConflictCopy(String path, Uint8List bytes) async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[-:]|\.\d+'), '');
    final dot = path.lastIndexOf('.');
    final relative = 'conflicts/${path.substring(0, dot)}.conflict-$stamp${path.substring(dot)}';
    final file = await _fileFor(relative);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return relative;
  }

  DateTime _updatedOf(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map;
      for (final key in const ['updated', 'finished', 'started']) {
        final value = DateTime.tryParse('${json[key] ?? ''}');
        if (value != null) return value.toUtc();
      }
    } catch (_) {
      // Unreadable copies lose.
    }
    return _epoch;
  }

  // ------------------------------------------------------------- settings

  Map<String, Object?> _settingsContent() {
    final s = DojoSettings.instance;
    return {
      'guidance': s.guidance,
      'model': s.model,
      'effort': s.effort,
      'opponent': s.opponent.toJson(),
      'side': s.side.name,
      'analysisDepth': s.analysisDepth.name,
      'voiceAutoSend': s.voiceAutoSend,
    };
  }

  /// Non-secret settings only: never the API key, the GitHub token or the
  /// device-specific Stockfish path.
  Uint8List _settingsBytes() => Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert({
    'updated': (_settingsUpdated ?? _epoch).toUtc().toIso8601String(),
    ..._settingsContent(),
  })));

  Future<void> _applySettings(Map<String, Object?> json) async {
    final s = DojoSettings.instance;
    _applyingSettings = true;
    try {
      if (json['guidance'] is bool) await s.setGuidance(json['guidance'] as bool);
      if (json['model'] is String) await s.setModel(json['model'] as String);
      if (json['effort'] is String && dojoEffortLevels.contains(json['effort'])) {
        await s.setEffort(json['effort'] as String);
      }
      if (json['opponent'] is Map) await s.setOpponent(DojoOpponent.fromJson(json['opponent']));
      for (final side in PlayerSide.values) {
        if (side.name == json['side']) await s.setSide(side);
      }
      for (final depth in DojoAnalysisDepth.values) {
        if (depth.name == json['analysisDepth']) await s.setAnalysisDepth(depth);
      }
      if (json['voiceAutoSend'] is bool) await s.setVoiceAutoSend(json['voiceAutoSend'] as bool);
      _settingsUpdated = DateTime.tryParse('${json['updated'] ?? ''}')?.toUtc() ?? _epoch;
      _settingsSnapshot = jsonEncode(_settingsContent());
      await _saveSettingsUpdated();
    } finally {
      _applyingSettings = false;
    }
  }

  // ----------------------------------------------------------------- http

  Future<http.Response> _request(
    String method,
    List<String> segments, {
    Map<String, String>? query,
    Object? body,
    String accept = 'application/vnd.github+json',
  }) async {
    final uri = Uri(scheme: 'https', host: _api, pathSegments: segments, queryParameters: query);
    final request = http.Request(method, uri)
      ..headers.addAll({
        'Authorization': 'Bearer $_token',
        'Accept': accept,
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Chesster',
      });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final streamed = await _client.send(request).timeout(const Duration(seconds: 60));
    return http.Response.fromStream(streamed).timeout(const Duration(seconds: 120));
  }

  void _check(http.Response response, String what) {
    final code = response.statusCode;
    if (code >= 200 && code < 300) return;
    final message = switch (code) {
      401 => 'GitHub rejected the token. Is it expired or revoked?',
      403 when response.headers['x-ratelimit-remaining'] == '0' => 'GitHub rate limit reached. Try again later.',
      403 => 'The token lacks permission. It needs Contents: read and write on $repoLabel.',
      404 => '$repoLabel was not found, or the token has no access to it.',
      _ => '$what failed (GitHub $code).',
    };
    throw DojoSyncException(message);
  }
}

String _dojoSyncTime(DateTime time) {
  final t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// One-line entry for DojoSettingsPage.
class DojoSyncTile extends StatelessWidget {
  const DojoSyncTile({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = DojoSync.instance;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => ListTile(
        key: const ValueKey('dojo-sync-tile'),
        leading: Icon(sync.syncing ? Icons.sync : (sync.isConfigured ? Icons.cloud_done_outlined : Icons.cloud_off)),
        title: const Text('Sync with GitHub'),
        subtitle: Text(
          sync.isConfigured ? '${sync.repoLabel} · ${sync.status}' : 'Off. Keep games in step between phone and PC',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DojoSyncPage())),
      ),
    );
  }
}

/// Setup and status screen for GitHub sync.
class DojoSyncPage extends StatefulWidget {
  const DojoSyncPage({super.key});

  @override
  State<DojoSyncPage> createState() => _DojoSyncPageState();
}

class _DojoSyncPageState extends State<DojoSyncPage> {
  DojoSync get sync => DojoSync.instance;
  late final TextEditingController _owner = TextEditingController(text: sync.owner);
  late final TextEditingController _repo = TextEditingController(text: sync.repo);
  final TextEditingController _token = TextEditingController();
  bool _busy = false;
  DojoSyncCheck? _check;

  @override
  void initState() {
    super.initState();
    sync.addListener(_changed);
    unawaited(sync.loadConfig().then((_) {
      if (!mounted) return;
      _owner.text = sync.owner;
      _repo.text = sync.repo;
    }));
  }

  @override
  void dispose() {
    sync.removeListener(_changed);
    _owner.dispose();
    _repo.dispose();
    _token.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAndTest() => _run(() async {
    await sync.configure(owner: _owner.text, repo: _repo.text, token: _token.text);
    _token.clear();
    final check = await sync.testConnection();
    _owner.text = sync.owner;
    if (mounted) setState(() => _check = check);
    if (check.ok) await sync.syncNow();
  });

  Future<void> _create() => _run(() async {
    final check = await sync.createRepository();
    if (mounted) setState(() => _check = check);
    if (check.ok) await sync.syncNow();
  });

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect sync?'),
        content: const Text(
          'The token is removed from this device. Your games stay here and in the GitHub repository.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (confirmed != true) return;
    await sync.disconnect();
    if (!mounted) return;
    setState(() => _check = null);
    _owner.text = '';
    _repo.text = sync.repo;
  }

  void _open(String url) => unawaited(
    maiaEngineChannel.invokeMethod<void>('openUrl', {'url': url}).catchError(
      (Object error, StackTrace stack) => AppDiagnostics.record('dojo-sync-open-url', error, stack),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = sync.lastSummary;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: sync.syncing
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(sync.isConfigured ? Icons.cloud_done_outlined : Icons.cloud_off),
                  title: Text(sync.isConfigured ? sync.repoLabel : 'Sync is off'),
                  subtitle: Text([
                    sync.status,
                    if (sync.lastSync != null) 'Last sync ${_dojoSyncTime(sync.lastSync!)}',
                    if (summary != null && summary.conflictCopies.isNotEmpty)
                      'Older conflict copies kept in the Dojo folder under conflicts/',
                  ].join('\n')),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton.icon(
                    key: const ValueKey('dojo-sync-now'),
                    onPressed: !sync.isConfigured || sync.syncing || _busy ? null : () => _run(sync.syncNow),
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync now'),
                  ),
                  const Spacer(),
                  if (sync.isConfigured)
                    TextButton(onPressed: _busy ? null : _disconnect, child: const Text('Disconnect')),
                ],
              ),
              const SizedBox(height: 16),
              Text('Repository', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _owner,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Owner',
                        helperText: 'Your GitHub user name (filled in automatically)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _repo,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Repository', border: OutlineInputBorder()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('dojo-sync-token'),
                controller: _token,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'GitHub token',
                  helperText: sync.hasToken
                      ? 'A token is saved in secure storage. Paste a new one to replace it.'
                      : 'Stored in secure storage. Only sent to api.github.com. Never synced.',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _saveAndTest,
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Save & test'),
                  ),
                  if (_check?.repoMissing == true)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _create,
                      icon: const Icon(Icons.add),
                      label: const Text('Create private repository'),
                    ),
                ],
              ),
              if (_check != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _check!.message,
                    style: theme.textTheme.bodySmall?.copyWith(color: _check!.ok ? null : theme.colorScheme.error),
                  ),
                ),
              const Divider(height: 32),
              Text('How to set it up', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              const Text(
                '1. Create a private repository on GitHub, for example "chesster-data". '
                'It can be empty.\n'
                '2. Create a fine-grained personal access token:\n'
                '   • Repository access: Only select repositories → your data repository\n'
                '   • Repository permissions: Contents → Read and write\n'
                '     (Metadata: Read-only is added automatically)\n'
                '   • Nothing else. Pick an expiry you are happy with.\n'
                '3. Paste the token here, tap Save & test, and do the same on your other device.',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => _open(dojoSyncNewRepoUrl),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('New repository'),
                  ),
                  TextButton.icon(
                    onPressed: () => _open(dojoSyncTokenUrl),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('New token'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Synced: every Dojo game (moves, analysis, coach chats, reports), the progress coach chat '
                'and Dojo preferences. Never synced: your Anthropic API key, the GitHub token and the '
                'Stockfish path. Sync runs at start-up, after a game or report is saved and when the app '
                'goes to the background. If both devices changed the same game, the newer copy wins and '
                'the other is kept under conflicts/ in the Dojo folder.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
