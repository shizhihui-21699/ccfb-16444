/// 运动轨迹隐私保护库。
///
/// 数据流总览:
///
/// ```
/// 原始轨迹(仅设备本地)
///   ├─► ActivityMetrics.compute ──► 距离统计 / 排行榜(精确,不受模糊化影响)
///   ├─► TrackSanitizer.sanitize ──► 公开轨迹(起止点模糊化,仅用于展示)
///   └─► HeatmapFilter.filterTrack ──► 热力图上传点(剔除隐私区域+敏感区域)
///                                        └─► 服务端 HeatmapAggregator(k-匿名)
///
/// PrivacyZoneDetector(本地 DBSCAN 聚类历史起止点)──► 隐私区域(仅本地存储)
/// ```
library fitness_privacy;

export 'src/geo.dart' show LatLng, haversineM, bearingDeg;
export 'src/models.dart';
export 'src/privacy_zone_detector.dart';
export 'src/track_sanitizer.dart';
export 'src/heatmap.dart';
