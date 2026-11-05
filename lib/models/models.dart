import 'package:latlong2/latlong.dart';

class TripProfile {
  int adults;
  List<int> childAges;
  Set<String> interests;
  int detourKm;
  int departureHour;
  TripProfile({
    this.adults = 2,
    List<int>? childAges,
    Set<String>? interests,
    this.detourKm = 10,
    this.departureHour = 9,
  }) : childAges = childAges ?? [7],
       interests = interests ?? {'Природа', 'История', 'Детям'};

  Map<String, dynamic> toJson() => {
    'adults': adults,
    'childAges': childAges,
    'interests': interests.toList(),
    'detourKm': detourKm,
    'departureHour': departureHour,
  };

  factory TripProfile.fromJson(Map<String, dynamic> json) => TripProfile(
    adults: (json['adults'] as num?)?.toInt() ?? 2,
    childAges: (json['childAges'] as List? ?? [7]).map((x) => (x as num).toInt()).toList(),
    interests: (json['interests'] as List? ?? ['Природа']).map((x) => x.toString()).toSet(),
    detourKm: (json['detourKm'] as num?)?.toInt() ?? 10,
    departureHour: (json['departureHour'] as num?)?.toInt() ?? 9,
  );
}

class PlacePoint {
  final String name;
  final LatLng position;
  const PlacePoint(this.name, this.position);
}

class RoadRoute {
  final List<LatLng> points;
  final double distanceKm;
  final double durationMinutes;
  const RoadRoute({required this.points, required this.distanceKm, required this.durationMinutes});
}

class Poi {
  final String id;
  final String name;
  final LatLng position;
  final String category;
  final double distanceKm;
  final int score;
  final int visitMinutes;
  int? aiScore;
  String? aiReason;
  bool selected;
  bool skipped;
  Poi({required this.id, required this.name, required this.position,
    required this.category, required this.distanceKm, required this.score,
    required this.visitMinutes, this.selected = false, this.skipped = false});
}

String categoryFor(Map<String, String> tags) {
  if (tags['leisure'] == 'playground' || tags['tourism'] == 'zoo' || tags['tourism'] == 'theme_park') return 'Детям';
  if (tags.containsKey('historic') || tags['tourism'] == 'museum') return 'История';
  if (tags.containsKey('natural') || tags['leisure'] == 'park' || tags['tourism'] == 'viewpoint') return 'Природа';
  return 'Интересное';
}

int visitDuration(String category) => category == 'Детям' ? 90 : category == 'История' ? 75 : 45;

int scorePoi(Map<String, String> tags, TripProfile profile, double detourKm) {
  final category = categoryFor(tags);
  var score = 30 - detourKm.round() * 2;
  if (profile.interests.contains(category)) score += 100;
  if (profile.childAges.isNotEmpty && category == 'Детям') score += 100;
  if (profile.childAges.any((age) => age <= 3) && tags['wheelchair'] == 'yes') score += 20;
  return score;
}

double distanceToRouteKm(LatLng p, List<LatLng> route) {
  if (route.isEmpty) return double.infinity;
  const distance = Distance();
  var best = double.infinity;
  for (final point in route) {
    final value = distance.as(LengthUnit.Kilometer, p, point);
    if (value < best) best = value;
  }
  return best;
}

double distanceFromStartKm(LatLng p, List<LatLng> route) {
  if (route.isEmpty) return 0;
  const distance = Distance();
  var cumulative = 0.0;
  var best = double.infinity;
  var closestDistance = 0.0;
  for (var i = 0; i < route.length; i++) {
    final d = distance.as(LengthUnit.Kilometer, p, route[i]);
    if (d < best) {
      best = d;
      closestDistance = cumulative;
    }
    if (i + 1 < route.length) cumulative += distance.as(LengthUnit.Kilometer, route[i], route[i + 1]);
  }
  return closestDistance;
}

/// Equally spaced positions along the WHOLE polyline, including the finish.
/// Public API sampling is bounded; a production-quality corridor needs PostGIS.
List<LatLng> routeSamples(List<LatLng> route, {int maxSamples = 12}) {
  if (route.length <= 1 || maxSamples < 2) return route.take(1).toList();
  const distance = Distance();
  final totals = <double>[0];
  for (var i = 1; i < route.length; i++) {
    totals.add(totals.last + distance.as(LengthUnit.Kilometer, route[i - 1], route[i]));
  }
  if (totals.last == 0) return [route.first];
  final result = <LatLng>[route.first];
  var cursor = 1;
  for (var index = 1; index < maxSamples - 1; index++) {
    final target = totals.last * index / (maxSamples - 1);
    while (cursor < totals.length - 1 && totals[cursor] < target) cursor++;
    if (route[cursor] != result.last) result.add(route[cursor]);
  }
  if (route.last != result.last) result.add(route.last);
  return result;
}
