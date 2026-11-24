import 'dart:math';

import 'geo.dart';
import 'models.dart';

/// 轨迹起止点模糊化。
///
/// 为什么不是简单截掉起止点:
/// 若轨迹离开隐私区域后仍走直线,攻击者沿轨迹走向反向延长即可推算出
/// 被截掉的一段指向哪里,几条轨迹交叉就能定位住址。因此本实现采用三层防护:
///
/// 1. 【裁剪到区域边界之外】轨迹完全离开隐私区域后才允许成为公开起点。
/// 2. 【每次活动随机扩展半径】用 (用户盐 + 活动ID) 做种子,每次裁剪半径
///    随机 +0~[maxRadiusJitterM]。否则所有活动的截点会落在一个圆环上,
///    圆环的圆心就是住址。
/// 3. 【延伸到"安全截点"】出区域后继续向前裁剪,直到轨迹发生过一次明显
///    转向(航向变化 ≥ [turnAngleDeg])且满足最小附加距离 —— 转向之后,
///    可见轨迹的走向不再指向来路,直线反推失效。附加距离本身也按活动随机,
///    并有上限 [maxExtraTrimM] 防止过度裁剪。
///
/// 距离统计与排行榜不受影响:指标在裁剪前由原始轨迹计算(见
/// [ActivityMetrics.compute]),公开轨迹仅用于展示。
class TrackSanitizer {
  /// 出区域后最少再裁掉的距离(米)。
  final double minExtraTrimM;

  /// 出区域后最多再裁掉的距离(找不到转向点时的兜底)。
  final double maxExtraTrimM;

  /// 判定"已转向"的航向变化阈值(度)。
  final double turnAngleDeg;

  /// 每次活动随机扩展区域半径的上限(米)。
  final double maxRadiusJitterM;

  /// 计算航向时向前/向后取的窗口长度(米),用于平滑 GPS 抖动。
  final double headingWindowM;

  const TrackSanitizer({
    this.minExtraTrimM = 150,
    this.maxExtraTrimM = 600,
    this.turnAngleDeg = 35,
    this.maxRadiusJitterM = 120,
    this.headingWindowM = 60,
  });

  /// [userSalt] 为每用户随机生成、只存本地的盐,保证同一用户同一活动的
  /// 裁剪结果可复现(重新上传时公开轨迹不变),但不同活动之间不可比较。
  SanitizedActivity sanitize({
    required List<TrackPoint> rawTrack,
    required List<PrivacyZone> zones,
    required String activityId,
    required String userSalt,
  }) {
    // 指标先算,基于完整原始轨迹。
    final metrics = ActivityMetrics.compute(rawTrack);

    if (rawTrack.length < 2 || zones.isEmpty) {
      return SanitizedActivity(
        publicTrack: List.of(rawTrack),
        metrics: metrics,
        hiddenStartM: 0,
        hiddenEndM: 0,
      );
    }

    // 每个活动独立的随机源:半径抖动与附加裁剪距离每次都不同,
    // 但对同一 (userSalt, activityId) 可复现。
    final rng = Random(_seed(userSalt, activityId));
    final jitter = rng.nextDouble() * maxRadiusJitterM;
    final extraTrim =
        minExtraTrimM + rng.nextDouble() * (maxExtraTrimM - minExtraTrimM);

    var start = 0;
    var end = rawTrack.length - 1;

    // 起点端:若活动从隐私区域内出发。
    if (_insideAny(rawTrack[start].position, zones, jitter)) {
      start = _findSafeCut(rawTrack, zones, jitter, extraTrim, forward: true);
    }
    // 终点端:若活动在隐私区域内结束。
    if (_insideAny(rawTrack[end].position, zones, jitter)) {
      end = _findSafeCut(rawTrack, zones, jitter, extraTrim, forward: false);
    }

    // 轨迹整体很短或两端裁剪相遇:整条不公开,只保留统计。
    final hideAll = start > end || start >= rawTrack.length || end < 0;
    final publicTrack =
        hideAll ? <TrackPoint>[] : rawTrack.sublist(start, end + 1);

    return SanitizedActivity(
      publicTrack: publicTrack,
      metrics: metrics,
      hiddenStartM: start >= rawTrack.length
          ? _pathLength(rawTrack, 0, rawTrack.length - 1)
          : _pathLength(rawTrack, 0, start),
      hiddenEndM:
          end < 0 ? _pathLength(rawTrack, 0, rawTrack.length - 1) : _pathLength(rawTrack, end, rawTrack.length - 1),
    );
  }

