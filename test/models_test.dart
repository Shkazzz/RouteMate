import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:routemate/models/models.dart';

void main() {
  test('child-friendly locations rank higher', () {
    final profile = TripProfile(childAges: [7], interests: {'Природа'});
    final zoo = scorePoi({'tourism': 'zoo'}, profile, 2);
    final museum = scorePoi({'tourism': 'museum'}, profile, 2);
    expect(zoo, greaterThan(museum));
  });
  test('profile roundtrip', () {
    final profile = TripProfile(childAges: [3, 12], detourKm: 15);
    final restored = TripProfile.fromJson(profile.toJson());
    expect(restored.childAges, [3, 12]);
    expect(restored.detourKm, 15);
  });
  test('distance is zero for a route point', () {
    expect(distanceToRouteKm(const LatLng(55.75, 37.6), [const LatLng(55.75, 37.6)]), closeTo(0, 0.001));
  });
}
