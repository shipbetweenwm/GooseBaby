import 'package:dio/dio.dart';
import '../skill_base.dart';

/// 天气查询技能
class WeatherSkill extends GooseSkill {
  final _dio = Dio();

  @override
  String get id => 'weather';

  @override
  String get name => '天气查询';

  @override
  String get description => '查询指定城市的当前天气情况，包括温度、湿度、天气状况等';

  @override
  String get icon => '🌤️';

  @override
  String get category => '生活工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'city',
      description: '要查询天气的城市名称，例如"北京"、"上海"',
      type: 'string',
      required: true,
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args) async {
    final city = args['city'] as String?;
    if (city == null || city.isEmpty) {
      return SkillResult.fail('请告诉鹅宝你想查哪个城市的天气呀~');
    }

    try {
      // 使用 wttr.in 免费天气API
      final response = await _dio.get(
        'https://wttr.in/$city',
        queryParameters: {'format': 'j1'},
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final current = (data['current_condition'] as List).first as Map<String, dynamic>;

        final temp = current['temp_C'];
        final feelsLike = current['FeelsLikeC'];
        final humidity = current['humidity'];
        final weatherDesc = (current['lang_zh'] as List?)?.first['value'] ??
            (current['weatherDesc'] as List).first['value'];
        final windSpeed = current['windspeedKmph'];

        return SkillResult.ok(
          '${city}现在的天气是$weatherDesc，温度${temp}°C（体感${feelsLike}°C），'
          '湿度${humidity}%，风速${windSpeed}km/h',
          data: {
            'city': city,
            'temperature': temp,
            'feelsLike': feelsLike,
            'humidity': humidity,
            'weather': weatherDesc,
            'windSpeed': windSpeed,
          },
          displayWidget: 'weather_card',
        );
      }

      return SkillResult.fail('鹅宝查不到${city}的天气呢，是不是城市名字写错啦？');
    } catch (e) {
      return SkillResult.fail('天气查询出错了：$e');
    }
  }
}
