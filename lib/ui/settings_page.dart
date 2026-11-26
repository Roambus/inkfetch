import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/format.dart';
import '../core/mirrors.dart';
import '../core/models.dart';
import '../core/update_check.dart';
import '../state/app_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  final AppController controller;
  const SettingsPage({super.key, required this.controller});

  static final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  AppController get c => controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const PageHead(title: '设置', subtitle: '按自己的网络与习惯微调。'),
              const SizedBox(height: 22),
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
    );
  }

  Widget _buildDestination(BuildContext context) {
    final palette = AppPalette.of(context);
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
              color: palette.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 18, color: palette.accent),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.destinationLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: palette.ink,
                        ),
                      ),
                      if ((c.destinationSubLabel ?? '').isNotEmpty &&
                          c.destinationSubLabel != c.destinationLabel) ...[
                        const SizedBox(height: 3),
                        Text(
                          c.destinationSubLabel ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: palette.muted),
                        ),
                      ],
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
              FilledButton(
                onPressed: c.pickDownloadDirectory,
                child: const Text('选择文件夹'),
              ),
              OutlinedButton(
                onPressed: c.resetDownloadDirectory,
                child: const Text('恢复默认'),
              ),
            ],
          ),
          if (c.isAndroid) ...[
            const SizedBox(height: 12),
            Text(
              '选公共文件夹（如 Download/InkFetch）可避免卸载时丢文件。',
              style: TextStyle(
                fontSize: 11.5,
                color: palette.muted,
                height: 1.55,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPerformance(BuildContext context) {
    final palette = AppPalette.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '下载性能',
            subtitle: '线程会在多个镜像之间按实测速度加权分配',
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '最大并发连接',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
              const Spacer(),
              Text(
                '${c.settings.maxConnections}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Slider(
            value: c.settings.maxConnections.toDouble(),
            min: 4,
            max: 48,
            divisions: 22,
            onChanged: (value) => c.setMaxConnections(value.round()),
          ),
          Text(
            '连接越多越容易跑满带宽，也会消耗更多镜像配额。默认 32 线程，'
            '网络较差时适当降低。',
            style: TextStyle(fontSize: 11.5, color: palette.muted, height: 1.55),
          ),
          const SizedBox(height: 14),
          Divider(color: palette.border),
          _SwitchRow(
            title: 'SHA-256 完整性校验',
            subtitle: '完成后计算哈希；Release 会与 GitHub 官方 digest 比对',
            value: c.settings.verifySha,
            onChanged: c.setVerifySha,
          ),
          Divider(color: palette.border),
          _SwitchRow(
            title: '高精度测速',
            subtitle: '每个源读取 1MB 样本，排序更准但更耗流量；'
                '开启后可用分片源不足时才扩展到长尾与实验源',
            value: c.settings.deepProbeAll,
            onChanged: c.setDeepProbe,
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
          _ThemeChoice(
            value: c.settings.theme,
            onChanged: (value) => c.setTheme(value),
          ),
        ],
      ),
    );
  }

  Widget _buildMirrors(BuildContext context) {
    final lanes = ['official', 'cdn', 'proxy', 'domain'];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
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
          const SizedBox(height: 6),
          for (var i = 0; i < lanes.length; i++) ...[
            if (i > 0) Divider(color: AppPalette.of(context).border),
            _MirrorGroup(lane: lanes[i], controller: c),
          ],
        ],
      ),
    );
  }

  Widget _buildAbout(BuildContext context) {
    final palette = AppPalette.of(context);
    final proxyCount = builtinMirrors
        .where((m) => m.kind == MirrorKind.prefix)
        .length;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const BrandMark(size: 40),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FutureBuilder<PackageInfo>(
                      future: _packageInfo,
                      builder: (context, snapshot) {
                        final info = snapshot.data;
                        final label = info == null
                            ? '墨取'
                            : '墨取 ${info.version}';
                        return Text(
                          label,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: palette.ink,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '原生 Flutter · 无 WebView / 无本地网页服务',
                      style: TextStyle(fontSize: 11.5, color: palette.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildUpdateRow(context, palette),
          const SizedBox(height: 4),
          Divider(color: palette.border, height: 20),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: openHomepage,
                icon: const Icon(Icons.public_rounded, size: 15),
                label: const Text('打开官网'),
              ),
              OutlinedButton.icon(
                onPressed: () => openReleasePage(),
                icon: const Icon(Icons.code_rounded, size: 15),
                label: const Text('GitHub 仓库'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            kHomepageUrl,
            style: TextStyle(
              fontFamily: kMono,
              fontFamilyFallback: kMonoFallback,
              fontSize: 10.5,
              color: palette.faint,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '内置 ${builtinMirrors.length} 个下载源：GitHub 官方、codeload、'
            'jsDelivr、GitMirror 以及 $proxyCount 个加速代理。'
            '下载前先测试常用镜像，可用分片源不足时才扩展到长尾源；'
            '每个源读取 128KB（高精度 1MB）Range 样本并校验首段内容一致性，'
            '然后按实测速度分配连接、分片并发下载。',
            style: TextStyle(fontSize: 12, color: palette.muted, height: 1.65),
          ),
          const SizedBox(height: 14),
          const Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              QuietTag(text: '多源分片'),
              QuietTag(text: '断点续传'),
              QuietTag(text: 'SHA-256'),
              QuietTag(text: 'Android SAF'),
              QuietTag(text: '桌面原生窗口'),
            ],
          ),
        ],
      ),
    );
  }

  /// 更新检查这一行。
  ///
  /// 显示三件事：现在是否最新、上次什么时候查过、一个可以手动重查的按钮。
  /// 「官网」不是隐藏链接，就写在这里——用户想找下载页时不该去翻文档。
  Widget _buildUpdateRow(BuildContext context, AppPalette palette) {
    final result = c.updateResult;
    final checkedAt = c.settings.lastUpdateCheck;
    final skipped = c.settings.skippedVersion;

    String status;
    Color statusColor;
    if (c.checkingUpdate) {
      status = '正在检查…';
      statusColor = palette.muted;
    } else if (result == null) {
      status = checkedAt == null ? '尚未检查' : '未检查到新版本';
      statusColor = palette.muted;
    } else if (!result.ok) {
      status = '检查失败';
      statusColor = palette.muted;
    } else if (result.hasUpdate) {
      status = skipped == result.latest
          ? '有新版本 ${result.latest}，已跳过'
          : '有新版本 ${result.latest}';
      statusColor = palette.accent;
    } else {
      status = '已是最新 ${result.current}';
      statusColor = palette.faint;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StatusDot(color: statusColor, label: status),
                  if (result != null && result.ok && result.source.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    QuietTag(text: '来源 ${result.source}'),
                  ],
                ],
              ),
              if (checkedAt != null) ...[
                const SizedBox(height: 4),
                Text(
                  '上次检查 ${_formatCheckedAt(checkedAt)}',
                  style: TextStyle(fontSize: 10.5, color: palette.faint),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: c.checkingUpdate
                  ? null
                  : () => c.checkUpdate(manual: true),
              child: Text(c.checkingUpdate ? '检查中…' : '检查更新'),
            ),
            if (skipped != null) ...[
              const SizedBox(height: 2),
              TextButton(
                onPressed: c.clearSkippedVersion,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  '恢复更新提示',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  static String _formatCheckedAt(String iso) {
    final time = DateTime.tryParse(iso);
    if (time == null) return iso;
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

/// 分段式主题选择，选中项改用边框与文字颜色区分，不使用填充色块。
class _ThemeChoice extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _ThemeChoice({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    const options = [
      ('system', '跟随系统', Icons.brightness_auto_outlined),
      ('dark', '深色', Icons.dark_mode_outlined),
      ('light', '浅色', Icons.light_mode_outlined),
    ];
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onChanged(options[i].$1),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: value == options[i].$1
                        ? palette.accent
                        : palette.border,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      options[i].$3,
                      size: 16,
                      color: value == options[i].$1
                          ? palette.accent
                          : palette.muted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      options[i].$2,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: value == options[i].$1
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: value == options[i].$1
                            ? palette.ink
                            : palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.muted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _MirrorGroup extends StatefulWidget {
  final String lane;
  final AppController controller;

  const _MirrorGroup({required this.lane, required this.controller});

  @override
  State<_MirrorGroup> createState() => _MirrorGroupState();
}

class _MirrorGroupState extends State<_MirrorGroup> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final items = builtinMirrors.where((m) => m.lane == widget.lane).toList();
    final enabled = items
        .where(
          (m) => !widget.controller.settings.disabledMirrors.contains(m.id),
        )
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Text(
                  laneLabel(widget.lane),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$enabled / ${items.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: palette.faint,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          for (final mirror in items)
            _MirrorRow(
              mirror: mirror,
              enabled: !widget.controller.settings.disabledMirrors.contains(
                mirror.id,
              ),
              controller: widget.controller,
            ),
        if (_open) const SizedBox(height: 4),
      ],
    );
  }
}

class _MirrorRow extends StatelessWidget {
  final MirrorSpec mirror;
  final bool enabled;
  final AppController controller;

  const _MirrorRow({
    required this.mirror,
    required this.enabled,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final host = mirror.base.isEmpty ? 'github.com' : mirror.base;
    return Padding(
      padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        mirror.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: enabled ? palette.ink : palette.faint,
                        ),
                      ),
                    ),
                    if (mirror.experimental) ...[
                      const SizedBox(width: 6),
                      const QuietTag(text: '实验'),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: palette.faint),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: (value) => controller.toggleMirror(mirror.id, value),
          ),
        ],
      ),
    );
  }
}

