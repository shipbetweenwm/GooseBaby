import 'weather_service.dart';

/// 智能关怀上下文 — 融合天气/时间/日期/健康/最近对话
class SmartCareContext {
  final WeatherInfo? weather;
  final DateTime now;
  final double petHealth;
  final double petEnergy;
  final double petHunger;
  final double petMood;
  final int companionDays;
  final List<String> recentUserMessages;
  final List<String> recentAssistantMessages;

  const SmartCareContext({
    this.weather,
    required this.now,
    this.petHealth = 90,
    this.petEnergy = 90,
    this.petHunger = 70,
    this.petMood = 80,
    this.companionDays = 1,
    this.recentUserMessages = const [],
    this.recentAssistantMessages = const [],
  });

  int get hour => now.hour;
  int get weekday => now.weekday;
  bool get isWeekday => weekday >= 1 && weekday <= 5;
  bool get isWeekend => weekday == 6 || weekday == 7;

  String get timeOfDay {
    if (hour >= 0 && hour < 6) return '深夜';
    if (hour >= 6 && hour < 9) return '清晨';
    if (hour >= 9 && hour < 12) return '上午';
    if (hour >= 12 && hour < 14) return '中午';
    if (hour >= 14 && hour < 17) return '下午';
    if (hour >= 17 && hour < 19) return '傍晚';
    if (hour >= 19 && hour < 22) return '晚上';
    return '深夜';
  }

  String get weekdayName {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return names[weekday - 1];
  }

  /// 特殊时间场景检测
  String get specialTimeContext {
    if (weekday == 5 && hour >= 15 && hour < 19) {
      return '周五下午了，马上周末，主人应该快下班了';
    }
    if (weekday == 5 && hour >= 19) {
      return '周五晚上，周末正式开始啦';
    }
    if (isWeekend && hour >= 8 && hour < 11) {
      return '周末早晨，可以睡个懒觉';
    }
    if (weekday == 7 && hour >= 19) {
      return '周日晚上，明天又要上班了';
    }
    if (hour >= 0 && hour < 6) {
      return '深夜了，主人可能还没睡';
    }
    if (isWeekday && hour >= 7 && hour < 9) {
      return '早上通勤时间';
    }
    if (hour >= 12 && hour < 14) {
      return '午休时间';
    }
    if (isWeekday && hour >= 17 && hour < 20) {
      return '下班时间';
    }
    return '';
  }

  /// 宠物健康状态描述
  String get petHealthContext {
    final parts = <String>[];
    if (petHunger < 30) parts.add('鹅宝有点饿了');
    if (petEnergy < 30) parts.add('鹅宝有点累了');
    if (petMood < 40) parts.add('鹅宝心情不太好');
    if (petHealth < 50) parts.add('鹅宝身体不太舒服');
    return parts.isEmpty ? '鹅宝状态良好' : parts.join('，');
  }

  /// 最近对话摘要（用于上下文）
  String get conversationSummary {
    if (recentUserMessages.isEmpty && recentAssistantMessages.isEmpty) {
      return '最近没有对话';
    }
    final parts = <String>[];
    if (recentUserMessages.isNotEmpty) {
      parts.add('主人最近说了: "${recentUserMessages.last}"');
    }
    if (recentAssistantMessages.isNotEmpty) {
      parts.add('鹅宝刚说了: "${recentAssistantMessages.last}"');
    }
    return parts.join('；');
  }

  /// 构建完整的上下文描述（注入到 LLM prompt）
  String buildFullContext() {
    final buffer = StringBuffer();

    // 时间日期（包含完整日期，让大模型自己判断节日）
    buffer.writeln('【当前时间】');
    buffer.writeln('今天是 ${now.year}年${now.month}月${now.day}日，周$weekdayName，$timeOfDay（$hour点）');
    if (specialTimeContext.isNotEmpty) {
      buffer.writeln('特殊场景: $specialTimeContext');
    }
    buffer.writeln('提示: 如果今天是节日（如春节、中秋、情人节、圣诞等），请在祝福中体现节日氛围');

    // 天气
    if (weather != null) {
      buffer.writeln('\n【天气情况】');
      buffer.writeln(weather!.brief);
      if (weather!.advice.isNotEmpty) {
        buffer.writeln(weather!.advice);
      }
    }

    // 宠物状态
    buffer.writeln('\n【鹅宝状态】');
    buffer.writeln(petHealthContext);
    buffer.writeln('已陪伴主人 $companionDays 天');

    // 最近对话
    if (recentUserMessages.isNotEmpty || recentAssistantMessages.isNotEmpty) {
      buffer.writeln('\n【最近对话】');
      buffer.writeln(conversationSummary);
    }

    return buffer.toString();
  }
}
