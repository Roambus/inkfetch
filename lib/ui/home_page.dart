import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/mirrors.dart';
import '../../core/models.dart';
import '../../state/app_controller.dart';
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
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
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
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.92,
          minChildSize: 0.4,
          builder: (context, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
              children: [
                SectionHeader(
                  title: '全部镜像测试结果',
                  subtitle:
                      '共测试 ${report.testedCount} 个源，'
                      '${report.usableCount} 个可用，'
                      '${report.rangeCount} 个支持分片',
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < report.sources.length; i++)
                  SourceProbeRow(probe: report.sources[i], index: i),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = c.report;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(context),
                    const SizedBox(height: 18),
                    if (c.probing) ...[
                      _buildProbingCard(context),
                      const SizedBox(height: 14),
                    ],
                    if (c.probeError != null) ...[
                      _buildErrorCard(context),
                      const SizedBox(height: 14),
                    ],
                    if (report != null) ...[
                      _buildReportCard(context, report),
                      const SizedBox(height: 14),
                    ],
                    const SizedBox(height: 6),
                    _buildExamples(context),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ),
        ),
        _buildComposer(context),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.55);
    final compact = MediaQuery.sizeOf(context).width < 560;
    return Row(
      children: [
        const GradientBadge(size: 52),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      'OctoFetch',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(letterSpacing: -0.8),
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 9),
                    const Pill(
                      text: '原生 Flutter',
                      color: kAccentAlt,
                      icon: Icons.smartphone_rounded,
                      dense: true,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              Text(
                compact ? '多源并发 · 跑满带宽' : '多镜像实测 · 多源分片并发 · 跑满带宽',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 9 : 12,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: kAccent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kAccent.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              const Icon(Icons.hub_rounded, size: 16, color: kAccent),
              const SizedBox(width: 6),
              Text(
                compact
                    ? '${builtinMirrors.length}'
                    : '${builtinMirrors.length} 个镜像',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: kAccent,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProbingCard(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('正在测试镜像', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  c.probeMessage.isEmpty ? '正在准备…' : c.probeMessage,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(BuildContext context) {
    return AppCard(
      color: kDanger.withValues(alpha: 0.08),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: kDanger),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              c.probeError!,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExamples(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    final examples = [
      'https://github.com/rust-lang/rust/blob/master/README.md',
      'https://github.com/git/git/archive/refs/heads/master.zip',
      'https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-1.7.1-amd64.deb',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 15, color: muted),
            const SizedBox(width: 6),
            Text(
              '试试示例链接',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final url in examples)
              ActionChip(
                label: Text(
                  _shorten(url),
                  style: const TextStyle(fontSize: 11.5),
                ),
                onPressed: () => _fill(url),
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.12),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  String _shorten(String url) {
    if (url.length <= 62) return url;
    return '${url.substring(0, 42)}…${url.substring(url.length - 16)}';
  }

  Widget _buildReportCard(BuildContext context, ProbeReport report) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    final plan = report.plan;
    final top = report.sources.take(4).toList();
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
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
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Pill(
                          text: kindLabel(report.parsed.kind),
                          color: kAccent,
                          dense: true,
                        ),
                        Pill(
                          text: '${report.testedCount} 个适配源已实测',
                          color: kAccentAlt,
                          icon: Icons.speed_rounded,
                          dense: true,
                        ),
                        Pill(
                          text: '${report.probedMs}ms',
                          color: muted,
                          icon: Icons.timer_outlined,
                          dense: true,
                        ),
                        if (report.expectedSha256 != null)
                          const Pill(
                            text: '官方 SHA',
                            color: kAccentAlt,
                            dense: true,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: c.busy ? null : _retest,
                child: const Text('重新测试'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kAccent.withValues(alpha: 0.18)),
            ),
            child: StatGrid(
              items: [
                StatBlock(
                  label: '可用源',
                  value: '${report.usableCount}',
                  accent: kAccentAlt,
                  icon: Icons.cloud_done_rounded,
                ),
                StatBlock(
                  label: '分片源',
                  value: '${report.rangeCount}',
                  icon: Icons.call_split_rounded,
                ),
                StatBlock(
                  label: '并发连接',
                  value: '${plan.totalConnections}',
                  accent: kAccent,
                  icon: Icons.hub_rounded,
                ),
                StatBlock(
                  label: '文件大小',
                  value: report.totalSize == null
                      ? '未知'
                      : humanBytes(report.totalSize!),
                  icon: Icons.straighten_rounded,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            plan.reason,
            style: TextStyle(fontSize: 11.5, color: muted, height: 1.5),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < top.length; i++)
            SourceProbeRow(probe: top[i], index: i),
          if (report.sources.length > top.length)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _showAllMirrors,
                icon: const Icon(Icons.list_alt_rounded, size: 17),
                label: Text('查看全部 ${report.sources.length} 个镜像结果'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF0B1524) : Colors.white;
    final busy = c.busy;
    final percent = c.snapshot != null && c.downloading
        ? c.snapshot!.progress
        : null;
    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        border: Border(
          top: BorderSide(
            color: dark ? const Color(0xFF22324C) : const Color(0xFFE1E9F5),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.45 : 0.08),
            blurRadius: 26,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.folder_special_rounded,
                        size: 16,
                        color: kAccent.withValues(alpha: 0.9),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '保存到 ',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.45),
                                ),
                              ),
                              TextSpan(
                                text: c.destinationLabel,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.8),
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      InkWell(
                        onTap: busy ? null : c.pickDownloadDirectory,
                        borderRadius: BorderRadius.circular(8),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(
                            '更改',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: kAccent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          focusNode: _focus,
                          onChanged: c.setUrl,
                          onSubmitted: (_) => _download(),
                          textInputAction: TextInputAction.go,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 13.5),
                          decoration: InputDecoration(
                            hintText: '粘贴 GitHub 文件 / Release / 压缩包链接',
                            hintStyle: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.onSurface
                                  .withValues(alpha: 0.38),
                            ),
                            prefixIcon: const Icon(
                              Icons.link_rounded,
                              size: 19,
                            ),
                            suffixIcon: IconButton(
                              tooltip: '粘贴剪贴板链接',
                              onPressed: busy ? null : _paste,
                              icon: const Icon(
                                Icons.content_paste_go_rounded,
                                size: 18,
                              ),
                            ),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 14,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          onPressed: busy ? null : _test,
                          child: const Text('测试'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: busy ? null : _download,
                      style: FilledButton.styleFrom(
                        backgroundColor: kAccent,
                        disabledBackgroundColor: kAccent.withValues(
                          alpha: 0.35,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (busy && percent != null) ...[
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                value: percent > 0 ? percent : null,
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '下载中 ${(percent * 100).toStringAsFixed(0)}%',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ] else ...[
                            const Icon(Icons.rocket_launch_rounded, size: 19),
                            const SizedBox(width: 9),
                            Text(
                              busy ? '处理中…' : '开始下载',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
