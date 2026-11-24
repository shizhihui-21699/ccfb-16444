import 'dart:math';

import 'package:fitness_privacy/fitness_privacy.dart';
import 'package:test/test.dart';

// ---------- 测试工具 ----------

LatLng offsetM(LatLng p, double bearingDeg, double meters) {
  final brng = bearingDeg * pi / 180;
  final dLat = meters * cos(brng) / 111320.0;
  final dLon = meters * sin(brng) / (111320.0 * cos(p.lat * pi / 180));
  return LatLng(p.lat + dLat, p.lon + dLon);
}

/// 按"航向+距离"的分段路径生成轨迹,每 [stepM] 米一个点。
List<TrackPoint> buildTrack(
  LatLng start,
  List<(double, double)> legs, {
  double stepM = 10,
}) {
  final pts = <TrackPoint>[];
  var pos = start;
  var t = DateTime(2026, 1, 1, 8);
  pts.add(TrackPoint(position: pos, time: t));
  for (final (bearing, meters) in legs) {
    var done = 0.0;
    while (done < meters) {
      pos = offsetM(pos, bearing, stepM);
      t = t.add(const Duration(seconds: 3));
      pts.add(TrackPoint(position: pos, time: t));
      done += stepM;
    }
  }
  return pts;
}

final home = LatLng(31.2304, 121.4737);
final homeZone = PrivacyZone(id: 'home', center: home, radiusM: 250);

