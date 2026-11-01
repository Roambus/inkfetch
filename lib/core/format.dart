import 'models.dart';

String humanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes B';
  final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String humanSpeed(int bps) => '${humanBytes(bps)}/s';

String humanDuration(int? seconds) {
  if (seconds == null || seconds <= 0) return '—';
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final secs = seconds % 60;
  if (minutes < 60) return '${minutes}m ${secs.toString().padLeft(2, '0')}s';
  final hours = minutes ~/ 60;
  return '${hours}h ${(minutes % 60).toString().padLeft(2, '0')}m';
}

String formatTime(DateTime time) {
  String pad(int v) => v.toString().padLeft(2, '0');
  final now = DateTime.now();
  final sameDay =
      now.year == time.year && now.month == time.month && now.day == time.day;
  if (sameDay) {
    return '${pad(time.hour)}:${pad(time.minute)}';
  }
  return '${time.year}-${pad(time.month)}-${pad(time.day)} '
      '${pad(time.hour)}:${pad(time.minute)}';
}

String kindLabel(UrlKind kind) => switch (kind) {
  UrlKind.raw => 'RAW 文件',
  UrlKind.release => 'Release 资产',
  UrlKind.archive => '仓库压缩包',
  UrlKind.gist => 'Gist',
};

String laneLabel(String lane) => switch (lane) {
  'official' => '官方',
  'cdn' => 'CDN',
  'proxy' => '加速代理',
  'domain' => '域名镜像',
  _ => lane,
};

String phaseLabel(DownloadPhase phase) => switch (phase) {
  DownloadPhase.downloading => '下载中',
  DownloadPhase.paused => '已暂停',
  DownloadPhase.verifying => '校验中',
  DownloadPhase.completed => '已完成',
  DownloadPhase.failed => '失败',
  DownloadPhase.cancelled => '已取消',
};
