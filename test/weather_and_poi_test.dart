import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:routemate/models/models.dart';
import 'package:routemate/services/weather_service.dart';

void main() {
  test('samples cover start and finish of a long route', () {
    final route = List.generate(101, (i) => LatLng(55.0, 30 + i / 10));
    final samples = routeSamples(route, maxSamples: 12);
    expect(samples.first, route.first);
    expect(samples.last, route.last);
    expect(samples.length, greaterThanOrEqualTo(10));
    expect(samples.length, lessThanOrEqualTo(12));
  });

  test('weather is unavailable beyond 16 forecast days', () {
    final today = DateTime(2026, 11, 5);
    expect(WeatherService.isForecastDate(today, now: today), isTrue);
    expect(WeatherService.isForecastDate(today.add(const Duration(days: 15)), now: today), isTrue);
    expect(WeatherService.isForecastDate(today.add(const Duration(days: 16)), now: today), isFalse);
  });

  test('Open-Meteo forecast is parsed for selected date', () async {
    final date = WeatherService.day(DateTime.now()).add(const Duration(days: 2));
    final selected = '${date.year.toString().padLeft(4,'0')}-${date.month.toString().padLeft(2,'0')}-${date.day.toString().padLeft(2,'0')}';
    final service = WeatherService(client: MockClient((request) async {
      expect(request.url.host, 'api.open-meteo.com');
      expect(request.url.queryParameters['start_date'], selected);
      expect(request.url.queryParameters['end_date'], selected);
      return http.Response(jsonEncode({
        'daily': {
          'time': [selected],
          'weather_code': [61],
          'temperature_2m_min': [4.2],
          'temperature_2m_max': [10.6],
          'precipitation_probability_max': [75],
          'wind_speed_10m_max': [21.0],
        }
      }), 200);
    }));
    final value = await service.fetch(
      location: 'Тверь', coordinates: const LatLng(56.85, 35.91), date: date);
    expect(value.description, 'Дождь');
    expect(value.minC, 4.2);
    expect(value.maxC, 10.6);
    expect(value.precipitationProbability, 75);
    service.dispose();
  });
}
