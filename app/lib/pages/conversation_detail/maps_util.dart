import 'dart:io';

import 'package:map_launcher/map_launcher.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:omi/env/env.dart';

/// Источник картинки карты для страницы разговора.
///
/// Google Static Maps требует ключ и включённый биллинг, и в странах, где Google
/// Maps не основной картограф, он же не самый полезный. Поэтому источник выбирается,
/// а не зашит: без ключа берётся OpenStreetMap, который работает вообще без
/// регистрации, поэтому карта не остаётся пустой рамкой «не удалось загрузить».
enum MapProvider {
  /// OpenStreetMap — без ключа и без биллинга, работает везде.
  openStreetMap,

  /// Яндекс.Карты — подробнее в России и СНГ; нужен бесплатный ключ Static API.
  yandex,

  /// Google — тёмная тема и стилизация, нужен ключ с включённым биллингом.
  google,
}

class MapsUtil {
  /// Что использовать. По умолчанию — источник, для которого ничего не нужно
  /// настраивать: пустая карта хуже простой карты.
  static MapProvider provider = _fromEnv();

  static MapProvider _fromEnv() {
    // Позволяет выбрать картограф на сборке, не трогая код:
    // --dart-define=OMI_MAP_PROVIDER=yandex|google|osm
    const raw = String.fromEnvironment('OMI_MAP_PROVIDER', defaultValue: 'osm');
    switch (raw.toLowerCase()) {
      case 'yandex':
        return MapProvider.yandex;
      case 'google':
        return MapProvider.google;
      default:
        return MapProvider.openStreetMap;
    }
  }

  static String getMapImageUrl(double lat, double lng) {
    switch (provider) {
      case MapProvider.openStreetMap:
        return _openStreetMapUrl(lat, lng);
      case MapProvider.yandex:
        return _yandexUrl(lat, lng);
      case MapProvider.google:
        return _googleUrl(lat, lng);
    }
  }

  /// Карта без единого ключа. Публичный staticmap.openstreetmap.de оказался мёртв
  /// (соединение не устанавливается), поэтому берём давнюю схему Яндекса — она
  /// отдаёт PNG без авторизации и покрывает мир целиком.
  static String _openStreetMapUrl(double lat, double lng) => _yandexLegacyUrl(lat, lng);

  /// Яндекс.Карты. Ключ нужен только новому Static API (`/v1`); прежняя схема
  /// `/1.x/` работает без него, поэтому при пустом ключе не падаем в ошибку, а
  /// просто идём этим путём. У Яндекса порядок координат обратный: долгота,широта.
  static String _yandexUrl(double lat, double lng) {
    final key = Env.yandexMapsApiKey;
    if (key == null || key.isEmpty) {
      return _yandexLegacyUrl(lat, lng);
    }
    return "https://static-maps.yandex.ru/v1"
        "?ll=$lng,$lat&z=15&size=650,450&lang=ru_RU&apikey=$key"
        "&pt=$lng,$lat,pm2rdm";
  }

  static String _yandexLegacyUrl(double lat, double lng) {
    return "https://static-maps.yandex.ru/1.x/"
        "?ll=$lng,$lat&z=15&size=650,450&l=map&pt=$lng,$lat,pm2rdm";
  }

