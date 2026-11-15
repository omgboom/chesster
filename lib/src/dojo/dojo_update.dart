part of '../../main.dart';

// In-app updates from GitHub Releases. CI names every asset
// `chesster-<tag>-<build>-arm64.apk` / `chesster-<tag>-<build>-windows-x64.zip`
// and passes the same <build> to `flutter build --build-number`, so the build
// number in the asset name is compared with the running app's build number.

const dojoUpdateRepository = 'omgboom/chesster';
const dojoUpdateLatestReleaseUrl =
    'https://api.github.com/repos/$dojoUpdateRepository/releases/latest';
const dojoUpdateReleasesPage =
    'https://github.com/$dojoUpdateRepository/releases/latest';
const dojoUpdateUserAgent = 'Chesster-Updater';
const dojoUpdateCheckedAtKey = 'dojoUpdateCheckedAtV1';
const dojoUpdateCachedReleaseKey = 'dojoUpdateCachedReleaseV1';
const dojoUpdateCheckInterval = Duration(days: 1);

enum DojoUpdatePlatform {
  android('-arm64.apk'),
  windows('-windows-x64.zip');

  const DojoUpdatePlatform(this.assetSuffix);

  /// Suffix of this platform's release asset name.
  final String assetSuffix;

  /// The platform this app can update itself on, or null.
  static DojoUpdatePlatform? get current {
    if (Platform.isAndroid) return DojoUpdatePlatform.android;
    if (Platform.isWindows) return DojoUpdatePlatform.windows;
    return null;
  }
}

final _dojoAssetBuildPattern = RegExp(
  r'-(\d+)-(?:arm64\.apk|windows-x64\.zip)$',
);

/// Build number embedded in a CI asset name, e.g. 1006 for
/// `chesster-v0.1.0-1006-arm64.apk`.
int? dojoParseAssetBuildNumber(String assetName) {
  final match = _dojoAssetBuildPattern.firstMatch(assetName);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// One downloadable release asset for this platform.
class DojoReleaseInfo {
  const DojoReleaseInfo({
    required this.tag,
    required this.buildNumber,
    required this.assetName,
    required this.downloadUrl,
    required this.size,
    this.sha256,
    this.pageUrl,
  });

  final String tag;
  final int buildNumber;
  final String assetName;
  final String downloadUrl;
  final int size;

  /// Lower-case hex SHA-256 from the GitHub asset `digest`, when provided.
  final String? sha256;
  final String? pageUrl;

  String get versionLabel => tag.startsWith('v') ? tag : 'v$tag';

  Map<String, Object?> toJson() => {
    'tag': tag,
    'buildNumber': buildNumber,
    'assetName': assetName,
    'downloadUrl': downloadUrl,
    'size': size,
    'sha256': sha256,
    'pageUrl': pageUrl,
  };

  static DojoReleaseInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final build = json['buildNumber'];
    final url = json['downloadUrl'];
    final name = json['assetName'];
    if (build is! int || url is! String || name is! String) return null;
    return DojoReleaseInfo(
      tag: json['tag'] as String? ?? '',
      buildNumber: build,
      assetName: name,
      downloadUrl: url,
      size: json['size'] as int? ?? 0,
      sha256: json['sha256'] as String?,
      pageUrl: json['pageUrl'] as String?,
    );
  }
}

/// Picks this platform's asset from a GitHub `releases/latest` response.
/// Returns null when the release has no matching asset with a build number.
DojoReleaseInfo? dojoSelectReleaseAsset(
  Map<String, Object?> release,
  DojoUpdatePlatform platform,
) {
  if (release['draft'] == true || release['prerelease'] == true) return null;
  final assets = release['assets'];
  if (assets is! List) return null;
  DojoReleaseInfo? best;
  for (final asset in assets) {
    if (asset is! Map) continue;
    final name = asset['name'];
    final url = asset['browser_download_url'];
    if (name is! String || url is! String) continue;
    if (!name.endsWith(platform.assetSuffix)) continue;
    final build = dojoParseAssetBuildNumber(name);
    if (build == null) continue;
    if (best != null && best.buildNumber >= build) continue;
    final digest = asset['digest'];
    best = DojoReleaseInfo(
      tag: release['tag_name'] as String? ?? '',
      buildNumber: build,
      assetName: name,
      downloadUrl: url,
      size: (asset['size'] as num?)?.toInt() ?? 0,
      sha256: digest is String && digest.startsWith('sha256:')
          ? digest.substring(7).toLowerCase()
          : null,
      pageUrl: release['html_url'] as String?,
    );
  }
  return best;
}

