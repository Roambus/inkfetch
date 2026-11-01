/// 解析 `Content-Range: bytes 0-1023/1048576` 响应头。
/// 返回 (起始字节, 结束字节, 总大小)，总大小为 `*` 或缺失时返回 null。
(int, int, int?)? parseContentRange(String value) {
  if (!value.startsWith('bytes ')) return null;
  final rest = value.substring(6);
  final slash = rest.indexOf('/');
  if (slash < 0) return null;
  final rangePart = rest.substring(0, slash);
  final totalPart = rest.substring(slash + 1);
  final dash = rangePart.indexOf('-');
  if (dash < 0) return null;
  final start = int.tryParse(rangePart.substring(0, dash).trim());
  final end = int.tryParse(rangePart.substring(dash + 1).trim());
  if (start == null || end == null) return null;
  final total = totalPart.trim() == '*' ? null : int.tryParse(totalPart.trim());
  return (start, end, total);
}

enum UrlKind { raw, release, archive, gist }

enum MirrorKind {
  official,
  codeload,
  prefix,
  rawHost,
  jsDelivr,
  statically,
  gitHack,
  domainReplace,
}

enum ProbeStatus { healthy, noRange, failed }

enum DownloadPhase {
  downloading,
  paused,
  verifying,
  completed,
  failed,
  cancelled,
}

class UrlParseException implements Exception {
  final String message;
  UrlParseException(this.message);
  @override
  String toString() => message;
}

class ParsedUrl {
  final String original;
  final String normalized;
  final UrlKind kind;
  final String? owner;
  final String? repo;
  final String? gitRef;
  final String? path;
  final String filename;
  final String? archiveFormat;
  final String? note;

  const ParsedUrl({
    required this.original,
    required this.normalized,
    required this.kind,
    this.owner,
    this.repo,
    this.gitRef,
    this.path,
    required this.filename,
    this.archiveFormat,
    this.note,
  });

  Map<String, dynamic> toJson() => {
    'original': original,
    'normalized': normalized,
    'kind': kind.name,
    'owner': owner,
    'repo': repo,
    'gitRef': gitRef,
    'path': path,
    'filename': filename,
    'archiveFormat': archiveFormat,
    'note': note,
  };

  factory ParsedUrl.fromJson(Map<String, dynamic> json) => ParsedUrl(
    original: json['original'] as String? ?? '',
    normalized: json['normalized'] as String? ?? '',
    kind: UrlKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => UrlKind.raw,
    ),
    owner: json['owner'] as String?,
    repo: json['repo'] as String?,
    gitRef: json['gitRef'] as String?,
    path: json['path'] as String?,
    filename: json['filename'] as String? ?? 'download.bin',
    archiveFormat: json['archiveFormat'] as String?,
    note: json['note'] as String?,
  );
}

class MirrorSpec {
  final String id;
  final String name;
  final MirrorKind kind;
  final String base;
  final Set<UrlKind> supports;
  final int maxConns;
  final int priority;
  final bool experimental;
  final String lane;

  const MirrorSpec({
    required this.id,
    required this.name,
    required this.kind,
    required this.base,
    required this.supports,
    required this.maxConns,
    required this.priority,
    required this.experimental,
    required this.lane,
  });
}

class SourceCandidate {
  final String id;
  final String name;
  final String url;
  final String lane;
  final int maxConns;
  final int priority;
  final bool experimental;

  const SourceCandidate({
    required this.id,
    required this.name,
    required this.url,
    required this.lane,
    required this.maxConns,
    required this.priority,
    required this.experimental,
  });
}

class SourceProbe {
  final String id;
  final String name;
  final String url;
  final String lane;
  ProbeStatus status;
  final int? httpStatus;
  bool supportsRange;
  final int? totalSize;
  final String? contentType;
  final String? etag;
  final int latencyMs;
  final int speedBps;
  final String? firstHash;
  bool? identityOk;
  double score;
  final int maxConns;
  String? error;
  final bool experimental;

