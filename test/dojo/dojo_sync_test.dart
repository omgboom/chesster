import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maia_chess/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory GitHub: repo info, refs, recursive trees, raw blobs, tree and
/// commit creation and fast-forward-only ref updates.
class FakeGitHub {
  FakeGitHub({this.empty = false, this.private = true});

  bool empty;
  bool private;
  final blobs = <String, Uint8List>{};
  final trees = <String, Map<String, String>>{}; // tree sha -> path -> blob sha
  final commits = <String, ({String tree, String? parent})>{};
  String? head;
  final requests = <String>[];
  void Function()? beforeRefUpdate;
  int _counter = 0;

  String _id(String prefix) => '$prefix${(++_counter).toString().padLeft(8, '0')}';

  String _treeOf(Map<String, String> files) {
    final sha = _id('tree');
    trees[sha] = Map.of(files);
    return sha;
  }

  /// Files at the current head.
  Map<String, String> get files => head == null ? {} : trees[commits[head]!.tree]!;

  String? text(String path) {
    final sha = files[path];
    return sha == null ? null : utf8.decode(blobs[sha]!);
  }

  /// Writes as another device would (one commit).
  void put(String path, String content) => _commitFiles({...files, path: _blob(utf8.encode(content))});

  void remove(String path) => _commitFiles({...files}..remove(path));

  String _blob(List<int> bytes) {
    final sha = dojoGitBlobSha(bytes);
    blobs[sha] = Uint8List.fromList(bytes);
    return sha;
  }

  void _commitFiles(Map<String, String> files) {
    final sha = _id('commit');
    commits[sha] = (tree: _treeOf(files), parent: head);
    head = sha;
    empty = false;
  }

  int count(String prefix) => requests.where((r) => r.startsWith(prefix)).length;

  late final MockClient client = MockClient((request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
    expect(request.headers['Authorization'], 'Bearer test-token');
    final body = request.body.isEmpty ? null : jsonDecode(request.body) as Map;
    const repo = '/repos/me/chesster-data';

    if (request.method == 'GET' && path == '/user') return json({'login': 'me'});
    if (request.method == 'GET' && path == repo) {
      return json({'private': private, 'default_branch': 'main'});
    }
    if (request.method == 'GET' && path == '$repo/git/ref/heads/main') {
      if (empty || head == null) return json({'message': 'Git Repository is empty.'}, 409);
      return json({'object': {'sha': head}});
    }
    if (request.method == 'PUT' && path == '$repo/contents/README.md') {
      put('README.md', utf8.decode(base64Decode(body!['content'] as String)));
      return json({}, 201);
    }
    if (request.method == 'GET' && path.startsWith('$repo/git/trees/')) {
      final commit = commits[path.split('/').last]!;
      expect(request.url.queryParameters['recursive'], '1');
      return json({
        'sha': commit.tree,
        'truncated': false,
        'tree': [
          for (final e in trees[commit.tree]!.entries) {'path': e.key, 'type': 'blob', 'mode': '100644', 'sha': e.value},
        ],
      });
    }
    if (request.method == 'GET' && path.startsWith('$repo/git/blobs/')) {
      expect(request.headers['Accept'], 'application/vnd.github.raw+json');
      return http.Response.bytes(blobs[path.split('/').last]!, 200);
    }
    if (request.method == 'POST' && path == '$repo/git/trees') {
      final files = Map.of(trees[body!['base_tree']]!);
      for (final entry in (body['tree'] as List).cast<Map>()) {
        final p = entry['path'] as String;
        if (entry.containsKey('content')) {
          files[p] = _blob(utf8.encode(entry['content'] as String));
        } else if (entry['sha'] == null) {
          files.remove(p);
        } else {
          files[p] = entry['sha'] as String;
        }
      }
      return json({'sha': _treeOf(files)}, 201);
    }
    if (request.method == 'POST' && path == '$repo/git/commits') {
      final sha = _id('commit');
      commits[sha] = (tree: body!['tree'] as String, parent: (body['parents'] as List).single as String);
      return json({'sha': sha}, 201);
    }
    if (request.method == 'PATCH' && path == '$repo/git/refs/heads/main') {
      final sha = body!['sha'] as String;
      final hook = beforeRefUpdate;
      beforeRefUpdate = null;
      hook?.call();
      // Fast-forward only.
      String? walk = sha;
      while (walk != null && walk != head) {
        walk = commits[walk]?.parent;
      }
      if (walk != head) return json({'message': 'Update is not a fast forward'}, 422);
      head = sha;
      return json({'object': {'sha': sha}});
    }
    return json({'message': 'Not Found'}, 404);
  });
}

