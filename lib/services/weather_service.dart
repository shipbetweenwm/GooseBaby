import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/http_client.dart';

/// 天气数据模型
class WeatherInfo {
  final double temperature;     // 温度 (摄氏度)
  final double feelsLike;       // 体感温度
  final int humidity;           // 湿度 (%)
  final double windSpeed;       // 风速 (km/h)
  final String description;     // 天气描述（中文）
  final String icon;            // 天气图标
  final int code;               // 天气代码
  final bool isDay;             // 是否白天
  final String city;            // 城市名

  const WeatherInfo({
    this.temperature = 20,
    this.feelsLike = 20,
    this.humidity = 50,
    this.windSpeed = 10,
    this.description = '晴',
    this.icon = '☀️',
    this.code = 0,
    this.isDay = true,
    this.city = '未知',
  });

  /// 是否极端天气
  bool get isExtreme =>
      temperature > 38 ||
      temperature < -5 ||
      windSpeed > 60 ||
      (code >= 95 && code <= 99); // 雷暴

  /// 是否需要带伞
  bool get needUmbrella => code >= 51 && code <= 67; // 各种雨

  /// 是否寒冷
  bool get isCold => temperature < 10;

  /// 是否炎热
  bool get isHot => temperature > 32;

  /// 是否适合外出
  bool get isGoodWeather =>
      !isExtreme && !needUmbrella && temperature >= 15 && temperature <= 30;

  /// 天气相关的建议（短文本）
  String get advice {
    if (isExtreme) return '外面天气很恶劣，主人最好别出门';
    if (needUmbrella) return '外面在下雨，主人出门记得带伞';
    if (isCold) return '外面好冷，主人多穿点衣服';
    if (isHot) return '外面好热，主人注意防暑降温';
    if (isGoodWeather) return '外面天气很好，适合出门走走';
    return '';
  }

  /// 简要天气描述
  String get brief => '$city $temperature°C $description';
}

/// 天气服务 — 使用 Open-Meteo 免费API（无需API Key）
class WeatherService {
  static WeatherService? _instance;
  static WeatherService get instance => _instance ??= WeatherService._();
  WeatherService._();

  WeatherInfo? _cachedWeather;
  DateTime? _lastFetch;
  String? _cachedCity;

  /// 缓存有效期（30分钟）
  static const _cacheDuration = Duration(minutes: 30);

  /// 获取当前天气（带缓存）
  Future<WeatherInfo?> getWeather() async {
    // 检查缓存
    if (_cachedWeather != null &&
        _lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < _cacheDuration) {
      return _cachedWeather;
    }

    try {
      // 先通过 IP 获取大致位置
      final coords = await _getLocationByIP();
      if (coords == null) {
        debugPrint('🌤️ 无法获取位置，使用默认天气');
        return _buildFallbackWeather();
      }

      // 查询天气
      final weather = await _fetchWeather(coords['lat']!, coords['lon']!);
      _cachedWeather = weather;
      _lastFetch = DateTime.now();
      return weather;
    } catch (e) {
      debugPrint('🌤️ 获取天气失败: $e');
      return _cachedWeather ?? _buildFallbackWeather();
    }
  }

  /// 强制刷新天气（忽略缓存）
  Future<WeatherInfo?> refreshWeather() async {
    _lastFetch = null;
    return getWeather();
  }

  /// 通过 IP 获取经纬度
  Future<Map<String, double>?> _getLocationByIP() async {
    try {
      final response = await HttpClient.instance.get(
        'https://ipapi.co/json/',
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        _cachedCity = data['city'] as String? ?? '未知';
        return {
          'lat': (data['latitude'] as num).toDouble(),
          'lon': (data['longitude'] as num).toDouble(),
        };
      }
      return null;
    } catch (e) {
      debugPrint('🌤️ IP定位失败: $e');
      // 尝试备用API
      try {
        final response = await HttpClient.instance.get(
          'http://ip-api.com/json/',
        );
        final data = response.data;
        if (data is Map<String, dynamic>) {
          _cachedCity = data['city'] as String? ?? '未知';
          return {
            'lat': (data['lat'] as num).toDouble(),
            'lon': (data['lon'] as num).toDouble(),
          };
        }
      } catch (e2) {
        debugPrint('🌤️ 备用IP定位也失败: $e2');
      }
      return null;
    }
  }

