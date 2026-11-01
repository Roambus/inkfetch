import 'models.dart';

const _githubHosts = {
  'github.com',
  'www.github.com',
  'raw.githubusercontent.com',
  'codeload.github.com',
  'gist.githubusercontent.com',
  'gist.github.com',
};

String _cleanInput(String input) {
  var trimmed = input.trim();
  for (final quote in ['"', "'", '<', '>']) {
    trimmed = trimmed.replaceAll(quote, '');
  }
  trimmed = trimmed.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (trimmed.startsWith('github.com/') ||
      trimmed.startsWith('raw.githubusercontent.com/') ||
      trimmed.startsWith('gist.githubusercontent.com/') ||
      trimmed.startsWith('codeload.github.com/')) {
    return 'https://$trimmed';
  }
  return trimmed;
}

/// Windows 与跨平台文件系统都不接受这些字符，统一替换为下划线。
final RegExp _illegalFilenameChars = RegExp(r'[<>:"|?*\x00-\x1F]');
final RegExp _reservedWindowsName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
  caseSensitive: false,
);

String _sanitizeFilename(String value, String fallback) {
  var decoded = value;
  try {
    decoded = Uri.decodeComponent(value);
  } catch (_) {}
  var base = decoded.split('/').last.split('\\').last.replaceAll('\u0000', '');
  base = base.replaceAll(_illegalFilenameChars, '_').trim();
  // Windows 不允许文件名以空格或点结尾。
  base = base.replaceAll(RegExp(r'[\s.]+$'), '');
  if (base.isEmpty || base == '.' || base == '..') return fallback;
  final dot = base.lastIndexOf('.');
  final stem = dot > 0 ? base.substring(0, dot) : base;
  if (_reservedWindowsName.hasMatch(stem)) base = '_$base';
  if (base.runes.length > 180) {
    final shortened = String.fromCharCodes(base.runes.take(180));
    return shortened;
  }
  return base;
}

String _repoName(String repo) =>
    repo.endsWith('.git') ? repo.substring(0, repo.length - 4) : repo;

List<String> _segments(Uri uri) =>
    uri.pathSegments.where((s) => s.isNotEmpty).toList();

String _encodedPath(Uri uri) => uri.path;

String _encodePath(String path) => path
    .split('/')
    .map((s) => s.isEmpty ? s : Uri.encodeComponent(Uri.decodeComponent(s)))
    .join('/');

ParsedUrl parseGitHubUrl(String input) {
  final cleaned = _cleanInput(input);
  if (cleaned.isEmpty) {
    throw UrlParseException('请先输入 GitHub 文件链接');
  }
  final uri = Uri.tryParse(cleaned);
  if (uri == null || uri.host.isEmpty) {
    throw UrlParseException('链接格式不正确，请粘贴完整的 GitHub 链接');
  }
  final host = uri.host.toLowerCase();
  if (!_githubHosts.contains(host)) {
    throw UrlParseException(
      '暂不支持该域名：$host。请使用 github.com / raw.githubusercontent.com 链接',
    );
  }
  final segments = _segments(uri);
  if (host == 'github.com' || host == 'www.github.com') {
    return _parseGitHubWeb(uri, segments);
  }
  if (host == 'raw.githubusercontent.com') {
    return _parseRaw(uri, segments);
  }
  if (host == 'codeload.github.com') {
    return _parseCodeload(uri, segments);
  }
  return _parseGist(uri, segments, host);
}

(String, String) _requireOwnerRepo(List<String> segments) {
  if (segments.length < 2) {
    throw UrlParseException('链接缺少 owner / repo 路径');
  }
  final owner = segments[0];
  final repo = _repoName(segments[1]);
  if (owner.isEmpty || repo.isEmpty) {
    throw UrlParseException('owner / repo 不能为空');
  }
  return (owner, repo);
}