  int _seed(String userSalt, String activityId) {
    var h = 0x811c9dc5;
    for (final c in '$userSalt:$activityId'.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  bool _insideAny(LatLng p, List<PrivacyZone> zones, double extraM) =>
      zones.any((z) => z.contains(p, extraRadiusM: extraM));

  /// 从被保护的一端出发,找到安全的公开截点索引。
  /// 返回值超出轨迹范围(向前 ≥ length,向后 < 0)表示应隐藏整条轨迹。
  /// [forward] = true 处理起点端(向轨迹尾部扫描),false 处理终点端。
  int _findSafeCut(
    List<TrackPoint> track,
    List<PrivacyZone> zones,
    double radiusJitterM,
    double extraTrimM, {
    required bool forward,
  }) {
    final dir = forward ? 1 : -1;
    final edge = forward ? 0 : track.length - 1;
    final hideAll = forward ? track.length : -1;

    // 第一步:找到完全离开(抖动后)隐私区域的点。
    var i = edge;
    var guard = 0;
    while (guard++ < track.length) {
      final next = i + dir;
      if (next < 0 || next >= track.length) return hideAll; // 整条都在区域内
      if (!_insideAny(track[next].position, zones, radiusJitterM)) break;
      i = next;
    }
    final exitIndex = i + dir;
    if (exitIndex < 0 || exitIndex >= track.length) return hideAll;

    // 第二步:出区域后继续走,直到"走过最小附加距离 且 航向已明显改变",
    // 或达到最大附加距离。转向后可见轨迹的走向不再指向来路。
    final exitHeading = _smoothedHeading(track, exitIndex, forward: forward);
    var travelled = 0.0;
    var j = exitIndex;
    while (true) {
      final next = j + dir;
      if (next < 0 || next >= track.length) {
        return hideAll; // 剩余可见段太短,宁可整条隐藏
      }
      travelled += haversineM(track[j].position, track[next].position);
      j = next;
      if (travelled >= extraTrimM) {
        final heading = _smoothedHeading(track, j, forward: forward);
        if (heading == null ||
            exitHeading == null ||
            angleDiffDeg(heading, exitHeading).abs() >= turnAngleDeg) {
          return j;
        }
      }
      if (travelled >= maxExtraTrimM) return j;
    }
  }

  /// 在 [index] 附近取约 [headingWindowM] 的窗口计算平滑航向,
  /// 方向与轨迹行进方向一致(处理终点端时取反,保证"来路方向"语义一致)。
  double? _smoothedHeading(List<TrackPoint> track, int index,
      {required bool forward}) {
    final dir = forward ? -1 : 1; // 向来路方向取窗口
    var other = index;
    var dist = 0.0;
    while (true) {
      final next = other + dir;
      if (next < 0 || next >= track.length) break;
      dist += haversineM(track[next].position, track[other].position);
      other = next;
      if (dist >= headingWindowM) break;
    }
    if (other == index) return null;
    final d = haversineM(track[other].position, track[index].position);
    if (d < 5) return null; // 两点太近,航向不可靠
    return bearingDeg(track[other].position, track[index].position);
  }

  double _pathLength(List<TrackPoint> track, int from, int to) {
    var d = 0.0;
    for (var i = from; i < to && i + 1 < track.length; i++) {
      d += haversineM(track[i].position, track[i + 1].position);
    }
    return d;
  }
}
