import 'dart:convert';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

/// Stores previously retrieved real POIs. Cache never fabricates coordinates.
class PoiCache {
  static const _prefix = 'poi_cache_v1_';
  static const _ttl = Duration(days: 14);

  Future<void> save(String key, List<Poi> pois) async {
    if (pois.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'pois': pois.take(50).map((p) => {
        'id': p.id, 'name': p.name, 'lat': p.position.latitude,
        'lon': p.position.longitude, 'category': p.category,
        'distanceKm': p.distanceKm, 'score': p.score,
        'visitMinutes': p.visitMinutes,
      }).toList(),
    };
    await prefs.setString('$_prefix$key', jsonEncode(data));
  }

  Future<List<Poi>> load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$key');
      if (raw == null) return [];
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = DateTime.parse(data['savedAt'] as String);
      if (DateTime.now().toUtc().difference(savedAt) > _ttl) return [];
      final entries = data['pois'] as List;
      return entries.map((item) {
        final p = item as Map<String, dynamic>;
        return Poi(
          id: p['id'] as String,
          name: p['name'] as String,
          position: LatLng((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble()),
          category: p['category'] as String,
          distanceKm: (p['distanceKm'] as num).toDouble(),
          score: (p['score'] as num).toInt(),
          visitMinutes: (p['visitMinutes'] as num).toInt(),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