/// True when [release] is strictly newer than the running build.
bool dojoIsNewerBuild(DojoReleaseInfo release, int? currentBuild) =>
    currentBuild != null && release.buildNumber > currentBuild;

enum DojoUpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installing,

  /// Android: the APK is downloaded and waits for the user (permission or
  /// installer dismissed).
  readyToInstall,
  error,
}

/// Checks GitHub for a newer build and installs it. One shared instance drives
/// both the home banner and the settings tile.
class DojoUpdater extends ChangeNotifier {
  DojoUpdater({
    this._client,
    Future<int?> Function()? currentBuild,
    DojoUpdatePlatform? platform,
    DateTime Function()? clock,
  }) : _currentBuild = currentBuild ?? _packageBuildNumber,
       _platform = platform ?? DojoUpdatePlatform.current,
       _clock = clock ?? DateTime.now;

  static DojoUpdater instance = DojoUpdater();

  final http.Client? _client;
  final Future<int?> Function() _currentBuild;
  final DojoUpdatePlatform? _platform;
  final DateTime Function() _clock;

  DojoUpdateStatus status = DojoUpdateStatus.idle;
  DojoReleaseInfo? release;
  int? runningBuild;

  /// Download progress in 0..1, or null when the size is unknown.
  double? progress;
  String? message;
  String? _downloadedPath;
  bool _autoChecked = false;

  bool get supported => _platform != null;
  bool get busy =>
      status == DojoUpdateStatus.checking ||
      status == DojoUpdateStatus.downloading ||
      status == DojoUpdateStatus.installing;

  /// True when there is a newer release the user can act on.
  bool get hasUpdate =>
      release != null &&
      const {
        DojoUpdateStatus.available,
        DojoUpdateStatus.downloading,
        DojoUpdateStatus.installing,
        DojoUpdateStatus.readyToInstall,
        DojoUpdateStatus.error,
      }.contains(status);

  static Future<int?> _packageBuildNumber() async =>
      int.tryParse((await PackageInfo.fromPlatform()).buildNumber);

  void _set(DojoUpdateStatus next, {String? message, double? progress}) {
    status = next;
    this.message = message;
    this.progress = progress;
    notifyListeners();
  }

  Future<T> _withClient<T>(Future<T> Function(http.Client client) body) async {
    final injected = _client;
    if (injected != null) return body(injected);
    final client = http.Client();
    try {
      return await body(client);
    } finally {
      client.close();
    }
  }

