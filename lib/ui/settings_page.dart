import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/mirrors.dart';
import '../../core/models.dart';
import '../../state/app_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  final AppController controller;
  const SettingsPage({super.key, required this.controller});

  AppController get c => controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('设置', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 14),
                _buildDestination(context),
                const SizedBox(height: 12),
                _buildPerformance(context),
                const SizedBox(height: 12),
                _buildAppearance(context),
                const SizedBox(height: 12),
                _buildMirrors(context),
                const SizedBox(height: 12),
                _buildAbout(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDestination(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '保存位置',
            subtitle: '手机与平板通过系统文件夹选择器授权，无需存储权限',
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kAccent.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: kAccent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.folder_special_rounded,
                    color: kAccent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.destinationLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        c.destinationSubLabel ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              FilledButton.icon(
                onPressed: c.pickDownloadDirectory,
                icon: const Icon(Icons.drive_file_move_rounded, size: 18),
                label: const Text('选择文件夹'),
              ),
              OutlinedButton.icon(
                onPressed: c.resetDownloadDirectory,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('恢复默认'),
              ),
            ],
          ),
          if (c.isAndroid) ...[
            const SizedBox(height: 10),
            Text(
              '提示：Android 建议选择一个公共文件夹（如 Download/OctoFetch）。'
              '未选择时文件保存在应用专属目录，卸载应用会一并删除。',
              style: TextStyle(fontSize: 11.5, color: muted, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPerformance(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: '下载性能', subtitle: '线程会在多个镜像之间按实测速度加权分配'),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('最大并发连接', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Pill(text: '${c.settings.maxConnections} 线程', color: kAccent),
            ],
          ),
          Slider(
            value: c.settings.maxConnections.toDouble(),
            min: 4,
            max: 48,
            divisions: 22,
            label: '${c.settings.maxConnections}',
            onChanged: (value) => c.setMaxConnections(value.round()),
          ),
          Text(
            '连接越多越容易跑满带宽，也会消耗更多镜像配额。默认 32 线程，'
            '网络较差时适当降低。',
            style: TextStyle(fontSize: 11.5, color: muted, height: 1.5),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: c.settings.verifySha,
            onChanged: c.setVerifySha,
            title: const Text(
              'SHA-256 完整性校验',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '完成后计算哈希；Release 会与 GitHub 官方 digest 比对',
              style: TextStyle(fontSize: 11.5, color: muted),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: c.settings.deepProbeAll,
            onChanged: c.setDeepProbe,
            title: const Text(
              '高精度测速',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '每次测试全部镜像；开启后每个源读取 1MB 样本，速度排序更准确但更耗流量',
              style: TextStyle(fontSize: 11.5, color: muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppearance(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: '外观', subtitle: '深色 / 浅色 / 跟随系统'),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'system',
                  icon: Icon(Icons.brightness_auto_rounded, size: 17),
                  label: Text('跟随系统'),
                ),
                ButtonSegment(
                  value: 'dark',
                  icon: Icon(Icons.dark_mode_rounded, size: 17),
                  label: Text('深色'),
                ),
                ButtonSegment(
                  value: 'light',
                  icon: Icon(Icons.light_mode_rounded, size: 17),
                  label: Text('浅色'),
                ),
              ],
              selected: {c.settings.theme},
              onSelectionChanged: (values) => c.setTheme(values.first),
              showSelectedIcon: false,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMirrors(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    final lanes = ['official', 'cdn', 'proxy', 'domain'];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '镜像管理',
            subtitle:
                '已启用 ${c.enabledMirrorCount} / ${builtinMirrors.length} 个镜像，'
                '关闭后会跳过该源',
            trailing: TextButton(
              onPressed: c.resetMirrors,
              child: const Text('全部启用'),
            ),
          ),
          const SizedBox(height: 4),
          for (final lane in lanes)
            _MirrorLane(lane: lane, controller: c, muted: muted),
        ],
      ),
    );
  }

  Widget _buildAbout(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const GradientBadge(size: 44, icon: Icons.bolt_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'OctoFetch 1.0.0',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '原生 Flutter · 无 WebView / 无本地网页服务',
                      style: TextStyle(fontSize: 11.5, color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '内置 ${builtinMirrors.length} 个下载源：GitHub 官方、codeload、'
            'jsDelivr、GitMirror 以及 ${builtinMirrors.where((m) => m.kind == MirrorKind.prefix).length} '
            '个加速代理。下载前会对目标文件发起 128KB（高精度 1MB）Range 实测，'
            '校验首段内容一致性后，按实测速度分配连接并分片并发下载。',
            style: TextStyle(fontSize: 12, color: muted, height: 1.65),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: const [
              Pill(text: '多源分片', color: kAccent, dense: true),
              Pill(text: '断点续传', color: kAccentAlt, dense: true),
              Pill(text: 'SHA-256', color: kAccentAlt, dense: true),
              Pill(text: 'Android SAF', color: kWarning, dense: true),
              Pill(text: '桌面原生窗口', color: kWarning, dense: true),
            ],
          ),
        ],
      ),
    );
  }
}

class _MirrorLane extends StatelessWidget {
  final String lane;
  final AppController controller;
  final Color muted;

  const _MirrorLane({
    required this.lane,
    required this.controller,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final items = builtinMirrors.where((m) => m.lane == lane).toList();
    final enabled = items
        .where((m) => !controller.settings.disabledMirrors.contains(m.id))
        .length;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 4),
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        laneLabel(lane),
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        '$enabled / ${items.length} 已启用',
        style: TextStyle(fontSize: 11.5, color: muted),
      ),
      children: [
        for (final mirror in items)
          _MirrorTile(
            mirror: mirror,
            enabled: !controller.settings.disabledMirrors.contains(mirror.id),
            controller: controller,
            muted: muted,
          ),
      ],
    );
  }
}

class _MirrorTile extends StatelessWidget {
  final MirrorSpec mirror;
  final bool enabled;
  final AppController controller;
  final Color muted;

  const _MirrorTile({
    required this.mirror,
    required this.enabled,
    required this.controller,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final host = mirror.base.isEmpty ? 'github.com' : mirror.base;
    return SwitchListTile(
      contentPadding: const EdgeInsets.only(left: 4, right: 4),
      dense: true,
      value: enabled,
      onChanged: (value) => controller.toggleMirror(mirror.id, value),
      title: Row(
        children: [
          Flexible(
            child: Text(
              mirror.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (mirror.experimental) ...[
            const SizedBox(width: 6),
            const Pill(text: '实验', color: kWarning, dense: true),
          ],
        ],
      ),
      subtitle: Text(
        host,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.5, color: muted),
      ),
      secondary: const Icon(Icons.cloud_outlined, size: 18),
    );
  }
}
