import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'models/models.dart';
import 'services/osm_services.dart';
import 'services/ai_recommendations.dart';
import 'services/weather_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RouteMateApp());
}

class RouteMateApp extends StatelessWidget {
  const RouteMateApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'RouteMate',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff147d70)),
      useMaterial3: true,
    ),
    home: const RouteMateHome(),
  );
}

class RouteMateHome extends StatefulWidget {
  const RouteMateHome({super.key});
  @override
  State<RouteMateHome> createState() => _RouteMateHomeState();
}

class _RouteMateHomeState extends State<RouteMateHome> {
  final api = OsmServices();
  final ai = AiRecommendations();
  final weatherService = WeatherService();
  final aiKeyController = TextEditingController();
  final mapController = MapController();
  final startController = TextEditingController(text: 'Москва');
  final finishController = TextEditingController(text: 'Тверь');
  TripProfile profile = TripProfile();
  DateTime tripDate = WeatherService.day(DateTime.now());
  Map<String, TripWeather> weatherByLocation = {};
  String? weatherMessage;
  PlacePoint? start;
  PlacePoint? finish;
  RoadRoute? original;
  RoadRoute? current;
  List<Poi> places = [];
  bool busy = false;
  String status = '';
  String? error;
  int page = 0;

  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('profile');
      if (value != null) profile = TripProfile.fromJson(jsonDecode(value) as Map<String, dynamic>);
      final savedDate = prefs.getString('tripDate');
      if (savedDate != null) tripDate = DateTime.tryParse(savedDate) ?? tripDate;
      startController.text = prefs.getString('start') ?? startController.text;
      finishController.text = prefs.getString('finish') ?? finishController.text;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile', jsonEncode(profile.toJson()));
    await prefs.setString('tripDate', tripDate.toIso8601String().split('T').first);
    await prefs.setString('start', startController.text);
    await prefs.setString('finish', finishController.text);
  }

  void fail(Object exception) {
    if (!mounted) return;
    setState(() {
      error = exception is ApiException ? exception.message : 'Ошибка запроса. Проверьте подключение и повторите.';
    });
  }

  void fitRoute() {
    final points = current?.points ?? [];
    if (points.length < 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        mapController.fitCamera(CameraFit.coordinates(
          coordinates: points,
          padding: const EdgeInsets.all(32),
        ));
      } catch (_) {}
    });
  }

  Future<void> plan() async {
    if (busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      busy = true;
      status = 'Ищем точки маршрута';
      error = null;
      places = [];
      start = null;
      finish = null;
      original = null;
      current = null;
      weatherByLocation = {};
      weatherMessage = null;
    });
    try {
      final a = await api.geocode(startController.text);
      final b = await api.geocode(finishController.text);
      if (!mounted) return;
      setState(() {
        start = a;
        finish = b;
        status = 'Прокладываем дорогу';
      });
      final road = await api.route([a, b]);
      if (!mounted) return;
      setState(() {
        original = road;
        current = road;
        status = 'Находим интересные места';
      });
      fitRoute();
      await save();
      await findPlaces();
      await loadWeather();
    } catch (exception) {
      fail(exception);
    } finally {
      if (mounted) setState(() { busy = false; status = ''; });
    }
  }

  Future<void> findPlaces() async {
    if (original == null) return;
    try {
      final found = await api.searchPoi(original!, profile);
      String? aiWarning;
      if (aiKeyController.text.trim().isNotEmpty && found.isNotEmpty) {
        try {
          if (mounted) setState(() => status = 'ИИ подбирает интересные места');
          await ai.personalize(places: found, profile: profile, apiKey: aiKeyController.text);
        } catch (exception) {
          aiWarning = exception.toString();
        }
      }
      if (!mounted) return;
      setState(() { places = found; error = aiWarning; page = 1; });
    } catch (exception) {
      fail(exception);
    }
  }

  List<Poi> get chosen {
    final result = places.where((p) => p.selected).toList();
    if (original != null) {
      result.sort((a, b) => distanceFromStartKm(a.position, original!.points)
        .compareTo(distanceFromStartKm(b.position, original!.points)));
    }
    return result;
  }

  Future<void> selectPoi(Poi poi) async {
    if (busy || start == null || finish == null) return;
    final old = poi.selected;
    setState(() { busy = true; status = 'Пересчитываем дорогу'; poi.selected = !old; error = null; });
    try {
      final stops = [start!, ...chosen.map((p) => PlacePoint(p.name, p.position)), finish!];
      final route = await api.route(stops);
      if (!mounted) return;
      setState(() => current = route);
      fitRoute();
      await loadWeather();
    } catch (exception) {
      if (mounted) setState(() => poi.selected = old);
      fail(exception);
    } finally {
      if (mounted) setState(() { busy = false; status = ''; });
    }
  }

  String formatTripDate(DateTime day) => '${day.day.toString().padLeft(2, '0')}.'
    '${day.month.toString().padLeft(2, '0')}.${day.year}';

  Future<void> chooseTripDate() async {
    final today = WeatherService.day(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: tripDate.isBefore(today) ? today : tripDate,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      helpText: 'Дата поездки',
    );
    if (picked == null || !mounted) return;
    setState(() => tripDate = picked);
    await save();
    await loadWeather();
  }

  Future<void> loadWeather() async {
    if (!mounted) return;
    if (!WeatherService.isForecastDate(tripDate)) {
      setState(() {
        weatherByLocation = {};
        weatherMessage = 'Прогноз на ${formatTripDate(tripDate)} пока недоступен. '
          'Open-Meteo прогнозирует максимум на 16 дней, включая сегодня.';
      });
      return;
    }
    final candidates = <PlacePoint>[
      if (start != null) start!,
      ...chosen.take(3).map((p) => PlacePoint(p.name, p.position)),
      if (finish != null && finish!.name != start?.name) finish!,
    ];
    if (candidates.isEmpty) return;
    final updated = <String, TripWeather>{};
    var failures = 0;
    // Weather must never block POI or route display.
    for (final place in candidates) {
      try {
        updated[place.name] = await weatherService.fetch(
          location: place.name, coordinates: place.position, date: tripDate);
      } catch (_) {
        failures++;
      }
    }
    if (!mounted) return;
    setState(() {
      weatherByLocation = updated;
      weatherMessage = failures == 0 ? null :
        'Прогноз получен не для всех точек. Повторите запрос позднее.';
    });
  }

  Widget weatherSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 12),
      Text('Погода на ${formatTripDate(tripDate)}',
        style: Theme.of(context).textTheme.titleMedium),
      if (weatherMessage != null)
        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(weatherMessage!)),
      if (weatherByLocation.isEmpty && weatherMessage == null)
        const Padding(padding: EdgeInsets.all(8), child: Text('Прогноз появится после построения маршрута.')),
      ...weatherByLocation.values.map((forecast) => Card(
        child: ListTile(
          leading: Icon(forecast.weatherCode >= 61 ? Icons.umbrella_outlined :
            forecast.weatherCode <= 3 ? Icons.wb_sunny_outlined : Icons.cloud_outlined),
          title: Text(forecast.location),
          subtitle: Text('${forecast.description}; осадки до ${forecast.precipitationProbability}% · '
            'ветер до ${forecast.maxWindKmh.toStringAsFixed(0)} км/ч'),
          trailing: Text('${forecast.minC.toStringAsFixed(0)}°…${forecast.maxC.toStringAsFixed(0)}°'),
        ),
      )),
      if (weatherByLocation.isNotEmpty)
        const Text('Источник: Open-Meteo. Прогноз ориентировочный для даты, '
          'не учитывает точное время прибытия к остановке.',
          style: TextStyle(fontSize: 11)),
      TextButton.icon(
        onPressed: (start == null || finish == null) ? null : loadWeather,
        icon: const Icon(Icons.refresh), label: const Text('Обновить погоду')),
    ],
  );

  Future<void> exportTrip() async {
    if (start == null || finish == null) return;
    final list = [start!, ...chosen.map((p) => PlacePoint(p.name, p.position)), finish!];
    final coordinates = list.map((p) => '${p.position.latitude},${p.position.longitude}').join(';');
    final uri = Uri.https('www.openstreetmap.org', '/directions',
      {'engine': 'fossgis_osrm_car', 'route': coordinates});
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      fail(ApiException('Не удалось открыть навигатор.'));
    }
  }

  @override
  void dispose() {
    api.dispose();
    ai.dispose();
    weatherService.dispose();
    aiKeyController.dispose();
    mapController.dispose();
    startController.dispose();
    finishController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('RouteMate', style: TextStyle(fontWeight: FontWeight.bold)),
      actions: [IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => setState(() => page = 3))],
    ),
    body: SafeArea(child: Column(children: [
      if (busy) const LinearProgressIndicator(),
      if (busy) Padding(padding: const EdgeInsets.all(8), child: Text(status)),
      if (error != null) MaterialBanner(
        content: Text(error!),
        leading: const Icon(Icons.warning_amber_rounded),
        actions: [
          if (original != null) TextButton(
            onPressed: busy ? null : () async {
              setState(() { busy = true; error = null; });
              await findPlaces();
              if (mounted) setState(() => busy = false);
            },
            child: const Text('Повторить поиск')),
          TextButton(onPressed: () => setState(() => error = null), child: const Text('Закрыть')),
        ],
      ),
      Expanded(child: IndexedStack(index: page, children: [
        routeScreen(), placesScreen(), itineraryScreen(), profileScreen(),
      ])),
    ])),
    bottomNavigationBar: NavigationBar(
      selectedIndex: page,
      onDestinationSelected: (value) => setState(() => page = value),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.route), label: 'Маршрут'),
        NavigationDestination(icon: Icon(Icons.place_outlined), label: 'Места'),
        NavigationDestination(icon: Icon(Icons.event_note_outlined), label: 'План'),
        NavigationDestination(icon: Icon(Icons.people_outline), label: 'Профиль'),
      ],
    ),
  );

  Widget routeScreen() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text('Куда едем?', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      TextField(controller: startController,
        decoration: const InputDecoration(labelText: 'Откуда', prefixIcon: Icon(Icons.trip_origin), border: OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(controller: finishController,
        decoration: const InputDecoration(labelText: 'Куда', prefixIcon: Icon(Icons.flag_outlined), border: OutlineInputBorder())),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: chooseTripDate,
        icon: const Icon(Icons.calendar_month),
        label: Text('Дата поездки: ${formatTripDate(tripDate)}'),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: busy ? null : plan,
        icon: const Icon(Icons.auto_awesome),
        label: const Text('Построить маршрут и найти места'),
      ),
      if (current != null) ...[
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(14), child:
          Text('Дорога: ${current!.distanceKm.toStringAsFixed(0)} км · ${(current!.durationMinutes / 60).toStringAsFixed(1)} ч'))),
      ],
      weatherSection(),
      const SizedBox(height: 12),
      mapView(),
      const SizedBox(height: 4),
      const Text('© OpenStreetMap contributors', style: TextStyle(fontSize: 12)),
      if (current != null)
        OutlinedButton.icon(onPressed: exportTrip,
          icon: const Icon(Icons.open_in_new), label: const Text('Открыть маршрут в OSM')),
    ],
  );

  Widget mapView() {
    final markers = <Marker>[];
    if (start != null) markers.add(Marker(point: start!.position, width: 40, height: 40,
      child: const Icon(Icons.flag, color: Colors.green, size: 34)));
    if (finish != null) markers.add(Marker(point: finish!.position, width: 40, height: 40,
      child: const Icon(Icons.place, color: Colors.red, size: 36)));
    for (final poi in places.where((p) => !p.skipped)) {
      markers.add(Marker(point: poi.position, width: 42, height: 42,
        child: IconButton(
          icon: Icon(poi.selected ? Icons.check_circle : Icons.place,
            color: poi.selected ? Colors.teal : Colors.orange, size: 34),
          onPressed: () => showPoi(poi),
        )));
    }
    return SizedBox(height: 360, child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: FlutterMap(
        mapController: mapController,
        options: const MapOptions(initialCenter: LatLng(56.2, 36.9), initialZoom: 6),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'app.routemate.routemate',
          ),
          if (current != null) PolylineLayer(polylines: [
            Polyline(points: current!.points, strokeWidth: 5, color: Colors.blue),
          ]),
          MarkerLayer(markers: markers),
        ],
      ),
    ));
  }

  Widget placesScreen() => places.isEmpty
    ? Center(child: Padding(padding: const EdgeInsets.all(24), child:
        Text(original == null ? 'Сначала постройте маршрут.' :
          'Места пока не найдены. При необходимости повторите поиск.',
          textAlign: TextAlign.center)))
    : ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: places.where((p) => !p.skipped).length,
        itemBuilder: (context, index) {
          final poi = places.where((p) => !p.skipped).toList()[index];
          return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(poi.name, style: Theme.of(context).textTheme.titleMedium),
              Text('${poi.category} · ~${poi.distanceKm.toStringAsFixed(1)} км от линии · ${poi.visitMinutes} мин'),
              Text('Соответствие интересам: ${poi.aiScore ?? poi.score} баллов${poi.aiScore == null ? ' (правила)' : ' (ИИ)'}'),
              if (poi.aiReason != null && poi.aiReason!.isNotEmpty)
                Text('ИИ: ${poi.aiReason}'),
              Row(children: [
                Expanded(child: FilledButton.tonal(
                  onPressed: busy ? null : () => selectPoi(poi),
                  child: Text(poi.selected ? 'Убрать' : 'Добавить'))),
                TextButton(onPressed: () => setState(() => poi.skipped = true),
                  child: const Text('Пропустить')),
              ]),
            ],
          )));
        },
      );

  void showPoi(Poi poi) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(padding: const EdgeInsets.all(20), child:
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(poi.name, style: Theme.of(context).textTheme.titleLarge),
          Text('${poi.category}, ~${poi.distanceKm.toStringAsFixed(1)} км от линии маршрута'),
          const SizedBox(height: 12),
          FilledButton(onPressed: () {
            Navigator.pop(sheetContext);
            selectPoi(poi);
          }, child: Text(poi.selected ? 'Убрать остановку' : 'Добавить остановку')),
        ])),
    );
  }

  String clock(double minutes) {
    final total = (profile.departureHour * 60 + minutes.round()) % 1440;
    return '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
  }

  Widget itineraryScreen() {
    if (current == null) return const Center(child: Text('Сначала постройте поездку.'));
    final visitTime = chosen.fold<int>(0, (sum, poi) => sum + poi.visitMinutes);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('План путешествия', style: Theme.of(context).textTheme.headlineSmall),
      ListTile(leading: const Icon(Icons.play_circle), title: Text('Выезд: ${start?.name ?? ''}'),
        subtitle: Text(clock(0))),
      ...chosen.map((poi) => ListTile(
        leading: const Icon(Icons.place),
        title: Text(poi.name),
        subtitle: Text('Плановое посещение: ${poi.visitMinutes} мин'),
      )),
      ListTile(leading: const Icon(Icons.flag), title: Text('Прибытие: ${finish?.name ?? ''}'),
        subtitle: Text('Примерно в ${clock(current!.durationMinutes + visitTime)}')),
      const Text('Время приблизительное: остановки и пробки могут изменить расчёт.'),
      weatherSection(),
      FilledButton.icon(onPressed: exportTrip,
        icon: const Icon(Icons.open_in_new), label: const Text('Экспортировать маршрут')),
    ]);
  }

  Widget profileScreen() => ListView(padding: const EdgeInsets.all(18), children: [
    Text('Путешественники', style: Theme.of(context).textTheme.headlineSmall),
    ListTile(title: const Text('Взрослые'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(onPressed: () => setState(() { if (profile.adults > 1) profile.adults--; }),
          icon: const Icon(Icons.remove_circle_outline)),
        Text('${profile.adults}'),
        IconButton(onPressed: () => setState(() => profile.adults++),
          icon: const Icon(Icons.add_circle_outline)),
      ])),
    const Text('Возраст детей (лет)'),
    Wrap(spacing: 6, children: [
      ...profile.childAges.asMap().entries.map((entry) => InputChip(
        label: Text('${entry.value} лет'),
        onDeleted: () => setState(() => profile.childAges.removeAt(entry.key)),
        onPressed: () => setState(() => profile.childAges[entry.key] = (entry.value + 1) % 18),
      )),
      ActionChip(label: const Text('+ ребёнок'), onPressed: () => setState(() => profile.childAges.add(7))),
    ]),
    const SizedBox(height: 14),
    const Text('Интересы'),
    Wrap(spacing: 8, children: ['Природа', 'История', 'Детям', 'Интересное'].map((tag) =>
      FilterChip(label: Text(tag), selected: profile.interests.contains(tag),
        onSelected: (value) => setState(() {
          if (value) { profile.interests.add(tag); } else { profile.interests.remove(tag); }
        }))).toList()),
    const SizedBox(height: 12),
    Text('Отклонение от маршрута: ${profile.detourKm} км'),
    Slider(value: profile.detourKm.toDouble(), min: 1, max: 20, divisions: 19,
      label: '${profile.detourKm} км',
      onChanged: (value) => setState(() => profile.detourKm = value.round())),
    Text('Час выезда: ${profile.departureHour}:00'),
    Slider(value: profile.departureHour.toDouble(), min: 0, max: 23, divisions: 23,
      onChanged: (value) => setState(() => profile.departureHour = value.round())),
    const SizedBox(height: 18),
    const Divider(),
    Text('ИИ-рекомендации (бесплатный тариф Gemini)',
      style: Theme.of(context).textTheme.titleMedium),
    const Text('Необязательно. Введите собственный API-ключ Google AI Studio. '
      'Ключ используется только в текущем сеансе и не сохраняется. '
      'Без ключа подбор работает по правилам. Не используйте такой способ '
      'хранения ключа для публичного коммерческого приложения.'),
    const SizedBox(height: 10),
    TextField(
      controller: aiKeyController,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        labelText: 'Gemini API key',
        prefixIcon: Icon(Icons.auto_awesome),
      ),
    ),
    const SizedBox(height: 8),
    if (places.isNotEmpty)
      OutlinedButton.icon(
        icon: const Icon(Icons.auto_awesome),
        label: const Text('Обновить рекомендации с ИИ'),
        onPressed: busy ? null : () async {
          if (aiKeyController.text.trim().isEmpty) {
            fail(ApiException('Введите API-ключ Gemini в профиле.'));
            return;
          }
          setState(() { busy = true; status = 'ИИ оценивает найденные места'; error = null; });
          try {
            await ai.personalize(places: places, profile: profile, apiKey: aiKeyController.text);
            if (mounted) setState(() { places.sort((a,b) =>
              (b.aiScore ?? b.score).compareTo(a.aiScore ?? a.score)); page = 1; });
          } catch (exception) { fail(exception); }
          finally { if (mounted) setState(() { busy = false; status = ''; }); }
        },
      ),
    const SizedBox(height: 12),
    FilledButton(onPressed: () async {
      await save();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Профиль сохранён')));
    }, child: const Text('Сохранить профиль')),
  ]);
}
