import 'geo.dart';
import 'models.dart';

/// 隐私区域自动识别。
///
/// 思路:用户不需要手动设置。把本机历史活动的【起点和终点】收集起来做
/// DBSCAN 密度聚类 —— 家门口、公司楼下会自然形成高密度簇,而随机路过
/// 的地点不会。每个足够密的簇生成一个圆形隐私区域。
///
/// 全部计算在设备本地完成,历史端点与隐私区域都不上传服务器。
class PrivacyZoneDetector {
  /// 邻域半径(米):端点相距小于该值视为同一簇。
  final double epsM;

  /// 形成隐私区域所需的最少端点数(往返算 2 个点,默认 3 即约 2 次活动)。
  final int minPts;

  /// 生成区域的最小半径(米),防止簇太集中时区域过小失去保护意义。
  final double minRadiusM;

  /// 在簇最远端点之外额外扩展的半径(米)。
  final double marginM;

  /// GPS 精度差于该值的端点不参与聚类(米)。
  final double maxAccuracyM;

  const PrivacyZoneDetector({
    this.epsM = 150,
    this.minPts = 3,
    this.minRadiusM = 200,
    this.marginM = 100,
    this.maxAccuracyM = 50,
  });

  /// 从历史活动的起止点中识别隐私区域。
  /// [endpoints] 为历次活动的起点与终点(每次活动贡献 2 个点)。
  List<PrivacyZone> detect(List<TrackPoint> endpoints) {
    final pts = endpoints
        .where((p) => p.accuracyM == null || p.accuracyM! <= maxAccuracyM)
        .map((p) => p.position)
        .toList();
    final clusters = _dbscan(pts);
    final zones = <PrivacyZone>[];
    for (var i = 0; i < clusters.length; i++) {
      final cluster = clusters[i];
      final center = _centroid(cluster);
      var radius = minRadiusM;
      for (final p in cluster) {
        final d = haversineM(center, p) + marginM;
        if (d > radius) radius = d;
      }
      zones.add(PrivacyZone(
        id: 'auto_$i',
        center: center,
        radiusM: radius,
        automatic: true,
      ));
    }
    return zones;
  }

  LatLng _centroid(List<LatLng> pts) {
    var lat = 0.0, lon = 0.0;
    for (final p in pts) {
      lat += p.lat;
      lon += p.lon;
    }
    return LatLng(lat / pts.length, lon / pts.length);
  }

  /// 标准 DBSCAN。运动历史端点量级很小(数百个),O(n²) 足够。
  List<List<LatLng>> _dbscan(List<LatLng> pts) {
    final n = pts.length;
    final visited = List.filled(n, false);
    final assigned = List.filled(n, false);
    final clusters = <List<LatLng>>[];

    List<int> neighbors(int i) {
      final result = <int>[];
      for (var j = 0; j < n; j++) {
        if (haversineM(pts[i], pts[j]) <= epsM) result.add(j);
      }
      return result;
    }

    for (var i = 0; i < n; i++) {
      if (visited[i]) continue;
      visited[i] = true;
      var seeds = neighbors(i);
      if (seeds.length < minPts) continue; // 噪声点,不成簇
      final cluster = <int>{};
      cluster.add(i);
      assigned[i] = true;
      while (seeds.isNotEmpty) {
        final j = seeds.removeLast();
        if (!visited[j]) {
          visited[j] = true;
          final jn = neighbors(j);
          if (jn.length >= minPts) seeds.addAll(jn);
        }
        if (!assigned[j]) {
          assigned[j] = true;
          cluster.add(j);
        }
      }
      clusters.add([for (final idx in cluster) pts[idx]]);
    }
    return clusters;
  }
}