void main() {
  group('PrivacyZoneDetector 隐私区域自动识别', () {
    test('反复出现的起止点聚成隐私区域,随机路过点不成簇', () {
      final rng = Random(42);
      final endpoints = <TrackPoint>[];
      // 8 次活动,起止点都在家附近 60m 内(GPS 自然抖动)。
      for (var i = 0; i < 16; i++) {
        final p = offsetM(home, rng.nextDouble() * 360, rng.nextDouble() * 60);
        endpoints.add(TrackPoint(position: p, time: DateTime(2026, 1, i + 1)));
      }
      // 3 个孤立的随机点,不应成簇。
      for (var i = 0; i < 3; i++) {
        endpoints.add(TrackPoint(
          position: offsetM(home, 90, 3000 + i * 2000),
          time: DateTime(2026, 2, i + 1),
        ));
      }

      final zones = const PrivacyZoneDetector().detect(endpoints);

      expect(zones, hasLength(1));
      expect(haversineM(zones.single.center, home), lessThan(50));
      expect(zones.single.radiusM, greaterThanOrEqualTo(200));
      expect(zones.single.automatic, isTrue);
    });

    test('历史活动太少时不生成区域(避免误伤)', () {
      final endpoints = [
        TrackPoint(position: home, time: DateTime(2026)),
        TrackPoint(position: offsetM(home, 0, 30), time: DateTime(2026)),
      ];
      expect(const PrivacyZoneDetector().detect(endpoints), isEmpty);
    });
  });

  group('TrackSanitizer 起止点模糊化', () {
    const sanitizer = TrackSanitizer(
      minExtraTrimM: 50,
      maxExtraTrimM: 500,
      maxRadiusJitterM: 0, // 测试中关闭抖动,结果确定
    );

    test('距离统计基于原始轨迹,不受裁剪影响', () {
      // 家 → 北 600m → 东 600m,全程 1200m。
      final raw = buildTrack(home, [(0, 600), (90, 600)]);
      final result = sanitizer.sanitize(
        rawTrack: raw,
        zones: [homeZone],
        activityId: 'a1',
        userSalt: 'salt',
      );
      expect(result.metrics.distanceM, closeTo(1200, 15));
      expect(result.hiddenStartM, greaterThan(0));
      // 公开轨迹显著短于原始轨迹。
      final publicLen =
          ActivityMetrics.compute(result.publicTrack).distanceM;
      expect(publicLen, lessThan(1200 - 250));
    });

    test('直线轨迹:截点延伸到最大附加距离,而非区域边界', () {
      final raw = buildTrack(home, [(0, 2000)]); // 一直向北,无转向
      final result = sanitizer.sanitize(
        rawTrack: raw,
        zones: [homeZone],
        activityId: 'a1',
        userSalt: 'salt',
      );
      final cutDist = haversineM(home, result.publicTrack.first.position);
      // 区域半径 250 + 最大附加 500。
      expect(cutDist, closeTo(750, 20));
    });

    test('带转向轨迹:截点延伸到转向之后,可见走向不再指向家', () {
      // 家 → 北 600m → 急转向东。转向点在 600m 处,出区域(250m)后
      // 若只截最小附加距离,可见段仍是直指家的直线;必须裁到转向之后。
      final raw = buildTrack(home, [(0, 600), (90, 800)]);
      final result = sanitizer.sanitize(
        rawTrack: raw,
        zones: [homeZone],
        activityId: 'a1',
        userSalt: 'salt',
      );
      final cutDist = haversineM(home, result.publicTrack.first.position);
      // 截点在转向点(600m)之后,且未超过 250+500=750m 上限。
      expect(cutDist, greaterThan(600));
      expect(cutDist, lessThanOrEqualTo(760));
    });

    test('终点在隐私区域内同样被裁剪', () {
      // 从 2km 外回家。
      final raw = buildTrack(offsetM(home, 180, 2000), [(0, 2000)]);
      final result = sanitizer.sanitize(
        rawTrack: raw,
        zones: [homeZone],
        activityId: 'a1',
        userSalt: 'salt',
      );
      final endDist = haversineM(home, result.publicTrack.last.position);
      expect(endDist, greaterThan(250));
      expect(result.hiddenEndM, greaterThan(0));
    });

    test('整条轨迹都在隐私区域内:不公开任何点,但统计仍然完整', () {
      final raw = buildTrack(home, [(0, 100)]); // 100m 短轨迹
      final result = sanitizer.sanitize(
        rawTrack: raw,
        zones: [homeZone],
        activityId: 'a1',
        userSalt: 'salt',
      );
      expect(result.publicTrack, isEmpty);
      expect(result.metrics.distanceM, closeTo(100, 5));
    });

    test('半径抖动:不同活动的截点位置不同,同一活动可复现', () {
      const jittery = TrackSanitizer(maxRadiusJitterM: 120);
      final raw = buildTrack(home, [(0, 3000)]);
      final a = jittery.sanitize(
          rawTrack: raw, zones: [homeZone], activityId: 'A', userSalt: 's');
      final b = jittery.sanitize(
          rawTrack: raw, zones: [homeZone], activityId: 'B', userSalt: 's');
      final a2 = jittery.sanitize(
          rawTrack: raw, zones: [homeZone], activityId: 'A', userSalt: 's');

      final cutA = haversineM(home, a.publicTrack.first.position);
      final cutB = haversineM(home, b.publicTrack.first.position);
      final cutA2 = haversineM(home, a2.publicTrack.first.position);

      expect(cutA, isNot(closeTo(cutB, 1))); // 截点不落在同一圆环上
      expect(cutA, closeTo(cutA2, 0.001)); // 同一活动重新上传结果一致
    });

    test('不在任何隐私区域内活动的轨迹原样公开', () {
      final far = offsetM(home, 90, 5000);
      final raw = buildTrack(far, [(0, 1000)]);
      final result = sanitizer.sanitize(
        rawTrack: raw,
        zones: [homeZone],
        activityId: 'a1',
        userSalt: 'salt',
      );
      expect(result.publicTrack, hasLength(raw.length));
    });
  });

  group('HeatmapFilter 热力图屏蔽', () {
    final sensitive = SensitiveArea(
      id: 'site',
      polygon: [
        LatLng(31.20, 121.40),
        LatLng(31.20, 121.41),
        LatLng(31.21, 121.41),
        LatLng(31.21, 121.40),
      ],
    );

    test('隐私区域内与敏感区域内的点被剔除,其余保留', () {
      final filter = HeatmapFilter(zoneMarginM: 0);
      final insideHome =
          TrackPoint(position: offsetM(home, 0, 50), time: DateTime(2026));
      final insideSite = TrackPoint(
          position: LatLng(31.205, 121.405), time: DateTime(2026));
      final outside = TrackPoint(
          position: offsetM(home, 0, 1000), time: DateTime(2026));

      expect(filter.isAllowed(insideHome, [homeZone], []), isFalse);
      expect(filter.isAllowed(insideSite, [], [sensitive]), isFalse);
      expect(filter.isAllowed(outside, [homeZone], [sensitive]), isTrue);
    });

    test('k-匿名:独立用户数不足的格子不展示', () {
      final agg = HeatmapAggregator(cellSizeM: 100, minUsers: 3);
      final p = LatLng(31.5, 121.5);
      agg.addPoint('u1', p);
      agg.addPoint('u2', p);
      agg.addPoint('u1', offsetM(p, 0, 10)); // 同用户同格,不重复计数
      expect(agg.visibleCells(), isEmpty); // 只有 2 个用户

      agg.addPoint('u3', p);
      expect(agg.visibleCells(), hasLength(1)); // 达到 3 人,放行
    });
  });
}