  SourceProbe({
    required this.id,
    required this.name,
    required this.url,
    required this.lane,
    required this.status,
    this.httpStatus,
    required this.supportsRange,
    this.totalSize,
    this.contentType,
    this.etag,
    required this.latencyMs,
    required this.speedBps,
    this.firstHash,
    this.identityOk,
    required this.score,
    required this.maxConns,
    this.error,
    required this.experimental,
  });

  bool get usable => status != ProbeStatus.failed && (identityOk ?? true);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'lane': lane,
    'status': status.name,
    'httpStatus': httpStatus,
    'supportsRange': supportsRange,
    'totalSize': totalSize,
    'contentType': contentType,
    'etag': etag,
    'latencyMs': latencyMs,
    'speedBps': speedBps,
    'firstHash': firstHash,
    'identityOk': identityOk,
    'score': score,
    'maxConns': maxConns,
    'error': error,
    'experimental': experimental,
  };

  factory SourceProbe.fromJson(Map<String, dynamic> json) => SourceProbe(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    lane: json['lane'] as String? ?? '',
    status: ProbeStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => ProbeStatus.failed,
    ),
    httpStatus: json['httpStatus'] as int?,
    supportsRange: json['supportsRange'] as bool? ?? false,
    totalSize: json['totalSize'] as int?,
    contentType: json['contentType'] as String?,
    etag: json['etag'] as String?,
    latencyMs: json['latencyMs'] as int? ?? 0,
    speedBps: json['speedBps'] as int? ?? 0,
    firstHash: json['firstHash'] as String?,
    identityOk: json['identityOk'] as bool?,
    score: (json['score'] as num?)?.toDouble() ?? 0.0,
    maxConns: json['maxConns'] as int? ?? 4,
    error: json['error'] as String?,
    experimental: json['experimental'] as bool? ?? false,
  );
}

class SiteAllocation {
  final String id;
  final String name;
  final String url;
  final String lane;
  final int connections;
  final double score;
  final int speedBps;
  final int maxConns;

  const SiteAllocation({
    required this.id,
    required this.name,
    required this.url,
    required this.lane,
    required this.connections,
    required this.score,
    required this.speedBps,
    required this.maxConns,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'lane': lane,
    'connections': connections,
    'score': score,
    'speedBps': speedBps,
    'maxConns': maxConns,
  };

  factory SiteAllocation.fromJson(Map<String, dynamic> json) => SiteAllocation(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    lane: json['lane'] as String? ?? '',
    connections: json['connections'] as int? ?? 1,
    score: (json['score'] as num?)?.toDouble() ?? 0.0,
    speedBps: json['speedBps'] as int? ?? 0,
    maxConns: json['maxConns'] as int? ?? 4,
  );
}

class ThreadPlan {
  final int totalConnections;
  final int chunkSize;
  final int chunkCount;
  final List<SiteAllocation> sites;
  final bool singleStream;
  final String reason;

  const ThreadPlan({
    required this.totalConnections,
    required this.chunkSize,
    required this.chunkCount,
    required this.sites,
    required this.singleStream,
    required this.reason,
  });

  Map<String, dynamic> toJson() => {
    'totalConnections': totalConnections,
    'chunkSize': chunkSize,
    'chunkCount': chunkCount,
    'sites': sites.map((s) => s.toJson()).toList(),
    'singleStream': singleStream,
    'reason': reason,
  };

  factory ThreadPlan.fromJson(Map<String, dynamic> json) => ThreadPlan(
    totalConnections: json['totalConnections'] as int? ?? 0,
    chunkSize: json['chunkSize'] as int? ?? 0,
    chunkCount: json['chunkCount'] as int? ?? 0,
    sites: (json['sites'] as List<dynamic>? ?? [])
        .map((e) => SiteAllocation.fromJson(e as Map<String, dynamic>))
        .toList(),
    singleStream: json['singleStream'] as bool? ?? false,
    reason: json['reason'] as String? ?? '',
  );
}

class ProbeReport {
  final ParsedUrl parsed;
  final List<SourceProbe> sources;
  final int testedCount;
  final int usableCount;
  final int rangeCount;
  final int? totalSize;
  final String? baselineHash;
  final ThreadPlan plan;
  final String? expectedSha256;
  final int probedMs;

