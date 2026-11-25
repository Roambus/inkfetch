import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从一段 Text(...) 代码里取出 style: 之后的表达式文本。
///
/// 只是给测试做粗判用的，不追求完整解析——只要能看出
/// 「这个 style 是不是三元表达式」就够了。
String? _styleExpression(String block) {
  final index = block.indexOf('style:');
  if (index < 0) return null;
  return block.substring(index);
}

/// 等宽字体（Cascadia Mono 子集）只有 377 个拉丁字形，**不含任何中文**。
/// 一旦把含中文的文案交给它，整段会渲染成方块（豆腐块）。
///
/// 「64 分片 · 4 个源」「准备下载…」「N 分片」这几处都曾经是方块，
/// 用户看到的就是「界面上大量意义不明的方块」。这个测试守住这条边界：
///   - 等宽样式的回退链里必须有中文字体；
///   - UI 代码里不允许把含中文的字面量交给 dataStyle / kMono。
void main() {
  test('等宽字体的回退链里必须有中文字体', () {
    final theme = File('lib/ui/theme.dart').readAsStringSync();
    final match = RegExp(
      r'const List<String> kMonoFallback\s*=\s*\[(.*?)\];',
      dotAll: true,
    ).firstMatch(theme);
    expect(match, isNotNull, reason: '找不到 kMonoFallback 定义');
    final body = match!.group(1)!;
    // 至少要有一个能在 Windows / macOS / Linux 上兜住中文的字体。
    final hasCjk = ['YaHei', 'Noto Sans SC', 'PingFang SC', 'sans-serif']
        .any(body.contains);
    expect(
      hasCjk,
      isTrue,
      reason: 'kMonoFallback 缺少中文字体，中文会渲染成方块：$body',
    );
  });

  test('UI 代码不把含中文的字面量交给等宽样式', () {
    final cjk = RegExp(r'[\u4e00-\u9fff]');
    final offenders = <String>[];

    for (final file in Directory('lib/ui')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // 只看「纯等宽」样式的落点：dataStyle(...) 或 fontFamily: kMono。
        if (!line.contains('dataStyle(') &&
            !line.contains('fontFamily: kMono')) {
          continue;
        }
        var start = i;
        while (start > 0 && !lines[start].contains('Text(')) {
          start--;
        }
        final block = lines.sublist(start, i + 1).join('\n');

        // 条件分支是安全的写法：
        //   style: cond ? TextStyle(...) : dataStyle(...)
        // 中文那支走普通 TextStyle，只有数字才会落到等宽。
        // 判断依据是 style: 之后出现了三元运算符。
        final styleLine = _styleExpression(block);
        final isConditional =
            styleLine != null && styleLine.contains('?') &&
            styleLine.indexOf('?') < styleLine.indexOf('dataStyle');

        for (final m in RegExp(r"'([^'\\]*(?:\\.[^'\\]*)*)'").allMatches(block)) {
          final literal = m.group(1)!;
          if (!cjk.hasMatch(literal)) continue;
          if (isConditional) {
            // 中文落在三元的前一支，不会进 dataStyle。
            continue;
          }
          offenders.add('${file.path}:${i + 1} -> $literal');
          break;
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些文案含中文却用了等宽字体，会渲染成方块：\n${offenders.join('\n')}',
    );
  });
}
