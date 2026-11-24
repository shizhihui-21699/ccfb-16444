import 'geo.dart';
import 'models.dart';

/// 热力图隐私过滤(客户端侧)。
///
/// 原则:凡是可能暴露隐私区域或敏感区域的点,根本不上传到热力图管道,
/// 而不是上传后在服务端打码 —— 服务端数据泄露时原始点不存在才是真正的保护。
class HeatmapFilter {
  /// 热力图过滤时隐私区域额外扩张的半径(米)。
  /// 比展示裁剪更保守:即使某段轨迹对本人公开,其靠近家的部分也不进热力图。
  final double zoneMarginM;

  const HeatmapFilter({this.zoneMarginM = 80});

  bool isAllowed(
    TrackPoint p,
    List<PrivacyZone> zones,
    List<SensitiveArea> sensitiveAreas,
  ) {
    for (final z in zones) {
      if (z.contains(p.position, extraRadiusM: zoneMarginM)) return false;
    }
    for (final a in sensitiveAreas) {
      if (a.contains(p.position)) return false;
    }
    return true;
  }

  /// 过滤整条轨迹,返回可上传至热力图管道的点。
  /// 被过滤段两侧的点不再相邻,聚合方应按时间戳断开线段,避免画出穿越
  /// 隐私区域的虚假直线。
  List<TrackPoint> filterTrack(
    List<TrackPoint> track,
    List<PrivacyZone> zones,
    List<SensitiveArea> sensitiveAreas,
  ) =>
      track.where((p) => isAllowed(p, zones, sensitiveAreas)).toList();
}

/// 热力图聚合(服务端侧)的 k-匿名保护。
///
/// 即使所有输入点都已过客户端过滤,热力图仍可能暴露"保密单位人员的
/// 活动规律":某个偏远格子里长期只有寥寥几人活动,本身就是一种信号。
/// 因此聚合时按网格统计【去重用户数】,不足 k 人的格子不下发、不渲染。
class HeatmapAggregator {
  /// 网格边长(米),约等于该纬度下的经度格换算。
  final double cellSizeM;

  /// 每个格子至少需要的独立用户数(k-匿名阈值)。
  final int minUsers;

  HeatmapAggregator({this.cellSizeM = 100, this.minUsers = 3});

  final Map<String, Set<String>> _cellUsers = {};

  String _cellKey(LatLng p) {
    // 等距圆柱近似投影成米,对热力图网格足够(格形随纬度略有拉伸,
    // 不影响匿名性;如需精确可换 S2/Geohash)。
    final latM = p.lat * 111320.0;
    final lonM = p.lon * 111320.0;
    return '${(latM / cellSizeM).floor()}:${(lonM / cellSizeM).floor()}';
  }

  void addPoint(String userId, LatLng p) {
    _cellUsers.putIfAbsent(_cellKey(p), () => <String>{}).add(userId);
  }

  /// 返回允许展示的格子键。调用方只渲染这些格子。
  Set<String> visibleCells() => {
        for (final e in _cellUsers.entries)
          if (e.value.length >= minUsers) e.key,
      };
}
