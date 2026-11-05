import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class TripWeather {
  final String location;
  final DateTime date;
  final int weatherCode;
  final double minC;
  final double maxC;
  final int precipitationProbability;
  final double maxWindKmh;

  const TripWeather({
    required this.location,
    required this.date,
    required this.weatherCode,
    required this.minC,
    required this.maxC,
    required this.precipitationProbability,
    required this.maxWindKmh,
  });

  String get description {
    if (weatherCode == 0) return 'Ясно';
    if (weatherCode <= 3) return 'Переменная облачность';
    if (weatherCode == 45 || weatherCode == 48) return 'Туман';
    if ([51, 53, 55, 56, 57].contains(weatherCode)) return 'Морось';
    if ([61, 63, 65, 66, 67, 80, 81, 82].contains(weatherCode)) return 'Дождь';
    if ([71, 73, 75, 77, 85, 86].contains(weatherCode)) return 'Снег';
    if (weatherCode >= 95) return 'Гроза';
    return 'Осадки возможны';
  }
}

class WeatherService {
  final http.Client client;
  WeatherService({http.Client? client}) : client = client ?? http.Client();

  static DateTime day(DateTime value) => DateTime(value.year, value.month, value.day);

  static bool isForecastDate(DateTime date, {DateTime? now}) {
    final today = day(now ?? DateTime.now());
    final delta = day(date).difference(today).inDays;
    // Open-Meteo provides a maximum of 16 days, including the current day.
    return delta >= 0 && delta < 16;
  }

  Future<TripWeather> fetch({
    required String location,
    required LatLng coordinates,
    required DateTime date,
  }) async {
    if (!isForecastDate(date)) {
      throw StateError('Прогноз пока недоступен: погода рассчитывается на ближайшие 16 дней.');
    }
    final selected = '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': coordinates.latitude.toStringAsFixed(5),
      'longitude': coordinates.longitude.toStringAsFixed(5),
      'daily': 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max',
      'timezone': 'auto',
      'start_date': selected,
      'end_date': selected,
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Погода: HTTP ${response.statusCode}');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map || body['daily'] is! Map) {
      throw const FormatException('Нет данных прогноза');
    }
    final daily = body['daily'] as Map;
    num firstNumber(String key) {
      final list = daily[key];
      if (list is! List || list.isEmpty || list.first is! num) {
        throw FormatException('Погода: отсутствует $key');
      }
      return list.first as num;
    }
    if (daily['time'] is! List || (daily['time'] as List).isEmpty ||
        (daily['time'] as List).first != selected) {
      throw const FormatException('Погода: дата ответа не совпадает');
    }
    return TripWeather(
      location: location,
      date: day(date),
      weatherCode: firstNumber('weather_code').toInt(),
      maxC: firstNumber('temperature_2m_max').toDouble(),
      minC: firstNumber('temperature_2m_min').toDouble(),
      precipitationProbability: firstNumber('precipitation_probability_max').toInt(),
      maxWindKmh: firstNumber('wind_speed_10m_max').toDouble(),
    );
  }

  void dispose() => client.close();
}
