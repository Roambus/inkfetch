import 'dart:convert';
import 'dart:io';

import 'github_accel.dart';

// hosts 文件的读写规则。
//
// 核心原则：**绝不动用户的其它条目**。
//
// 做法是用一对标记把我们的内容包起来，只增删这一段：
//
// ```
// # BEGIN InkFetch GitHub Accelerator
// 140.82.114.6 api.github.com
// # END InkFetch GitHub Accelerator
// ```
//
// 启用时如果已有旧区块就先剔掉再写入新的（避免重复累积）；
// 停用时整段移除，其余内容逐字节保持不变。
//
// 注意：这个文件在 Windows 上是 CRLF、可能带 BOM、也可能末尾没有换行。
// 这些都按原样保留，不做「顺手规范化」——那同样属于改用户的东西。

// 区块起始标记。
const String kHostsBeginMarker = '# BEGIN InkFetch GitHub Accelerator';

// 区块结束标记。
const String kHostsEndMarker = '# END InkFetch GitHub Accelerator';

// 把条目拼成待嵌入的文本（不含标记）。
//
// 同一域名只留一条；域名按字母序，输出稳定，便于比对「内容有没有变」。
String buildHostsBlock(Iterable<HostEntry> entries) {
  final byHost = <String, String>{};
  for (final e in entries) {
    byHost.putIfAbsent(e.host, () => e.ip);
  }
  if (byHost.isEmpty) return '';
  final hosts = byHost.keys.toList()..sort();
  final buffer = StringBuffer();
  for (final host in hosts) {
    // 用空格对齐：IP 左对齐到 16 列，和常见 hosts 排版一致。
    buffer.writeln('${byHost[host]!.padRight(16)} $host');
  }
  return buffer.toString();
}

// 从现有 hosts 文本里剔除我们写过的区块（含标记行）。
//
// 支持多次残留：即使因为异常留下了多个区块，也一并清掉。
String stripHostsBlock(String text) {
  final lines = const LineSplitter().convert(text);
  final kept = <String>[];
  var inside = false;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed == kHostsBeginMarker) {
      inside = true;
      continue;
    }
    if (trimmed == kHostsEndMarker) {
      inside = false;
      continue;
    }
    if (inside) continue;
    kept.add(line);
  }
  // 保留原有换行风格：本来用 CRLF 就用 CRLF。
  final crlf = text.contains('\r\n');
  final eol = crlf ? '\r\n' : '\n';
  final joined = kept.join(eol);
  // 去掉我们清理后可能在结尾留下的多余空行，但保留用户自己的一行尾部空行。
  return joined.trimRight().isEmpty ? '' : joined;
}

// 把加速条目合并进现有 hosts 文本，返回新的完整内容。
//
// 已有区块会先被剔除，再在末尾追加新块，因此重复启用不会累积。
String applyHostsBlock(String original, Iterable<HostEntry> entries) {
  final block = buildHostsBlock(entries);
  final base = stripHostsBlock(original);
  final crlf = original.contains('\r\n');
  final eol = crlf ? '\r\n' : '\n';

  final buffer = StringBuffer();
  if (base.trim().isNotEmpty) {
    buffer.write(base);
    if (!base.endsWith('\n')) buffer.write(eol);
    buffer.write(eol);
  }
  buffer.write(kHostsBeginMarker);
  buffer.write(eol);
  if (block.isNotEmpty) {
    // block 内部用的是 \n，按宿主文件风格换行。
    for (final line in const LineSplitter().convert(block)) {
      buffer.write(line);
      buffer.write(eol);
    }
  }
  buffer.write(kHostsEndMarker);
  buffer.write(eol);
  return buffer.toString();
}

// 现有文本里是否已经含有我们的区块。
bool hasHostsBlock(String text) =>
    text.contains(kHostsBeginMarker) && text.contains(kHostsEndMarker);

// 从现有文本里读出我们写过的条目（用于界面展示「当前生效了什么」）。
List<HostEntry> readHostsBlock(String text) {
  final lines = const LineSplitter().convert(text);
  final entries = <HostEntry>[];
  var inside = false;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed == kHostsBeginMarker) {
      inside = true;
      continue;
    }
    if (trimmed == kHostsEndMarker) {
      inside = false;
      continue;
    }
    if (!inside) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      entries.add(HostEntry(parts[1], parts[0]));
    }
  }
  return entries;
}

// Windows 上 hosts 文件的位置。
String windowsHostsPath() {
  final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return '$root${Platform.pathSeparator}System32'
      '${Platform.pathSeparator}drivers${Platform.pathSeparator}etc'
      '${Platform.pathSeparator}hosts';
}

// 备份文件的路径：与 hosts 同目录，后缀 .inkfetch.bak。
String hostsBackupPath(String hostsPath) => '$hostsPath.inkfetch.bak';

// 读取 hosts 文本；文件不存在时返回空串。
Future<String> readHostsFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return '';
  final bytes = await file.readAsBytes();
  // 有些 hosts 带 UTF-8 BOM，直接 decode 会在首行留下 \uFEFF，
  // 导致后面的解析把第一行当注释失败。这里显式剥掉。
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  return utf8.decode(bytes, allowMalformed: true);
}