  const ProbeReport({
    required this.parsed,
    required this.sources,
    required this.testedCount,
    required this.usableCount,
    required this.rangeCount,
    required this.totalSize,
    required this.baselineHash,
    required this.plan,
    required this.expectedSha256,
    required this.probedMs,
  });

  Map<String, dynamic> toJson() => {
    'parsed': parsed.toJson(),
    'sources': sources.map((s) => s.toJson()).toList(),
    'testedCount': testedCount,
    'usableCount': usableCount,
    'rangeCount': rangeCount,
    'totalSize': totalSize,
    'baselineHash': baselineHash,
    'plan': plan.toJson(),
    'expectedSha256': expectedSha256,
    'probedMs': probedMs,
  };

  factory ProbeReport.fromJson(Map<String, dynamic> json) => ProbeReport(
    parsed: ParsedUrl.fromJson(json['parsed'] as Map<String, dynamic>),
    sources: (json['sources'] as List<dynamic>? ?? [])
        .map((e) => SourceProbe.fromJson(e as Map<String, dynamic>))
        .toList(),
    testedCount: json['testedCount'] as int? ?? 0,
    usableCount: json['usableCount'] as int? ?? 0,
    rangeCount: json['rangeCount'] as int? ?? 0,
    totalSize: json['totalSize'] as int?,
    baselineHash: json['baselineHash'] as String?,
    plan: ThreadPlan.fromJson(json['plan'] as Map<String, dynamic>? ?? {}),
    expectedSha256: json['expectedSha256'] as String?,
    probedMs: json['probedMs'] as int? ?? 0,
  );
}

class SiteProgress {
  final String id;
  final String name;
  final String lane;
  final int connections;
  int speedBps;
  int bytes;
  int errors;
  bool disabled;

  SiteProgress({
    required this.id,
    required this.name,
    required this.lane,
    required this.connections,
    this.speedBps = 0,
    this.bytes = 0,
    this.errors = 0,
    this.disabled = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'lane': lane,
    'connections': connections,
    'speedBps': speedBps,
    'bytes': bytes,
    'errors': errors,
    'disabled': disabled,
  };
}

class DownloadSnapshot {
  final String taskId;
  final DownloadPhase phase;
  final String filename;
  final String destPath;
  final int downloaded;
  final int total;
  final int speedBps;
  final int? etaSecs;
  final int elapsedMs;
  final List<SiteProgress> sites;
  final List<int> chunkMap;
  final int chunkSize;
  final String? sha256;
  final String? error;
  final String? savedUri;
  final double progress;

  /// 是否已与 GitHub 官方 digest 比对通过（仅 Release 资产可能为 true）。
  final bool shaVerified;

  const DownloadSnapshot({
    required this.taskId,
    required this.phase,
    required this.filename,
    required this.destPath,
    required this.downloaded,
    required this.total,
    required this.speedBps,
    required this.etaSecs,
    required this.elapsedMs,
    required this.sites,
    required this.chunkMap,
    required this.chunkSize,
    required this.sha256,
    required this.error,
    required this.savedUri,
    required this.progress,
    this.shaVerified = false,
  });

  DownloadSnapshot copyWith({
    DownloadPhase? phase,
    String? destPath,
    int? downloaded,
    int? total,
    int? speedBps,
    int? etaSecs,
    int? elapsedMs,
    List<SiteProgress>? sites,
    List<int>? chunkMap,
    int? chunkSize,
    String? sha256,
    String? error,
    String? savedUri,
    double? progress,
    bool? shaVerified,
  }) {
    return DownloadSnapshot(
      taskId: taskId,
      phase: phase ?? this.phase,
      filename: filename,
      destPath: destPath ?? this.destPath,
      downloaded: downloaded ?? this.downloaded,
      total: total ?? this.total,
      speedBps: speedBps ?? this.speedBps,
      etaSecs: etaSecs ?? this.etaSecs,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      sites: sites ?? this.sites,
      chunkMap: chunkMap ?? this.chunkMap,
      chunkSize: chunkSize ?? this.chunkSize,
      sha256: sha256 ?? this.sha256,
      error: error ?? this.error,
      savedUri: savedUri ?? this.savedUri,
      progress: progress ?? this.progress,
      shaVerified: shaVerified ?? this.shaVerified,
    );
  }
}

/// 磁盘上存在 `.octopart` 状态文件的未完成任务，应用重启后可继续下载。
class IncompleteTask {
  final String url;
  final String destPath;
  final String filename;
  final int total;
  final int downloaded;
  final int chunkCount;
  final int completedChunks;

