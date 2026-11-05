# RouteMate MVP

Flutter-приложение для автомобильных поездок: маршрут А→Б, персональные интересы, дети, поиск интересных мест вдоль дороги, выбор остановок, пересчёт времени и экспорт в OpenStreetMap.

## Сборка APK в GitHub

Откройте **Actions → Build RouteMate Android APK → Run workflow**. После успешного выполнения скачайте артефакт **RouteMate-debug-APK**. Это тестовая APK-сборка (не подписанная для публикации в магазине).

## Запуск локально

Установите Flutter SDK и Android SDK. В корне репозитория:

```bash
flutter create . --project-name routemate --org app.routemate --platforms android,ios
flutter pub get
flutter test
flutter run
```

Шаблонные каталоги платформ (Android/iOS) **генерируются Flutter**, а не хранятся как неполные ручные заглушки. Существуют каталоги `lib/`, `lib/models/`, `lib/services/`, `test/`, `.github/workflows/`. Скрипт CI автоматически добавляет разрешение Android `INTERNET` для release/debug APK.

## Бесплатные сервисы и ограничения

- OpenStreetMap + `flutter_map`: карта, attribution.
- Nominatim: геокодирование; соблюдаем ограничение частоты запросов.
- OSRM routing.openstreetmap.de: построение маршрута.
- Overpass: поиск POI небольшими партиями с запасными endpoints.

Эти публичные ресурсы работают без платных API-ключей, но имеют ограничения доступности и нагрузки. Не использовать как гарантию продакшен-сервиса. Часы работы и автомобильное время отклонения в MVP не подтверждаются; расстояние от точки до маршрута приблизительное. Для коммерческой версии рекомендуется собственный сервер с PostGIS/OSM extract.

При временном отказе Overpass приложение оставляет основной маршрут, показывает понятную ошибку и разрешает повторить поиск.

## Состав

- `lib/main.dart` — интерфейс.
- `lib/models/models.dart` — профиль и рейтинг.
- `lib/services/osm_services.dart` — геокодирование, маршруты и поиск POI.
- `test/models_test.dart` — базовые тесты.
- `.github/workflows/android-apk.yml` — сборка APK.

Статус: исходный MVP, GitHub Actions сборка ещё должна пройти успешно, после чего проверить приложение на телефоне.