  /// Checks once per [dojoUpdateCheckInterval]; between checks the cached
  /// result is shown. Never runs under `flutter test`.
  Future<void> maybeAutoCheck() async {
    if (_autoChecked || !supported || _runningUnderFlutterTest) return;
    _autoChecked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(dojoUpdateCheckedAtKey);
      final now = _clock().millisecondsSinceEpoch;
      if (last != null &&
          now - last >= 0 &&
          now - last < dojoUpdateCheckInterval.inMilliseconds) {
        final cachedJson = prefs.getString(dojoUpdateCachedReleaseKey);
        final cached = cachedJson == null
            ? null
            : DojoReleaseInfo.fromJson(jsonDecode(cachedJson));
        runningBuild ??= await _currentBuild();
        if (cached != null &&
            dojoIsNewerBuild(cached, runningBuild) &&
            status == DojoUpdateStatus.idle) {
          release = cached;
          _set(DojoUpdateStatus.available);
        }
        return;
      }
      await check(quiet: true);
    } catch (_) {
      // Automatic checks are best effort; the settings tile shows errors.
    }
  }

  /// Queries the latest GitHub release. With [quiet], failures leave the
  /// banner hidden instead of showing an error.
  Future<void> check({bool quiet = false}) async {
    final platform = _platform;
    if (platform == null || busy) return;
    _set(DojoUpdateStatus.checking);
    try {
      runningBuild ??= await _currentBuild();
      final response = await _withClient(
        (client) => client
            .get(
              Uri.parse(dojoUpdateLatestReleaseUrl),
              headers: const {
                'User-Agent': dojoUpdateUserAgent,
                'Accept': 'application/vnd.github+json',
              },
            )
            .timeout(const Duration(seconds: 20)),
      );
      final prefs = await SharedPreferences.getInstance();
      if (response.statusCode == 404) {
        await prefs.setInt(
          dojoUpdateCheckedAtKey,
          _clock().millisecondsSinceEpoch,
        );
        await prefs.remove(dojoUpdateCachedReleaseKey);
        release = null;
        _set(DojoUpdateStatus.upToDate, message: 'No releases published yet');
        return;
      }
      if (response.statusCode != 200) {
        throw HttpException(
          response.statusCode == 403 || response.statusCode == 429
              ? 'GitHub rate limit reached, try again later'
              : 'GitHub answered ${response.statusCode}',
        );
      }
      final decoded = jsonDecode(response.body);
      final found = decoded is Map<String, Object?>
          ? dojoSelectReleaseAsset(decoded, platform)
          : null;
      await prefs.setInt(
        dojoUpdateCheckedAtKey,
        _clock().millisecondsSinceEpoch,
      );
      if (found != null && dojoIsNewerBuild(found, runningBuild)) {
        await prefs.setString(
          dojoUpdateCachedReleaseKey,
          jsonEncode(found.toJson()),
        );
        release = found;
        _downloadedPath = null;
        _set(DojoUpdateStatus.available);
      } else {
        await prefs.remove(dojoUpdateCachedReleaseKey);
        release = null;
        _set(
          DojoUpdateStatus.upToDate,
          message: found == null
              ? 'The latest release has no ${platform.name} download'
              : null,
        );
      }
    } catch (error) {
      release = null;
      if (quiet) {
        _set(DojoUpdateStatus.idle);
      } else {
        _set(DojoUpdateStatus.error, message: _describe(error));
      }
    }
  }

  /// Downloads the release asset and installs it.
  Future<void> install() async {
    final target = release;
    final platform = _platform;
    if (target == null || platform == null || busy) return;
    try {
      var path = _downloadedPath;
      if (path == null || !File(path).existsSync()) {
        path = await _download(target, platform);
        _downloadedPath = path;
      }
      _set(DojoUpdateStatus.installing);
      switch (platform) {
        case DojoUpdatePlatform.android:
          await _installAndroid(path);
        case DojoUpdatePlatform.windows:
          await _installWindows(path);
      }
    } catch (error) {
      _set(DojoUpdateStatus.error, message: _describe(error));
    }
  }

  Future<String> _download(
    DojoReleaseInfo target,
    DojoUpdatePlatform platform,
  ) async {
    _set(DojoUpdateStatus.downloading, progress: 0);
    final Directory folder;
    if (platform == DojoUpdatePlatform.android) {
      // Matches <cache-path name="updates" path="updates/"/> in file_paths.xml.
      folder = Directory(
        '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates',
      );
    } else {
      folder = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}chesster-update',
      );
    }
    if (folder.existsSync()) {
      // Old downloads are not needed any more.
      for (final entry in folder.listSync()) {
        try {
          entry.deleteSync(recursive: true);
        } catch (_) {}
      }
    } else {
      folder.createSync(recursive: true);
    }
    final file = File(
      '${folder.path}${Platform.pathSeparator}${target.assetName}',
    );
    final partial = File('${file.path}.part');
    await _withClient((client) async {
      final request = http.Request('GET', Uri.parse(target.downloadUrl))
        ..headers['User-Agent'] = dojoUpdateUserAgent
        ..headers['Accept'] = 'application/octet-stream';
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw HttpException('Download failed (${response.statusCode})');
      }
      final total =
          response.contentLength ?? (target.size > 0 ? target.size : null);
      final digestSink = _DigestSink();
      final hasher = crypto.sha256.startChunkedConversion(digestSink);
      final sink = partial.openWrite();
      var received = 0;
      var lastNotified = -1.0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 60),
        )) {
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) {
            final value = (received / total).clamp(0.0, 1.0);
            if (value - lastNotified >= 0.01) {
              lastNotified = value;
              _set(DojoUpdateStatus.downloading, progress: value);
            }
          }
        }
      } finally {
        await sink.close();
        hasher.close();
      }
      if (target.size > 0 && received != target.size) {
        throw HttpException(
          'Download incomplete ($received of ${target.size} bytes)',
        );
      }
      final expected = target.sha256;
      if (expected != null && digestSink.value.toString() != expected) {
        throw const HttpException('Downloaded file failed its checksum');
      }
    });
    if (file.existsSync()) file.deleteSync();
    partial.renameSync(file.path);
    return file.path;
  }

  Future<void> _installAndroid(String apkPath) async {
    final outcome = await maiaEngineChannel.invokeMethod<String>('installApk', {
      'path': apkPath,
    });
    if (outcome == 'permission_required') {
      _set(
        DojoUpdateStatus.readyToInstall,
        message:
            'Allow "Install unknown apps" for Chesster in the settings screen '
            'that just opened, then come back and tap Install.',
      );
    } else {
      _set(
        DojoUpdateStatus.readyToInstall,
        message:
            'Follow the Android installer. Your games are kept. '
            'Tap Install again if you closed it.',
      );
    }
  }

  Future<void> _installWindows(String zipPath) async {
    final sep = Platform.pathSeparator;
    final exe = File(Platform.resolvedExecutable);
    final installDir = exe.parent.path;
    final probe = File('$installDir$sep.chesster-update-probe');
    try {
      probe.writeAsStringSync('ok');
      probe.deleteSync();
    } catch (_) {
      throw HttpException(
        'Chesster cannot write to $installDir. The update was downloaded to '
        '$zipPath; unzip it over the install folder yourself.',
      );
    }

    final extractDir = Directory('${File(zipPath).parent.path}${sep}extracted');
    if (extractDir.existsSync()) extractDir.deleteSync(recursive: true);
    extractDir.createSync(recursive: true);
    final windir = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    var extracted = await Process.run('$windir${sep}System32${sep}tar.exe', [
      '-xf',
      zipPath,
      '-C',
      extractDir.path,
    ]).then((r) => r.exitCode == 0).catchError((_) => false);
    if (!extracted) {
      final ps = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Expand-Archive -LiteralPath ${_psQuote(zipPath)} '
            '-DestinationPath ${_psQuote(extractDir.path)} -Force',
      ]);
      extracted = ps.exitCode == 0;
    }
    if (!extracted) {
      throw HttpException('Could not unzip the update ($zipPath)');
    }
    final exeName = exe.uri.pathSegments.last;
    String? source;
    for (final candidate in [
      '${extractDir.path}${sep}Chesster',
      extractDir.path,
    ]) {
      if (File('$candidate$sep$exeName').existsSync() ||
          File('$candidate${sep}chesster.exe').existsSync()) {
        source = candidate;
        break;
      }
    }
    if (source == null) {
      throw HttpException('The update zip has no chesster.exe ($zipPath)');
    }

    final log = '${File(zipPath).parent.path}${sep}update.log';
    final script = File('${File(zipPath).parent.path}${sep}apply-update.ps1');
    final target = '$installDir$sep$exeName';
    // Waits for this process, stops engines started from the install folder,
    // copies the new files over it (user data lives in %APPDATA%) and starts
    // the new build. The BOM keeps non-ASCII paths intact in PowerShell 5.1.
    script.writeAsStringSync(
      '\uFEFF'
      "\$ErrorActionPreference = 'Continue'\r\n"
      "\$log = ${_psQuote(log)}\r\n"
      "\"Waiting for Chesster (pid $pid) to exit\" | Out-File -LiteralPath \$log -Encoding utf8\r\n"
      'Wait-Process -Id $pid -Timeout 60 -ErrorAction SilentlyContinue\r\n'
      'Get-Process -Name stockfish -ErrorAction SilentlyContinue | '
      'Where-Object { \$_.Path -and \$_.Path.StartsWith(${_psQuote(installDir)}, '
      "[System.StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue\r\n"
      'Start-Sleep -Milliseconds 700\r\n'
      '& robocopy ${_psQuote(source)} ${_psQuote(installDir)} /E /R:10 /W:1 /NP /NDL '
      "| Out-File -LiteralPath \$log -Append -Encoding utf8\r\n"
      "\$code = \$LASTEXITCODE\r\n"
      "\"robocopy exit code \$code\" | Out-File -LiteralPath \$log -Append -Encoding utf8\r\n"
      'Start-Process -FilePath ${_psQuote(target)} -WorkingDirectory ${_psQuote(installDir)}\r\n'
      "if (\$code -lt 8) { Remove-Item -LiteralPath ${_psQuote(extractDir.path)} -Recurse -Force -ErrorAction SilentlyContinue }\r\n",
    );

    // Release stockfish.exe so it can be overwritten.
    try {
      await DojoEngine.instance.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
    ], mode: ProcessStartMode.detached);
    exit(0);
  }

  static String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

  static String _describe(Object error) {
    if (error is HttpException) return error.message;
    if (error is PlatformException) return error.message ?? error.code;
    if (error is TimeoutException) return 'GitHub did not answer in time';
    if (error is SocketException) return 'No connection to GitHub';
    return error.toString();
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

String _dojoUpdateHeadline(DojoReleaseInfo release) =>
    'Update available: ${release.versionLabel} (build ${release.buildNumber})';

/// Home-screen banner. Renders nothing unless a newer build is available.
class DojoUpdateBanner extends StatefulWidget {
  const DojoUpdateBanner({super.key, this.updater});

  /// Defaults to [DojoUpdater.instance].
  final DojoUpdater? updater;

  @override
  State<DojoUpdateBanner> createState() => _DojoUpdateBannerState();
}

class _DojoUpdateBannerState extends State<DojoUpdateBanner> {
  DojoUpdater get _updater => widget.updater ?? DojoUpdater.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_updater.maybeAutoCheck());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _updater,
      builder: (context, _) {
        final updater = _updater;
        final release = updater.release;
        if (release == null || !updater.hasUpdate) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final downloading = updater.status == DojoUpdateStatus.downloading;
        final installing = updater.status == DojoUpdateStatus.installing;
        final ready = updater.status == DojoUpdateStatus.readyToInstall;
        final error = updater.status == DojoUpdateStatus.error;
        return Card(
          key: const ValueKey('dojo-update-banner'),
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.system_update_outlined,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _dojoUpdateHeadline(release),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: updater.busy ? null : updater.install,
                      child: Text(
                        error ? 'Retry' : (ready ? 'Install' : 'Update'),
                      ),
                    ),
                  ],
                ),
                if (downloading || installing) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: installing ? null : updater.progress,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    installing
                        ? 'Installing…'
                        : 'Downloading… ${((updater.progress ?? 0) * 100).round()}%',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (updater.message != null && !downloading) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    updater.message!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: error
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// "Check for updates" row for the settings page.
class DojoUpdateTile extends StatefulWidget {
  const DojoUpdateTile({super.key, this.updater});

