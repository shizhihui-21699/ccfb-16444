import 'geo.dart';

/// 轨迹点。
class TrackPoint {
  final LatLng position;
  final DateTime time;
  final double? altitudeM;

  /// GPS 精度(米),精度太差的点在聚类和统计时会被降权或丢弃。
  final double? accuracyM;

  const TrackPoint({
    required this.position,
    required this.time,
    this.altitudeM,
    this.accuracyM,
  });
}

/// 隐私区域(圆形)。只保存在用户本地设备,绝不上传。
class PrivacyZone {
  final String id;
  final LatLng center;
  final double radiusM;

  /// true = 由历史轨迹自动聚类得出;false = 用户手动设置。
  final bool automatic;

  const PrivacyZone({
    required this.id,
    required this.center,
    required this.radiusM,
    this.automatic = true,
  });

  bool contains(LatLng p, {double extraRadiusM = 0}) =>
      haversineM(center, p) <= radiusM + extraRadiusM;
}

/// 敏感区域(多边形,如保密单位),由服务端下发,用于热力图屏蔽。
class SensitiveArea {
  final String id;
  final List<LatLng> polygon;
  const SensitiveArea({required this.id, required this.polygon});

  bool contains(LatLng p) => pointInPolygon(p, polygon);
}

/// 基于【原始轨迹】计算的运动指标 —— 排行榜和距离统计只使用这份数据,
/// 与对外展示的模糊化轨迹完全解耦,因此模糊化不影响任何统计精度。
class ActivityMetrics {
  final double distanceM;
  final Duration elapsed;
  final Duration movingTime;
  final double elevationGainM;

  const ActivityMetrics({
    required this.distanceM,
    required this.elapsed,
    required this.movingTime,
    required this.elevationGainM,
  });

  /// 静止判定阈值:两采样点间平均速度低于该值视为静止(米/秒)。
  static const double _stoppedSpeedMps = 0.5;

  factory ActivityMetrics.compute(List<TrackPoint> raw) {
    var distance = 0.0;
    var moving = Duration.zero;
    var gain = 0.0;
    for (var i = 1; i < raw.length; i++) {
      final a = raw[i - 1];
      final b = raw[i];
      // 丢弃精度极差(>50m)的点对,避免 GPS 漂移虚增距离。
      final accA = a.accuracyM;
      final accB = b.accuracyM;
      if ((accA != null && accA > 50) || (accB != null && accB > 50)) continue;

      final d = haversineM(a.position, b.position);
      final dt = b.time.difference(a.time);
      // 过滤异常跳点(>100km/h 视为 GPS 跳变)。
      final dtSec = dt.inMilliseconds / 1000.0;
      if (dtSec <= 0) continue;
      final speed = d / dtSec;
      if (speed > 28) continue;

      distance += d;
      if (speed >= _stoppedSpeedMps) moving += dt;
      final altA = a.altitudeM;
      final altB = b.altitudeM;
      if (altA != null && altB != null && altB > altA) gain += altB - altA;
    }
    return ActivityMetrics(
      distanceM: distance,
      elapsed: raw.length >= 2
          ? raw.last.time.difference(raw.first.time)
          : Duration.zero,
      movingTime: moving,
      elevationGainM: gain,
    );
  }
}

/// 模糊化结果:公开轨迹 + 私密的完整指标。
class SanitizedActivity {
  /// 对外展示的轨迹(已裁剪起止段)。仅用于地图展示,不参与任何统计。
  final List<TrackPoint> publicTrack;

  /// 由原始完整轨迹算出的指标,用于距离统计与排行榜。
  final ActivityMetrics metrics;

  /// 起点端被隐藏的距离(米),可用于"本活动已隐藏起点附近 xxx 米"的提示。
  final double hiddenStartM;

  /// 终点端被隐藏的距离(米)。
  final double hiddenEndM;

  const SanitizedActivity({
    required this.publicTrack,
    required this.metrics,
    required this.hiddenStartM,
    required this.hiddenEndM,
  });
}