  static String _googleUrl(double lat, double lng) {
    // Dark theme Google Maps with minimal labels
    const String baseUrl = "https://maps.googleapis.com/maps/api/staticmap";
    final String center = "center=$lat,$lng";
    const String zoom = "zoom=15";
    const String size = "size=800x500";
    const String scale = "scale=2";
    const String format = "format=png";

    // Custom marker styling
    final String marker = "markers=color:0x9C27B0%7Clabel:%20%7C$lat,$lng";

    final String styles = [
      // Base geometry
      "style=element:geometry%7Ccolor:0x1a1a1a",
      // Hide icons
      "style=element:labels.icon%7Cvisibility:off",
      // Text styling
      "style=element:labels.text.fill%7Ccolor:0x4a4a4a",
      "style=element:labels.text.stroke%7Ccolor:0x1a1a1a",
      // Hide administrative labels
      "style=feature:administrative%7Celement:geometry%7Cvisibility:off",
      "style=feature:administrative%7Celement:labels%7Cvisibility:off",
      "style=feature:administrative.locality%7Celement:labels.text.fill%7Ccolor:0x8a8a8a",
      "style=feature:administrative.neighborhood%7Cvisibility:off",
      "style=feature:administrative.land_parcel%7Cvisibility:off",
      // Hide POI labels
      "style=feature:poi%7Celement:labels%7Cvisibility:off",
      "style=feature:poi.business%7Cvisibility:off",
      "style=feature:poi.government%7Cvisibility:off",
      "style=feature:poi.medical%7Cvisibility:off",
      "style=feature:poi.place_of_worship%7Cvisibility:off",
      "style=feature:poi.school%7Cvisibility:off",
      "style=feature:poi.sports_complex%7Cvisibility:off",
      // Parks
      "style=feature:poi.park%7Celement:geometry%7Ccolor:0x263c3f",
      "style=feature:poi.park%7Celement:labels.text%7Cvisibility:simplified",
      "style=feature:poi.park%7Celement:labels.text.fill%7Ccolor:0x5a7a5f",
      // Roads
      "style=feature:road%7Celement:geometry%7Ccolor:0x2c2c2c",
      "style=feature:road%7Celement:labels%7Cvisibility:simplified",
      "style=feature:road%7Celement:labels.text.fill%7Ccolor:0x6a6a6a",
      "style=feature:road.arterial%7Celement:geometry%7Ccolor:0x373737",
      "style=feature:road.arterial%7Celement:labels%7Cvisibility:off",
      "style=feature:road.highway%7Celement:geometry%7Ccolor:0x444444",
      "style=feature:road.highway%7Celement:labels.text.fill%7Ccolor:0x8a8a8a",
      "style=feature:road.highway.controlled_access%7Celement:geometry%7Ccolor:0x555555",
      "style=feature:road.local%7Celement:labels%7Cvisibility:off",
      // Hide transit labels
      "style=feature:transit%7Celement:labels%7Cvisibility:off",
      // Water
      "style=feature:water%7Celement:geometry%7Ccolor:0x0e1626",
      "style=feature:water%7Celement:labels.text.fill%7Ccolor:0x3d5a5d",
      "style=feature:water%7Celement:labels.text%7Cvisibility:simplified",
    ].join("&");

    final String key = "key=${Env.googleMapsApiKey}";

    return "$baseUrl?$center&$zoom&$size&$scale&$format&$marker&$styles&$key";
  }

  static String getGoogleMapsPlaceUrl(String googlePlaceId) {
    return "https://www.google.com/maps/place/?q=place_id=$googlePlaceId";
  }

  static void launchMap(double lat, double lng) async {
    // Открывать точку в том же сервисе, картинку которого человек только что видел:
    // тап по Яндекс-карте, уводящий в Google Maps, выглядит поломкой.
    try {
      final preferred = _preferredMapTypes();
      for (final type in preferred) {
        if (await MapLauncher.isMapAvailable(type) == true) {
          await MapLauncher.showMarker(mapType: type, coords: Coords(lat, lng), title: '');
          return;
        }
      }
      final installed = await MapLauncher.installedMaps;
      if (installed.isNotEmpty) {
        await installed.first.showMarker(coords: Coords(lat, lng), title: '');
        return;
      }
    } catch (_) {}
    await launchUrl(Uri.parse(_webFallbackUrl(lat, lng)), mode: LaunchMode.externalApplication);
  }

  /// Приложения карт в порядке предпочтения — сначала выбранный источник.
  static List<MapType> _preferredMapTypes() {
    final platformDefault = Platform.isIOS ? MapType.apple : MapType.google;
    switch (provider) {
      case MapProvider.yandex:
        return [MapType.yandexMaps, MapType.yandexNavi, platformDefault];
      case MapProvider.openStreetMap:
      case MapProvider.google:
        return [platformDefault];
    }
  }

  /// Если ни одного приложения карт нет — открываем в браузере, тоже в выбранном сервисе.
  static String _webFallbackUrl(double lat, double lng) {
    switch (provider) {
      case MapProvider.yandex:
        return 'https://yandex.ru/maps/?pt=$lng,$lat&z=16&l=map';
      case MapProvider.openStreetMap:
        return 'https://www.openstreetmap.org/?mlat=$lat&mlon=$lng#map=16/$lat/$lng';
      case MapProvider.google:
        return 'https://www.google.com/maps/search/?api=1&query=$lat,$lng';
    }
  }
}