  /// Defaults to [DojoUpdater.instance].
  final DojoUpdater? updater;

  @override
  State<DojoUpdateTile> createState() => _DojoUpdateTileState();
}

class _DojoUpdateTileState extends State<DojoUpdateTile> {
  DojoUpdater get _updater => widget.updater ?? DojoUpdater.instance;
  String? _version;

  @override
  void initState() {
    super.initState();
    if (!_runningUnderFlutterTest) {
      PackageInfo.fromPlatform()
          .then((info) {
            if (mounted) {
              setState(
                () => _version = 'v${info.version} (build ${info.buildNumber})',
              );
            }
          })
          .catchError((Object _) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _updater,
      builder: (context, _) {
        final updater = _updater;
        final installed = _version == null
            ? 'Installed version unknown'
            : 'Installed: $_version';
        if (!updater.supported) {
          return ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('Updates'),
            subtitle: Text(
              '$installed\nIn-app updates work on Android and Windows. '
              'New builds are at $dojoUpdateReleasesPage',
            ),
          );
        }
        final release = updater.release;
        final String status;
        switch (updater.status) {
          case DojoUpdateStatus.checking:
            status = 'Checking…';
          case DojoUpdateStatus.upToDate:
            status = updater.message ?? 'You have the latest version';
          case DojoUpdateStatus.available:
          case DojoUpdateStatus.readyToInstall:
            status = release == null ? '' : _dojoUpdateHeadline(release);
          case DojoUpdateStatus.downloading:
            status = 'Downloading… ${((updater.progress ?? 0) * 100).round()}%';
          case DojoUpdateStatus.installing:
            status = 'Installing…';
          case DojoUpdateStatus.error:
            status = updater.message ?? 'Update failed';
          case DojoUpdateStatus.idle:
            status = 'Checks GitHub once a day';
        }
        return ListTile(
          key: const ValueKey('dojo-update-tile'),
          leading: const Icon(Icons.system_update_outlined),
          title: const Text('Check for updates'),
          subtitle: Text('$installed\n$status'),
          isThreeLine: true,
          enabled: !updater.busy,
          onTap: updater.busy ? null : () => unawaited(updater.check()),
          trailing: updater.busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : updater.hasUpdate
              ? FilledButton(
                  onPressed: updater.install,
                  child: Text(
                    updater.status == DojoUpdateStatus.readyToInstall
                        ? 'Install'
                        : 'Update',
                  ),
                )
              : null,
        );
      },
    );
  }
}