ParsedUrl _parseGitHubWeb(Uri uri, List<String> segments) {
  final (owner, repo) = _requireOwnerRepo(segments);
  final repoUrl = 'https://github.com/$owner/$repo';
  final action = segments.length > 2 ? segments[2] : '';
  final encodedParts = _encodedPath(uri).split('/');

  switch (action) {
    case 'blob':
    case 'raw':
      if (segments.length < 5) {
        throw UrlParseException('文件链接缺少分支或文件路径');
      }
      final gitRef = segments[3];
      final path = segments.sublist(4).join('/');
      final encodedTail = encodedParts.length >= 6
          ? encodedParts.sublist(5).join('/')
          : _encodePath(path);
      return ParsedUrl(
        original: uri.toString(),
        normalized:
            'https://raw.githubusercontent.com/$owner/$repo/${_encodePath(gitRef)}/$encodedTail',
        kind: UrlKind.raw,
        owner: owner,
        repo: repo,
        gitRef: gitRef,
        path: path,
        filename: _sanitizeFilename(segments.last, 'download.bin'),
        note: '已将网页文件链接转换为 raw 直链',
      );
    case 'releases':
      if (segments.length >= 4 &&
          segments[3] == 'download' &&
          segments.length >= 6) {
        final gitRef = segments[4];
        final asset = segments.sublist(5).join('/');
        return ParsedUrl(
          original: uri.toString(),
          normalized:
              'https://github.com/$owner/$repo/releases/download/$gitRef/$asset',
          kind: UrlKind.release,
          owner: owner,
          repo: repo,
          gitRef: gitRef,
          path: asset,
          filename: _sanitizeFilename(segments.last, 'release-asset.bin'),
          note: 'Release 资产：官方源与镜像并行下载',
        );
      }
      final archive = '$repoUrl/archive/HEAD.zip';
      return ParsedUrl(
        original: uri.toString(),
        normalized: archive,
        kind: UrlKind.archive,
        owner: owner,
        repo: repo,
        gitRef: 'HEAD',
        filename: '$repo-HEAD.zip',
        archiveFormat: 'zip',
        note: 'Release 页面链接已转为仓库 HEAD 压缩包',
      );
    case 'archive':
      if (segments.length < 4) {
        throw UrlParseException('压缩包链接缺少分支或标签');
      }
      final String format;
      if (uri.path.endsWith('.tar.gz')) {
        format = 'tar.gz';
      } else if (uri.path.endsWith('.zip')) {
        format = 'zip';
      } else {
        throw UrlParseException('仅支持 .zip 或 .tar.gz 仓库压缩包');
      }
      var refPart = uri.path;
      final prefix = '/$owner/$repo/archive/';
      if (refPart.startsWith(prefix)) {
        refPart = refPart.substring(prefix.length);
      } else {
        refPart = segments.sublist(3).join('/');
      }
      if (refPart.endsWith('.$format')) {
        refPart = refPart.substring(0, refPart.length - format.length - 1);
      }
      if (refPart.isEmpty) {
        throw UrlParseException('压缩包链接缺少分支或标签');
      }
      final refTail = refPart.split('/').last;
      return ParsedUrl(
        original: uri.toString(),
        normalized: 'https://github.com/$owner/$repo/archive/$refPart.$format',
        kind: UrlKind.archive,
        owner: owner,
        repo: repo,
        gitRef: refPart,
        filename: '$repo-$refTail.$format',
        archiveFormat: format,
        note: '仓库归档将使用 codeload 与镜像并行下载',
      );
    case 'tree':
      final gitRef = segments.length > 3 ? segments[3] : 'HEAD';
      final archive = '$repoUrl/archive/$gitRef.zip';
      return ParsedUrl(
        original: uri.toString(),
        normalized: archive,
        kind: UrlKind.archive,
        owner: owner,
        repo: repo,
        gitRef: gitRef,
        path: segments.length > 4 ? segments.sublist(4).join('/') : '',
        filename: '$repo-${_sanitizeFilename(gitRef, 'HEAD')}.zip',
        archiveFormat: 'zip',
        note: '目录链接已自动转为仓库 ZIP 压缩包',
      );
    default:
      final archive = '$repoUrl/archive/HEAD.zip';
      return ParsedUrl(
        original: uri.toString(),
        normalized: archive,
        kind: UrlKind.archive,
        owner: owner,
        repo: repo,
        gitRef: 'HEAD',
        filename: '$repo-HEAD.zip',
        archiveFormat: 'zip',
        note: '仓库链接已自动转为 HEAD ZIP 压缩包',
      );
  }
}

ParsedUrl _parseRaw(Uri uri, List<String> segments) {
  final (owner, repo) = _requireOwnerRepo(segments);
  if (segments.length < 4) {
    throw UrlParseException('raw 链接缺少分支或文件路径');
  }
  final gitRef = segments[2];
  final path = segments.sublist(3).join('/');
  final encodedParts = _encodedPath(uri).split('/');
  final encodedTail = encodedParts.length >= 5
      ? encodedParts.sublist(4).join('/')
      : _encodePath(path);
  return ParsedUrl(
    original: uri.toString(),
    normalized:
        'https://raw.githubusercontent.com/$owner/$repo/${_encodePath(gitRef)}/$encodedTail',
    kind: UrlKind.raw,
    owner: owner,
    repo: repo,
    gitRef: gitRef,
    path: path,
    filename: _sanitizeFilename(segments.last, 'download.bin'),
  );
}

ParsedUrl _parseCodeload(Uri uri, List<String> segments) {
  final (owner, repo) = _requireOwnerRepo(segments);
  if (segments.length < 4) {
    throw UrlParseException('codeload 链接缺少格式或分支');
  }
  final format = segments[2];
  if (format != 'zip' && format != 'tar.gz') {
    throw UrlParseException('codeload 仅支持 zip / tar.gz');
  }
  final refPart = segments.sublist(3).join('/');
  final archive = 'https://github.com/$owner/$repo/archive/$refPart.$format';
  final refTail = refPart.split('/').last;
  return ParsedUrl(
    original: uri.toString(),
    normalized: archive,
    kind: UrlKind.archive,
    owner: owner,
    repo: repo,
    gitRef: refPart,
    filename: '$repo-$refTail.$format',
    archiveFormat: format,
    note: 'codeload 链接已规范化',
  );
}

ParsedUrl _parseGist(Uri uri, List<String> segments, String host) {
  if (host == 'gist.github.com') {
    if (segments.length < 2) {
      throw UrlParseException('Gist 链接缺少 ID');
    }
    final id = segments[1];
    return ParsedUrl(
      original: uri.toString(),
      normalized: 'https://gist.githubusercontent.com/${segments[0]}/$id/raw',
      kind: UrlKind.gist,
      owner: segments[0],
      filename: 'gist-$id.txt',
      note: 'Gist 页面链接已转换为 raw 直链；多文件请使用具体 raw 地址',
    );
  }
  if (segments.length < 3) {
    throw UrlParseException('Gist raw 链接不完整');
  }
  final id = segments[1];
  return ParsedUrl(
    original: uri.toString(),
    normalized: uri.toString(),
    kind: UrlKind.gist,
    owner: segments.first,
    path: segments.sublist(2).join('/'),
    filename: _sanitizeFilename(segments.last, 'gist-$id.txt'),
  );
}