  const IncompleteTask({
    required this.url,
    required this.destPath,
    required this.filename,
    required this.total,
    required this.downloaded,
    required this.chunkCount,
    required this.completedChunks,
  });

  double get progress =>
      total > 0 ? (downloaded / total).clamp(0.0, 1.0).toDouble() : 0.0;
}

class HistoryEntry {
  final String taskId;
  final String filename;
  final String url;
  final String destPath;
  final String? savedUri;
  final String? folderUri;
  final int total;
  final int downloaded;
  final int speedBps;
  final String? sha256;
  final String status;
  final DateTime createdAt;
  final DateTime? finishedAt;
  final String? error;

  const HistoryEntry({
    required this.taskId,
    required this.filename,
    required this.url,
    required this.destPath,
    this.savedUri,
    this.folderUri,
    required this.total,
    required this.downloaded,
    required this.speedBps,
    this.sha256,
    required this.status,
    required this.createdAt,
    this.finishedAt,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'filename': filename,
    'url': url,
    'destPath': destPath,
    'savedUri': savedUri,
    'folderUri': folderUri,
    'total': total,
    'downloaded': downloaded,
    'speedBps': speedBps,
    'sha256': sha256,
    'status': status,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'error': error,
  };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
    taskId: json['taskId'] as String? ?? '',
    filename: json['filename'] as String? ?? '',
    url: json['url'] as String? ?? '',
    destPath: json['destPath'] as String? ?? '',
    savedUri: json['savedUri'] as String?,
    folderUri: json['folderUri'] as String?,
    total: json['total'] as int? ?? 0,
    downloaded: json['downloaded'] as int? ?? 0,
    speedBps: json['speedBps'] as int? ?? 0,
    sha256: json['sha256'] as String?,
    status: json['status'] as String? ?? 'completed',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    finishedAt: json['finishedAt'] == null
        ? null
        : DateTime.tryParse(json['finishedAt'] as String),
    error: json['error'] as String?,
  );
}

class AppSettings {
  int maxConnections;
  String theme;
  String? downloadDir;
  String? androidTreeUri;
  String? androidTreeName;
  List<String> disabledMirrors;
  bool deepProbeAll;
  bool verifySha;
  bool autoSaveToSelectedFolder;

  AppSettings({
    this.maxConnections = 32,
    this.theme = 'system',
    this.downloadDir,
    this.androidTreeUri,
    this.androidTreeName,
    this.disabledMirrors = const [],
    this.deepProbeAll = false,
    this.verifySha = true,
    this.autoSaveToSelectedFolder = true,
  });

  Map<String, dynamic> toJson() => {
    'maxConnections': maxConnections,
    'theme': theme,
    'downloadDir': downloadDir,
    'androidTreeUri': androidTreeUri,
    'androidTreeName': androidTreeName,
    'disabledMirrors': disabledMirrors,
    'deepProbeAll': deepProbeAll,
    'verifySha': verifySha,
    'autoSaveToSelectedFolder': autoSaveToSelectedFolder,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    maxConnections: json['maxConnections'] as int? ?? 32,
    theme: json['theme'] as String? ?? 'system',
    downloadDir: json['downloadDir'] as String?,
    androidTreeUri: json['androidTreeUri'] as String?,
    androidTreeName: json['androidTreeName'] as String?,
    disabledMirrors: (json['disabledMirrors'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList(),
    deepProbeAll: json['deepProbeAll'] as bool? ?? false,
    verifySha: json['verifySha'] as bool? ?? true,
    autoSaveToSelectedFolder: json['autoSaveToSelectedFolder'] as bool? ?? true,
  );
}