/// One simulated device: its own Dojo folder and sync state.
class Device {
  Device(this.name, FakeGitHub github, {bool includeSettings = false})
    : root = Directory.systemTemp.createTempSync('dojo_sync_$name'),
      sync = DojoSync(client: github.client, includeSettings: includeSettings, persistConfig: false) {
    Directory('${root.path}/games').createSync();
  }

  final String name;
  final Directory root;
  final DojoSync sync;

  Future<T> run<T>(Future<T> Function() body) async {
    DojoStore.overrideRoot = root;
    DojoSync.instance = sync;
    return body();
  }

  Future<void> connect() => sync.configure(owner: 'me', repo: 'chesster-data', token: 'test-token');

  Future<DojoSyncSummary> syncNow() => run(sync.syncNow);

  Future<void> save(DojoGame game) => run(() => DojoStore.instance.save(game));

  Future<DojoGame?> load(String id) => run(() => DojoStore.instance.load(id));

  File file(String relative) => File('${root.path}/$relative');

  List<String> conflictFiles() {
    final dir = Directory('${root.path}/conflicts/games');
    if (!dir.existsSync()) return [];
    return [for (final f in dir.listSync()) f.uri.pathSegments.last];
  }
}

DojoGame game(String id, {String? reason}) => DojoGame(
  id: id,
  opponent: const DojoOpponent(kind: DojoOpponentKind.maia, elo: 1500),
  playerIsWhite: true,
  started: DateTime.utc(2026, 11, 1),
  resultReason: reason,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGitHub github;
  late Device a;
  late Device b;
  final roots = <Directory>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    github = FakeGitHub();
    a = Device('a', github);
    b = Device('b', github);
    roots.addAll([a.root, b.root]);
    await a.connect();
    await b.connect();
  });

  tearDown(() {
    DojoStore.overrideRoot = null;
    DojoSync.instance = DojoSync();
    for (final dir in roots) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    roots.clear();
  });

  group('decide', () {
    test('three-way rules', () {
      DojoSyncAction d(String? l, String? r, String? base, {bool tomb = false}) =>
          DojoSync.decide(local: l, remote: r, base: base, tombstone: tomb);
      expect(d('x', 'x', null), DojoSyncAction.none);
      expect(d('x', null, null), DojoSyncAction.upload);
      expect(d(null, 'x', null), DojoSyncAction.download);
      expect(d('y', 'x', 'x'), DojoSyncAction.upload);
      expect(d('x', 'y', 'x'), DojoSyncAction.download);
      expect(d('y', 'z', 'x'), DojoSyncAction.conflict);
      expect(d('y', 'z', null), DojoSyncAction.conflict);
      expect(d('x', null, 'x'), DojoSyncAction.deleteLocal);
      expect(d('y', null, 'x'), DojoSyncAction.upload, reason: 'edited locally after a remote delete');
      expect(d(null, 'x', 'x', tomb: true), DojoSyncAction.deleteRemote);
      expect(d(null, 'y', 'x', tomb: true), DojoSyncAction.download, reason: 'edited remotely after a local delete');
      expect(d(null, 'x', 'x'), DojoSyncAction.download, reason: 'vanished without a recorded delete: restore');
    });

    test('blob sha matches git', () {
      // `printf 'hello\n' | git hash-object --stdin`
      expect(dojoGitBlobSha(utf8.encode('hello\n')), 'ce013625030ba8dba906f756967f9e9ca394464a');
    });
  });

  test('first sync initialises an empty repo and uploads everything in one commit', () async {
    github.empty = true;
    await a.save(game('g1'));
    await a.save(game('g2'));
    await a.run(() => DojoStore.instance.saveProgressChat(DojoConversation(entries: [DojoChatEntry(role: 'user', text: 'hi')])));

    final summary = await a.syncNow();

    expect(summary.ok, isTrue, reason: summary.error);
    expect(summary.uploaded, 3);
    expect(github.files.keys, containsAll(['README.md', 'games/g1.json', 'games/g2.json', 'progress_chat.json']));
    expect(github.count('POST /repos/me/chesster-data/git/commits'), 1);
    expect(github.text('games/g1.json'), a.file('games/g1.json').readAsStringSync());
    expect(jsonDecode(github.text('games/g1.json')!)['updated'], isNotNull);
    expect(a.file('sync_manifest.json').existsSync(), isTrue);
    expect(github.files.keys, isNot(contains('sync_manifest.json')));
  });

  test('remote-only file downloads', () async {
    await b.save(game('g9', reason: 'from phone'));
    expect((await b.syncNow()).uploaded, 1);

    final summary = await a.syncNow();

    expect(summary.downloaded, 1);
    expect((await a.load('g9'))!.resultReason, 'from phone');
  });

  test('unchanged files are skipped both ways', () async {
    await a.save(game('g1'));
    await a.syncNow();
    await b.syncNow();
    github.requests.clear();

    final again = await a.syncNow();
    final other = await b.syncNow();

    expect(again.uploaded + again.downloaded, 0);
    expect(other.uploaded + other.downloaded, 0);
    expect(again.unchanged, 1);
    expect(github.count('POST'), 0);
    expect(github.count('PATCH'), 0);
    expect(github.count('PUT'), 0);
    expect(github.count('GET /repos/me/chesster-data/git/blobs'), 0);
    expect(again.describe(), 'Everything up to date');
  });

  test('a local edit uploads and the other device downloads it', () async {
    await a.save(game('g1'));
    await a.syncNow();
    await b.syncNow();

    await a.save(game('g1', reason: 'edited'));
    expect((await a.syncNow()).uploaded, 1);
    expect((await b.syncNow()).downloaded, 1);
    expect((await b.load('g1'))!.resultReason, 'edited');
  });

  group('both changed', () {
    setUp(() async {
      await a.save(game('g1'));
      await a.syncNow();
      await b.syncNow();
    });

    test('remote newer wins and the local copy is kept', () async {
      await a.save(game('g1', reason: 'older edit on PC'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await b.save(game('g1', reason: 'newer edit on phone'));
      await b.syncNow();

      final summary = await a.syncNow();

      expect(summary.conflicts, 1);
      expect(summary.uploaded, 0);
      expect((await a.load('g1'))!.resultReason, 'newer edit on phone');
      final copies = a.conflictFiles();
      expect(copies, hasLength(1));
      expect(copies.single, startsWith('g1.conflict-'));
      expect(File('${a.root.path}/conflicts/games/${copies.single}').readAsStringSync(), contains('older edit on PC'));
      expect((await a.run(() => DojoStore.instance.loadAll())).map((g) => g.id), ['g1'],
          reason: 'conflict copies are not listed as games');
    });

    test('local newer wins, is uploaded, and the remote copy is kept', () async {
      await b.save(game('g1', reason: 'older edit on phone'));
      await b.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await a.save(game('g1', reason: 'newer edit on PC'));

      final summary = await a.syncNow();

      expect(summary.conflicts, 1);
      expect(summary.uploaded, 1);
      expect(github.text('games/g1.json'), contains('newer edit on PC'));
      expect(File('${a.root.path}/conflicts/games/${a.conflictFiles().single}').readAsStringSync(),
          contains('older edit on phone'));
      // The phone then takes the winner without another conflict.
      final phone = await b.syncNow();
      expect(phone.conflicts, 0);
      expect((await b.load('g1'))!.resultReason, 'newer edit on PC');
    });
  });

  group('deletions', () {
    setUp(() async {
      await a.save(game('g1'));
      await a.save(game('g2'));
      await a.syncNow();
      await b.syncNow();
    });

    test('a local delete removes the remote file and then the other device copy', () async {
      await a.run(() => DojoStore.instance.delete('g1'));

      final summary = await a.syncNow();
      expect(summary.deletedRemote, 1);
      expect(github.files.keys, isNot(contains('games/g1.json')));
      expect(github.files.keys, contains('games/g2.json'));

      final phone = await b.syncNow();
      expect(phone.deletedLocal, 1);
      expect(b.file('games/g1.json').existsSync(), isFalse);
      expect(b.file('games/g2.json').existsSync(), isTrue);

      // Nothing comes back on later syncs.
      expect((await a.syncNow()).downloaded, 0);
      expect(a.file('games/g1.json').existsSync(), isFalse);
    });

    test('a file that vanished without a recorded delete is restored, not deleted remotely', () async {
      a.file('games/g1.json').deleteSync();

      final summary = await a.syncNow();

      expect(summary.deletedRemote, 0);
      expect(summary.downloaded, 1);
      expect(a.file('games/g1.json').existsSync(), isTrue);
      expect(github.files.keys, contains('games/g1.json'));
    });

    test('a delete loses to a newer remote edit', () async {
      await a.run(() => DojoStore.instance.delete('g1'));
      await b.save(game('g1', reason: 'kept playing on phone'));
      await b.syncNow();

      final summary = await a.syncNow();

      expect(summary.deletedRemote, 0);
      expect((await a.load('g1'))!.resultReason, 'kept playing on phone');
    });
  });

  test('a ref race leaves the manifest unchanged so the next sync retries', () async {
    await a.save(game('g1'));
    await a.syncNow();
    await a.save(game('g1', reason: 'edit'));
    // Another device pushes between our listing and our ref update.
    github.beforeRefUpdate = () => github.put('unrelated.txt', 'x');

    final failed = await a.syncNow();
    expect(failed.ok, isFalse);
    expect(failed.error, contains('Another device'));
    expect(github.text('games/g1.json'), isNot(contains('edit')));

    final retried = await a.syncNow();
    expect(retried.ok, isTrue, reason: retried.error);
    expect(retried.uploaded, 1);
    expect(github.text('games/g1.json'), contains('"resultReason": "edit"'));
  });

  test('refuses a public repository', () async {
    github.private = false;
    await a.save(game('g1'));
    final summary = await a.syncNow();
    expect(summary.ok, isFalse);
    expect(summary.error, contains('public'));
    expect(github.count('POST'), 0);
  });

  test('settings sync without secrets; newer remote settings apply', () async {
    final pc = Device('pc', github, includeSettings: true);
    roots.add(pc.root);
    await pc.connect();
    final settings = DojoSettings.instance;
    settings.loaded = true;
    await settings.setApiKey('sk-ant-secret');
    await settings.setModel('claude-haiku-5-5');

    expect((await pc.syncNow()).ok, isTrue);
    final uploaded = github.text('settings.json')!;
    expect(uploaded, isNot(contains('sk-ant-secret')));
    expect(uploaded, isNot(contains('test-token')));
    expect(jsonDecode(uploaded)['model'], 'claude-haiku-5-5');

    final remote = (jsonDecode(uploaded) as Map)
      ..['model'] = 'claude-opus-5-5'
      ..['updated'] = DateTime.now().toUtc().add(const Duration(minutes: 1)).toIso8601String();
    github.put('settings.json', jsonEncode(remote));

    final summary = await pc.syncNow();
    expect(summary.downloaded, 1);
    expect(settings.model, 'claude-opus-5-5');
    expect(settings.apiKey, 'sk-ant-secret');
    await settings.setApiKey('');
  });

  test('testConnection reports a missing repository', () async {
    final missing = DojoSync(client: MockClient((request) async {
      if (request.url.path == '/user') return http.Response(jsonEncode({'login': 'me'}), 200);
      return http.Response('{"message":"Not Found"}', 404);
    }), persistConfig: false);
    await missing.configure(owner: '', repo: 'chesster-data', token: 'test-token');
    final check = await missing.testConnection();
    expect(check.ok, isFalse);
    expect(check.repoMissing, isTrue);
    expect(missing.owner, 'me');
  });

  for (final configured in [false, true]) {
    testWidgets('sync page and settings tile fit a Pixel 8a (configured: $configured)', (tester) async {
      tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      DojoSync.instance = configured ? a.sync : DojoSync(persistConfig: false);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: DojoSyncTile())));
      expect(find.text('Sync with GitHub'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dojo-sync-tile')));
      await tester.pumpAndSettle();
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text(configured ? 'me/chesster-data' : 'Sync is off'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('New token'), 200, scrollable: find.byType(Scrollable).first);
      expect(tester.takeException(), isNull);
    });
  }
}
