import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/models.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override String toString() => message;
}

class OsmServices {
  final http.Client _client;
  OsmServices({http.Client? client}) : _client = client ?? http.Client();

  static const _headers = <String, String>{
    'User-Agent': 'RouteMateMVP/0.2 (https://github.com/Shkazzz/RouteMate)',
    'Accept': 'application/json',
  };
  DateTime _lastGeocode = DateTime.fromMillisecondsSinceEpoch(0);

  Future<dynamic> _request(Uri uri, {String? postBody, Duration timeout = const Duration(seconds: 20)}) async {
    try {
      final http.Response response;
      if (postBody == null) {
        response = await _client.get(uri, headers: _headers).timeout(timeout);
      } else {
        response = await _client.post(uri,
          headers: {..._headers, 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'},
          body: {'data': postBody}).timeout(timeout);
      }
      if (response.statusCode == 429) throw ApiException('Сервис ограничил частоту запросов (429). Повторите позже.');
      if (response.statusCode >= 500) throw ApiException('Сервер временно недоступен (HTTP ${response.statusCode}).');
      if (response.statusCode != 200) throw ApiException('Ошибка HTTP ${response.statusCode}.');
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on TimeoutException {
      throw ApiException('Превышено время ожидания ответа картографического сервера.');
    } on SocketException {
      throw ApiException('Нет подключения к серверу. Проверьте интернет или DNS.');
    } on HandshakeException {
      throw ApiException('Ошибка безопасного соединения с картографическим сервером.');
    } on FormatException {
      throw ApiException('Картографический сервер вернул некорректный ответ.');
    } on http.ClientException catch (error) {
      throw ApiException('Сетевая ошибка: ${error.message}');
    }
  }

  Future<PlacePoint> geocode(String query) async {
    if (query.trim().length < 2) throw ApiException('Введите город или адрес.');
    final delay = const Duration(milliseconds: 1100) - DateTime.now().difference(_lastGeocode);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    _lastGeocode = DateTime.now();
    final uri = Uri.https('nominatim.openstreetmap.org', '/search',
      {'q': query.trim(), 'format': 'jsonv2', 'limit': '1'});
    final data = await _request(uri);
    if (data is! List || data.isEmpty) throw ApiException('Адрес «$query» не найден.');
    final item = data.first as Map;
    return PlacePoint(query, LatLng(double.parse(item['lat'].toString()), double.parse(item['lon'].toString())));
  }

  Future<RoadRoute> route(List<PlacePoint> stops) async {
    if (stops.length < 2) throw ApiException('Укажите начало и конец маршрута.');
    final points = stops.map((p) => '${p.position.longitude},${p.position.latitude}').join(';');
    final uri = Uri.parse('https://routing.openstreetmap.de/routed-car/route/v1/driving/$points?overview=full&geometries=geojson&steps=false');
    final data = await _request(uri, timeout: const Duration(seconds: 35));
    if (data is! Map || data['code'] != 'Ok' || data['routes'] is! List || (data['routes'] as List).isEmpty) {
      throw ApiException('Автомобильный маршрут не найден.');
    }
    final found = (data['routes'] as List).first as Map;
    final shape = ((found['geometry'] as Map)['coordinates'] as List)
      .map((xy) => LatLng((xy[1] as num).toDouble(), (xy[0] as num).toDouble())).toList();
    return RoadRoute(points: shape, distanceKm: (found['distance'] as num).toDouble() / 1000,
      durationMinutes: (found['duration'] as num).toDouble() / 60);
  }

  Future<List<Poi>> searchPoi(RoadRoute route, TripProfile profile) async {
    if (route.points.isEmpty) return [];
    // Cap Overpass work: a handful of geographically distributed points, not a giant query.
    const distance = Distance();
    final spacingKm = math.max(20.0, profile.detourKm.toDouble() * 2);
    final samples = <LatLng>[route.points.first];
    var accrued = 0.0;
    for (var i = 1; i < route.points.length; i++) {
      accrued += distance.as(LengthUnit.Kilometer, route.points[i - 1], route.points[i]);
      if (accrued >= spacingKm && samples.length < 6) {
        samples.add(route.points[i]);
        accrued = 0;
      }
    }
    if (samples.length < 6 && samples.last != route.points.last) samples.add(route.points.last);
    final radius = (profile.detourKm * 1000).clamp(1000, 12000);
    final collected = <Poi>[];
    final seen = <String>{};
    final hosts = ['overpass.kumi.systems', 'overpass.nchc.org.tw', 'overpass-api.de'];
    var successfulBatches = 0;
    Object? lastError;

    // Small queries and failover. Partial results are acceptable in MVP.
    for (var offset = 0; offset < samples.length; offset += 3) {
      final batch = samples.skip(offset).take(3);
      final clauses = <String>[];
      for (final p in batch) {
        final around = '(around:$radius,${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)})';
        clauses.add('nwr["tourism"~"museum|attraction|viewpoint|zoo|theme_park"]$around;');
        clauses.add('nwr["historic"]$around;');
        clauses.add('nwr["natural"~"waterfall|peak|beach|spring"]$around;');
        clauses.add('nwr["leisure"~"park|playground"]$around;');
      }
      final query = '[out:json][timeout:15];(${clauses.join()});out center 80;';
      dynamic data;
      for (final host in hosts) {
        try {
          data = await _request(Uri.https(host, '/api/interpreter'),
            postBody: query, timeout: const Duration(seconds: 8));
          if (data is Map && data['elements'] is List) break;
          data = null;
        } catch (error) { lastError = error; }
      }
      if (data is! Map || data['elements'] is! List) continue;
      successfulBatches++;
      for (final raw in data['elements'] as List) {
        if (raw is! Map) continue;
        final tags = (raw['tags'] as Map? ?? {}).map<String, String>((key, value) => MapEntry(key.toString(), value.toString()));
        final name = tags['name:ru'] ?? tags['name'];
        final pointData = raw['center'] is Map ? raw['center'] as Map : raw;
        if (name == null || name.isEmpty || pointData['lat'] is! num || pointData['lon'] is! num) continue;
        final position = LatLng((pointData['lat'] as num).toDouble(), (pointData['lon'] as num).toDouble());
        final km = distanceToRouteKm(position, route.points);
        if (km > profile.detourKm + 1) continue;
        final id = '${raw['type']}/${raw['id']}';
        if (!seen.add(id)) continue;
        final category = categoryFor(tags);
        collected.add(Poi(id: id, name: name, position: position, category: category,
          distanceKm: km, score: scorePoi(tags, profile, km), visitMinutes: visitDuration(category)));
      }
    }
    // Wikipedia geosearch is an independent POI fallback, not an AI model.
    // It returns real geotagged articles even when public Overpass gives HTTP 502.
    if (collected.length < 12) {
      for (final point in samples.take(6)) {
        try {
          final data = await _request(Uri.https('ru.wikipedia.org', '/w/api.php', {
            'action': 'query',
            'list': 'geosearch',
            'gscoord': '${point.latitude.toStringAsFixed(5)}|${point.longitude.toStringAsFixed(5)}',
            'gsradius': (profile.detourKm * 1000).clamp(1000, 10000).toString(),
            'gslimit': '20',
            'format': 'json',
          }), timeout: const Duration(seconds: 8));
          final found = ((data as Map)['query'] as Map?)?['geosearch'] as List? ?? [];
          for (final entry in found) {
            if (entry is! Map || entry['lat'] is! num || entry['lon'] is! num) continue;
            final id = 'wiki/${entry['pageid']}';
            if (seen.contains(id)) continue;
            final position = LatLng((entry['lat'] as num).toDouble(), (entry['lon'] as num).toDouble());
            final km = distanceToRouteKm(position, route.points);
            if (km > profile.detourKm + 1) continue;
            seen.add(id);
            final name = (entry['title'] ?? '').toString();
            if (name.isEmpty) continue;
            collected.add(Poi(id: id, name: name, position: position,
              category: 'История', distanceKm: km,
              score: 30 + (profile.interests.contains('История') ? 100 : 0) - km.round() * 2,
              visitMinutes: 60));
          }
        } catch (error) {
          lastError = error;
        }
      }
    }
    collected.sort((a, b) => b.score.compareTo(a.score));
    if (collected.isEmpty && successfulBatches == 0) {
      throw ApiException('Сервисы поиска мест не ответили (Overpass и Wikipedia). Маршрут остаётся на карте. ${lastError ?? ''}');
    }
    return collected.take(40).toList();
  }

  void dispose() => _client.close();
}