  /// 从 Open-Meteo 查询天气
  Future<WeatherInfo> _fetchWeather(double lat, double lon) async {
    final response = await HttpClient.instance.get(
      'https://api.open-meteo.com/v1/forecast',
      queryParameters: {
        'latitude': lat,
        'longitude': lon,
        'current':
            'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day',
        'timezone': 'auto',
      },
    );

    final data = response.data;
    if (data is! Map<String, dynamic>) {
      return _buildFallbackWeather();
    }

    final current = data['current'] as Map<String, dynamic>?;
    if (current == null) return _buildFallbackWeather();

    final code = (current['weather_code'] as num?)?.toInt() ?? 0;
    final isDay = (current['is_day'] as int?) == 1;

    return WeatherInfo(
      temperature: (current['temperature_2m'] as num?)?.toDouble() ?? 20,
      feelsLike: (current['apparent_temperature'] as num?)?.toDouble() ?? 20,
      humidity: (current['relative_humidity_2m'] as num?)?.toInt() ?? 50,
      windSpeed: (current['wind_speed_10m'] as num?)?.toDouble() ?? 10,
      description: _weatherCodeToDescription(code, isDay),
      icon: _weatherCodeToIcon(code, isDay),
      code: code,
      isDay: isDay,
      city: _cachedCity ?? '未知',
    );
  }

  /// 无法获取天气时的回退
  WeatherInfo _buildFallbackWeather() {
    // 根据月份和当前时间给一个大致合理的天气
    final month = DateTime.now().month;
    final hour = DateTime.now().hour;
    double temp;
    String desc;

    if (month >= 6 && month <= 8) {
      temp = 28 + (hour >= 12 && hour <= 15 ? 5 : 0);
      desc = hour >= 6 && hour < 19 ? '晴' : '多云';
    } else if (month >= 12 || month <= 2) {
      temp = 5 + (hour >= 12 && hour <= 15 ? 3 : -2);
      desc = '阴';
    } else if (month >= 3 && month <= 5) {
      temp = 18;
      desc = '多云';
    } else {
      temp = 20;
      desc = '晴转多云';
    }

    return WeatherInfo(
      temperature: temp,
      feelsLike: temp,
      description: desc,
      icon: desc.contains('晴') ? '☀️' : '⛅',
      city: _cachedCity ?? '未知',
    );
  }

  /// WMO 天气代码 → 中文描述
  static String _weatherCodeToDescription(int code, bool isDay) {
    const descriptions = {
      0: '晴',
      1: '大部晴朗',
      2: '多云',
      3: '阴天',
      45: '雾',
      48: '霜雾',
      51: '小毛毛雨',
      53: '毛毛雨',
      55: '大毛毛雨',
      56: '冻毛毛雨',
      57: '大冻毛毛雨',
      61: '小雨',
      63: '中雨',
      65: '大雨',
      66: '冻雨',
      67: '大冻雨',
      71: '小雪',
      73: '中雪',
      75: '大雪',
      77: '雪粒',
      80: '小阵雨',
      81: '阵雨',
      82: '大阵雨',
      85: '小阵雪',
      86: '大阵雪',
      95: '雷暴',
      96: '雷暴伴冰雹',
      99: '强雷暴冰雹',
    };
    return descriptions[code] ?? '未知天气';
  }

  /// WMO 天气代码 → emoji 图标
  static String _weatherCodeToIcon(int code, bool isDay) {
    if (code == 0) return isDay ? '☀️' : '🌙';
    if (code <= 2) return '⛅';
    if (code <= 3) return '☁️';
    if (code <= 48) return '🌫️';
    if (code <= 57) return '🌦️';
    if (code <= 67) return '🌧️';
    if (code <= 77) return '❄️';
    if (code <= 82) return '🌧️';
    if (code <= 86) return '🌨️';
    return '⛈️';
  }
}
