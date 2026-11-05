import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:routemate/models/models.dart';
import 'package:routemate/services/osm_services.dart';
import 'package:routemate/services/poi_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real Wikipedia POI is returned when Overpass fails', () async {
    var wikipediaRequests = 0;
    final service = OsmServices(client: MockClient((request) async {
      if (request.url.host.contains('overpass')) {
        return http.Response('bad gateway', 502);
      }
      if (request.url.host == 'ru.wikipedia.org') {
        wikipediaRequests++;
        expect(request.url.queryParameters['origin'], '*');
        return http.Response(jsonEncode({
          'query': { 'geosearch': [
            {'pageid': 12345, 'title': 'Памятник у дороги', 'lat': 55.75, 'lon': 37.6}
          ] }
        }), 200);
      }
      return http.Response('not found', 404);
    }));
    final road = RoadRoute(
      points: [const LatLng(55.75, 37.6), const LatLng(55.77, 37.62)],
      distanceKm: 3,
      durationMinutes: 8,
    );
    final found = await service.searchPoi(road, TripProfile(detourKm: 10));
    expect(found, hasLength(1));
    expect(found.first.name, 'Памятник у дороги');
    expect(wikipediaRequests, greaterThan(0));
    service.dispose();
  });

  test('successful real POI results survive cache roundtrip', () async {
    SharedPreferences.setMockInitialValues({});
    final cache = PoiCache();
    final input = [Poi(
      id: 'wiki/123', name: 'Достопримечательность',
      position: const LatLng(55.7, 37.6), category: 'Интересное',
      distanceKm: 2, score: 80, visitMinutes: 45,
    )];
    await cache.save('test_route', input);
    final restored = await cache.load('test_route');
    expect(restored, hasLength(1));
    expect(restored.first.id, 'wiki/123');
    expect(restored.first.position.latitude, 55.7);
  });
}
