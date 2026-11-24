import 'dart:math';

/// 经纬度坐标(WGS84)。
class LatLng {
  final double lat;
  final double lon;
  const LatLng(this.lat, this.lon);

  @override
  String toString() => '(${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)})';
}

const double _earthRadiusM = 6371000.0;

double _rad(double deg) => deg * pi / 180.0;

/// 两点间大圆距离(米)。
double haversineM(LatLng a, LatLng b) {
  final dLat = _rad(b.lat - a.lat);
  final dLon = _rad(b.lon - a.lon);
  final h = sin(dLat / 2) * sin(dLat / 2) +
      cos(_rad(a.lat)) * cos(_rad(b.lat)) * sin(dLon / 2) * sin(dLon / 2);
  return 2 * _earthRadiusM * asin(min(1.0, sqrt(h)));
}

/// 从 a 指向 b 的方位角(度,0=北,顺时针)。
double bearingDeg(LatLng a, LatLng b) {
  final lat1 = _rad(a.lat);
  final lat2 = _rad(b.lat);
  final dLon = _rad(b.lon - a.lon);
  final y = sin(dLon) * cos(lat2);
  final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
  return (atan2(y, x) * 180.0 / pi + 360.0) % 360.0;
}

/// 两个方位角的最小夹角,范围 [-180, 180]。
double angleDiffDeg(double a, double b) => (a - b + 540.0) % 360.0 - 180.0;

/// 射线法判断点是否在多边形内(用于敏感区域屏蔽)。
bool pointInPolygon(LatLng p, List<LatLng> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i];
    final b = polygon[j];
    final crosses = (a.lon > p.lon) != (b.lon > p.lon);
    if (crosses) {
      final latAtLon =
          a.lat + (p.lon - a.lon) * (b.lat - a.lat) / (b.lon - a.lon);
      if (p.lat < latAtLon) inside = !inside;
    }
  }
  return inside;
}
