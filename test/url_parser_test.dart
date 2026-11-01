import 'package:flutter_test/flutter_test.dart';
import 'package:inkfetch/core/url_parser.dart';
import 'package:inkfetch/core/models.dart';

void main() {
  group('URL 解析', () {
    test('blob 链接转换为 raw 直链', () {
      final parsed = parseGitHubUrl(
        'https://github.com/rust-lang/rust/blob/master/README.md?plain=1#top',
      );
      expect(parsed.kind, UrlKind.raw);
      expect(
        parsed.normalized,
        'https://raw.githubusercontent.com/rust-lang/rust/master/README.md',
      );
      expect(parsed.filename, 'README.md');
      expect(parsed.owner, 'rust-lang');
      expect(parsed.gitRef, 'master');
    });

    test('raw 域名链接', () {
      final parsed = parseGitHubUrl(
        'raw.githubusercontent.com/owner/repo/main/src/main.rs',
      );
      expect(parsed.kind, UrlKind.raw);
      expect(parsed.filename, 'main.rs');
      expect(
        parsed.normalized,
        'https://raw.githubusercontent.com/owner/repo/main/src/main.rs',
      );
    });

    test('Release 资产', () {
      final parsed = parseGitHubUrl(
        'https://github.com/owner/repo/releases/download/v1.2.3/app-linux-x64.tar.gz',
      );
      expect(parsed.kind, UrlKind.release);
      expect(parsed.filename, 'app-linux-x64.tar.gz');
      expect(parsed.gitRef, 'v1.2.3');
    });

    test('仓库归档', () {
      final parsed = parseGitHubUrl(
        'https://github.com/owner/repo/archive/refs/heads/main.zip',
      );
      expect(parsed.kind, UrlKind.archive);
      expect(parsed.archiveFormat, 'zip');
      expect(parsed.gitRef, 'refs/heads/main');
      expect(parsed.filename, 'repo-main.zip');
    });

    test('codeload 规范化', () {
      final parsed = parseGitHubUrl(
        'https://codeload.github.com/owner/repo/tar.gz/refs/tags/v1.0',
      );
      expect(parsed.kind, UrlKind.archive);
      expect(parsed.archiveFormat, 'tar.gz');
      expect(parsed.gitRef, 'refs/tags/v1.0');
      expect(
        parsed.normalized,
        'https://github.com/owner/repo/archive/refs/tags/v1.0.tar.gz',
      );
    });

    test('仓库根链接转为 HEAD 压缩包', () {
      final parsed = parseGitHubUrl('https://github.com/owner/repo');
      expect(parsed.kind, UrlKind.archive);
      expect(
        parsed.normalized,
        'https://github.com/owner/repo/archive/HEAD.zip',
      );
      expect(parsed.filename, 'repo-HEAD.zip');
    });

    test('目录链接转为压缩包', () {
      final parsed = parseGitHubUrl(
        'https://github.com/owner/repo/tree/dev/src',
      );
      expect(parsed.kind, UrlKind.archive);
      expect(
        parsed.normalized,
        'https://github.com/owner/repo/archive/dev.zip',
      );
    });

    test('Gist raw', () {
      final parsed = parseGitHubUrl(
        'https://gist.githubusercontent.com/user/abc123/raw/notes.md',
      );
      expect(parsed.kind, UrlKind.gist);
      expect(parsed.filename, 'notes.md');
    });

    test('拒绝非 GitHub 域名', () {
      expect(
        () => parseGitHubUrl('https://example.com/file.zip'),
        throwsA(isA<UrlParseException>()),
      );
    });

    test('无协议输入自动补全', () {
      final parsed = parseGitHubUrl(
        'github.com/owner/repo/releases/download/v1/file.zip',
      );
      expect(parsed.kind, UrlKind.release);
    });

    test('中文与空格文件名会被解码', () {
      final parsed = parseGitHubUrl(
        'https://github.com/owner/repo/blob/main/docs/%E8%AF%B4%E6%98%8E.md',
      );
      expect(parsed.filename, '说明.md');
    });
  });
}
