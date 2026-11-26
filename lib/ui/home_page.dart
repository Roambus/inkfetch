import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../state/app_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  final AppController controller;
  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _text.text = c.urlInput;
    c.addListener(_syncInput);
  }

  @override
  void dispose() {
    c.removeListener(_syncInput);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 从队列或未完成任务恢复时，输入框需要跟随控制器。
  void _syncInput() {
    if (_focus.hasFocus) return;
    if (_text.text == c.urlInput) return;
    _text.value = TextEditingValue(
      text: c.urlInput,
      selection: TextSelection.collapsed(offset: c.urlInput.length),
    );
  }

  void _fill(String url) {
    _text.text = url;
    _text.selection = TextSelection.fromPosition(
      TextPosition(offset: url.length),
    );
    c.setUrl(url);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _fill(text);
  }

  Future<void> _test() async {
    _focus.unfocus();
    await c.probe();
  }

  Future<void> _retest() async {
    _focus.unfocus();
    await c.probe(force: true);
  }

  Future<void> _download() async {
    _focus.unfocus();
    await c.startDownload();
  }

  void _showAllMirrors() {
    final report = c.report;
    if (report == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            children: [
              SectionHeader(
                title: '全部镜像结果',
                subtitle:
                    '测试 ${report.testedCount} 个源 · 可用 ${report.usableCount} 个 · '
                    '支持分片 ${report.rangeCount} 个',
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < report.sources.length; i++) ...[
                if (i > 0) Divider(height: 1),
                SourceProbeRow(probe: report.sources[i], index: i),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = c.report;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHead(
                title: '下载',
                subtitle: '多镜像并发拉取，慢源自动降权，断了可以接着下。',
                trailing: _MirrorCount(count: c.enabledMirrorCount),
              ),
              const SizedBox(height: 26),
              _buildComposer(context),
              if (c.probing) ...[
                const SizedBox(height: 12),
                _buildProbing(context),
              ],
              if (c.probeError != null) ...[
                const SizedBox(height: 12),
                _buildError(context),
              ],
              if (report != null) ...[
                const SizedBox(height: 12),
                _buildReport(context, report),
              ],
              const SizedBox(height: 30),
              if (report == null) _buildExamples(context) else _buildExamples(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 输入区不是一张「填表卡片」，而是一整条可写字的案面：
  /// 上面是链接输入，下面一分为二——保存位置在左，动作在右。
  Widget _buildComposer(BuildContext context) {
    final palette = AppPalette.of(context);
    final busy = c.busy;
    final percent = c.snapshot != null && c.downloading
        ? c.snapshot!.progress
        : null;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 链接输入：一整行，没有输入框边框，靠下划线分界。
          Container(
            padding: const EdgeInsets.fromLTRB(18, 6, 8, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: [
                Icon(Icons.link_rounded, size: 18, color: palette.faint),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    onChanged: c.setUrl,
                    onSubmitted: (_) => _download(),
                    textInputAction: TextInputAction.go,
                    maxLines: 1,
                    style: TextStyle(fontSize: 13.5, color: palette.ink),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '粘贴 GitHub 文件、Release、压缩包或 Gist 链接',
                      prefixIcon: null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '粘贴剪贴板',
                  onPressed: busy ? null : _paste,
                  icon: const Icon(Icons.content_paste_rounded, size: 16),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 窄屏：动作独占一行；宽屏：保存位置在左、动作在右。
                final compact = constraints.maxWidth < 520;
                final actions = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton(
                      onPressed: busy ? null : _test,
                      child: const Text('测试镜像'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: busy ? null : _download,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (busy && percent != null) ...[
                            SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                value: percent > 0 ? percent : null,
                                strokeWidth: 2,
                                color: palette.onPrimaryFill,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('${(percent * 100).toStringAsFixed(0)}%'),
                          ] else
                            Text(busy ? '处理中' : '开始下载'),
                        ],
                      ),
                    ),
                  ],
                );
                final destination = Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 15, color: palette.faint),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        c.destinationLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: palette.muted),
                      ),
                    ),
                    const SizedBox(width: 2),
                    TextButton(
                      onPressed: busy ? null : c.pickDownloadDirectory,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('更改'),
                    ),
                  ],
                );
                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      destination,
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: actions),
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: destination),
                    const SizedBox(width: 12),
                    actions,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProbing(BuildContext context) {
    final palette = AppPalette.of(context);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: palette.accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              c.probeMessage.isEmpty ? '正在测试镜像…' : c.probeMessage,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final palette = AppPalette.of(context);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      color: palette.danger.withValues(alpha: 0.05),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: palette.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              c.probeError!,
              style: TextStyle(
                fontSize: 12,
                color: palette.danger,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReport(BuildContext context, ProbeReport report) {
    final palette = AppPalette.of(context);
    final plan = report.plan;
    final top = report.sources.take(4).toList();
    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      report.parsed.filename,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        QuietTag(text: kindLabel(report.parsed.kind)),
                        if (report.expectedSha256 != null)
                          const QuietTag(text: '官方 SHA'),
                        Text(
                          '已测试 ${report.testedCount} 个源 · ${report.probedMs}ms',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: palette.faint,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: c.busy ? null : _retest,
                child: const Text('重新测试'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ReadingStrip(
            items: [
              Reading(label: '可用源', value: '${report.usableCount}'),
              Reading(label: '分片源', value: '${report.rangeCount}'),
              Reading(label: '并发连接', value: '${plan.totalConnections}'),
              Reading(
                label: '文件大小',
                value: report.totalSize == null
                    ? '未知'
                    : humanBytes(report.totalSize!),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            plan.reason,
            style: TextStyle(fontSize: 11.5, color: palette.muted, height: 1.65),
          ),
          const SizedBox(height: 14),
          Divider(height: 1),
          for (var i = 0; i < top.length; i++) ...[
            if (i > 0) Divider(height: 1),
            SourceProbeRow(probe: top[i], index: i),
          ],
          if (report.sources.length > top.length)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _showAllMirrors,
                child: Text('查看全部 ${report.sources.length} 个镜像结果'),
              ),
            ),
        ],
      ),
    );
  }

  /// 示例链接做成可点的整行，每行说明它是什么类型的链接——
  /// 比三条下划线 URL 有用得多。
  ///
  /// 用的是本项目自己的仓库：真能下、大小有区分，
  /// Release 那条还带官方 digest，能顺带演示 SHA-256 校验。
  Widget _buildExamples(BuildContext context) {
    final palette = AppPalette.of(context);
    final examples = [
      (
        '单文件',
        'inkfetch · InkMono-Regular.ttf',
        'https://github.com/Roambus/inkfetch/blob/main/assets/fonts/InkMono-Regular.ttf',
      ),
      (
        '仓库快照',
        'photocraft · main.zip',
        'https://github.com/Roambus/photocraft/archive/refs/heads/main.zip',
      ),
      (
        'Release 资产',
        'scrcpy-LiteUI · Kuaitou-v2.1.0.exe',
        'https://github.com/Roambus/scrcpy-LiteUI/releases/download/v2.1.0/Kuaitou-v2.1.0.exe',
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '试试这些',
          style: displayStyle(
            size: 15,
            weight: FontWeight.w600,
            color: palette.muted,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        for (final example in examples)
          _ExampleRow(
            kind: example.$1,
            label: example.$2,
            onTap: () => _fill(example.$3),
          ),
        const SizedBox(height: 22),
        Divider(height: 1),
        const SizedBox(height: 18),
        // 空着的下半屏不该只是死白：把「这个工具在做什么」写清楚，
        // 顺手也是这一页的收尾。
        _HowItWorks(),
      ],
    );
  }
}

/// 首页收尾的一行说明。
///
/// 旧版这里是「解析 / 分片 / 落地」三段解释性文字，读起来像产品文档，
/// 而且讲的东西界面上本来就看得见。现在压成一行，只留用户真正需要
/// 知道的一件事：下完会校验。
class _HowItWorks extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 14,
          color: palette.faint,
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            '下载完成后会算 SHA-256，与官方校验值比对。',
            style: TextStyle(
              fontSize: 11.5,
              color: palette.faint,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }
}

class _ExampleRow extends StatelessWidget {
  final String kind;
  final String label;
  final VoidCallback onTap;

  const _ExampleRow({
    required this.kind,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 74,
              child: Text(
                kind,
                style: TextStyle(fontSize: 11, color: palette.faint),
              ),
            ),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kMono,
                  fontFamilyFallback: kMonoFallback,
                  fontSize: 11.5,
                  color: palette.muted,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.north_east_rounded,
              size: 13,
              color: palette.faint,
            ),
          ],
        ),
      ),
    );
  }
}

/// 右上角的源数量：小数字 + 说明，不用彩色胶囊。
class _MirrorCount extends StatelessWidget {
  final int count;
  const _MirrorCount({required this.count});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '$count',
          style: dataStyle(size: 19, weight: FontWeight.w600, color: palette.ink),
        ),
        const SizedBox(height: 1),
        Text(
          '个镜像源',
          style: TextStyle(fontSize: 10, color: palette.faint),
        ),
      ],
    );
  }
}




