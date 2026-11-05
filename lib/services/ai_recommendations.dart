import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/models.dart';

/// Optional Gemini free-tier personalization. The model only re-ranks real POIs.
class AiRecommendations {
  final http.Client _client;
  AiRecommendations({http.Client? client}) : _client = client ?? http.Client();

  Future<void> personalize({
    required List<Poi> places,
    required TripProfile profile,
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty || places.isEmpty) return;
    final candidates = places.take(30).map((poi) => {
      'id': poi.id,
      'name': poi.name,
      'category': poi.category,
      'detourKmApprox': double.parse(poi.distanceKm.toStringAsFixed(1)),
      'initialScore': poi.score,
    }).toList();
    final prompt = [
      'Ты эксперт по автомобильным путешествиям. Оцени только реально найденные POI.',
      'Не добавляй новые названия, места или координаты.',
      'Взрослые: ${profile.adults}; возраст детей: ${profile.childAges.join(", ")};',
      'интересы: ${profile.interests.join(", ")}; максимум отклонения от линии дороги: ${profile.detourKm} км.',
      'Отдай ТОЛЬКО JSON вида {"recommendations":[{"id":"exact input id","score":0..100,"reason":"кратко на русском"}]}.',
      'Для каждой входной точки не больше одной оценки. Не выдумывай часы работы, безопасность и доступность.',
      'Точки: ${jsonEncode(candidates)}',
    ].join('\n');
    final uri = Uri.https('generativelanguage.googleapis.com',
      '/v1beta/models/gemini-2.5-flash-lite:generateContent');
    try {
      final response = await _client.post(uri,
        headers: {
          'Content-Type': 'application/json',
          'x-goog-api-key': apiKey.trim(),
        },
        body: jsonEncode({
          'contents': [{'parts': [{'text': prompt}]}],
          'generationConfig': {'responseMimeType': 'application/json', 'temperature': 0.2},
        }),
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw StateError('ИИ недоступен: HTTP ${response.statusCode}. Проверьте ключ и лимиты бесплатного тарифа.');
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final candidatesResponse = body['candidates'] as List?;
      if (candidatesResponse == null || candidatesResponse.isEmpty) {
        throw StateError('ИИ не вернул рекомендаций.');
      }
      final parts = ((candidatesResponse.first as Map)['content'] as Map)['parts'] as List;
      final text = (parts.first as Map)['text'].toString();
      final result = jsonDecode(text) as Map<String, dynamic>;
      final proposed = result['recommendations'] as List? ?? [];
      final byId = {for (final poi in places) poi.id: poi};
      for (final item in proposed) {
        if (item is! Map) continue;
        final poi = byId[item['id']];
        if (poi == null || item['score'] is! num) continue;
        poi.aiScore = (item['score'] as num).toInt().clamp(0, 100);
        poi.aiReason = (item['reason'] ?? '').toString();
      }
      places.sort((a, b) => (b.aiScore ?? b.score).compareTo(a.aiScore ?? a.score));
    } on TimeoutException {
      throw StateError('ИИ не ответил вовремя. Использованы базовые оценки.');
    } on SocketException {
      throw StateError('Соединение с ИИ недоступно. Использованы базовые оценки.');
    } on FormatException {
      throw StateError('ИИ вернул неожиданный формат. Использованы базовые оценки.');
    } on http.ClientException {
      throw StateError('Сетевая ошибка ИИ. Использованы базовые оценки.');
    }
  }

  void dispose() => _client.close();
}
