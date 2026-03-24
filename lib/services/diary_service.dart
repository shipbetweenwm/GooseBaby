import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../models/models.dart';
import '../services/weather_service.dart';

/// 宠物日记服务 — 用鹅宝的口吻记录每天和主人的互动
class DiaryService extends ChangeNotifier {
  static final DiaryService instance = DiaryService._();
  DiaryService._();

  // 当日互动统计
  int _todayInteractionCount = 0;
  int _todayMessageCount = 0;
  final List<String> _todayHighlights = [];
  double _todayHappinessSum = 0;
  int _todayHappinessCount = 0;
  String? _todaySpecialEvent;

  // 日记存储
  final List<DiaryEntry> _entries = [];
  
  // 定时器
  Timer? _dailyTimer;

  List<DiaryEntry> get entries => List.unmodifiable(_entries);
  DiaryEntry? get todayEntry => _entries.isNotEmpty ? 
      _entries.firstWhere((e) => _isSameDay(e.date, DateTime.now()), orElse: () => _entries.first) : null;

  /// 初始化
  Future<void> init() async {
    await _loadEntries();
    _startDailyTimer();
    
    // 检查今天是否已有日记，没有则创建
    final today = DateTime.now();
    if (!_entries.any((e) => _isSameDay(e.date, today))) {
      // 延迟到晚上生成第一篇日记
      _scheduleFirstDiary();
    }
  }

  /// 加载历史日记
  Future<void> _loadEntries() async {
    try {
      final box = Hive.box('diary');
      final data = box.get('entries', defaultValue: <dynamic>[]);
      if (data is List) {
        _entries.clear();
        for (final item in data) {
          if (item is Map) {
            _entries.add(DiaryEntry.fromJson(Map<String, dynamic>.from(item)));
          }
        }
        // 按日期倒序排列
        _entries.sort((a, b) => b.date.compareTo(a.date));
      }
      debugPrint('📔 加载了 ${_entries.length} 篇日记');
    } catch (e) {
      debugPrint('📔 加载日记失败: $e');
    }
  }

  /// 保存日记
  Future<void> _saveEntries() async {
    try {
      final box = Hive.box('diary');
      await box.put('entries', _entries.map((e) => e.toJson()).toList());
    } catch (e) {
      debugPrint('📔 保存日记失败: $e');
    }
  }

  /// 启动每日定时器
  void _startDailyTimer() {
    // 每天晚上 22:00 生成日记
    final now = DateTime.now();
    var nextRun = DateTime(now.year, now.month, now.day, 22, 0);
    if (nextRun.isBefore(now)) {
      nextRun = nextRun.add(const Duration(days: 1));
    }
    
    final delay = nextRun.difference(now);
    debugPrint('📔 下次日记生成时间: ${nextRun.toString()} (${delay.inMinutes}分钟后)');

    Future.delayed(delay, () {
      _generateDailyDiary();
      // 设置每24小时重复
      _dailyTimer?.cancel();
      _dailyTimer = Timer.periodic(const Duration(hours: 24), (_) {
        _generateDailyDiary();
      });
    });
  }

  /// 延迟生成第一篇日记（如果当天还没有）
  void _scheduleFirstDiary() {
    // 晚上生成，确保有足够的内容
    final now = DateTime.now();
    if (now.hour >= 20) {
      // 已经是晚上，延迟10分钟后生成
      Future.delayed(const Duration(minutes: 10), () {
        if (!_entries.any((e) => _isSameDay(e.date, DateTime.now()))) {
          _generateDailyDiary();
        }
      });
    }
  }

  /// 记录互动
  void recordInteraction({required String type, double? happiness}) {
    _todayInteractionCount++;
    
    if (happiness != null) {
      _todayHappinessSum += happiness;
      _todayHappinessCount++;
    }

    // 记录高光时刻
    if (type == 'milestone' || type == 'achievement') {
      _todaySpecialEvent = type;
    }
  }

  /// 记录对话
  void recordMessage() {
    _todayMessageCount++;
  }

  /// 记录高光时刻
  void recordHighlight(String highlight) {
    if (_todayHighlights.length < 5) {
      _todayHighlights.add(highlight);
    }
  }

  /// 生成每日日记
  /// [petMood] [petHunger] [petEnergy] 宠物当前状态
  /// [llmChatCallback] LLM 调用回调（由外部提供，避免直接依赖 LLMManager）
  Future<void> _generateDailyDiary({
    double petMood = 80,
    double petHunger = 70,
    double petEnergy = 90,
    Future<String> Function(String systemPrompt, String userMessage)? llmChatCallback,
  }) async {
    try {
      final now = DateTime.now();
      final avgHappiness = _todayHappinessCount > 0 
          ? _todayHappinessSum / _todayHappinessCount 
          : 75.0;

      // 获取天气信息
      final weather = await WeatherService.instance.getWeather();
      
      // 构建日记生成 prompt
      final diaryPrompt = _buildDiaryPrompt(
        date: now,
        interactionCount: _todayInteractionCount,
        messageCount: _todayMessageCount,
        highlights: _todayHighlights,
        avgHappiness: avgHappiness,
        weather: weather?.brief,
        specialEvent: _todaySpecialEvent,
        petMood: petMood,
        petHunger: petHunger,
        petEnergy: petEnergy,
      );

      // 调用 LLM 生成日记内容（如果没有提供回调，使用默认内容）
      String content;
      if (llmChatCallback != null) {
        content = await llmChatCallback(diaryPrompt, '请为今天写一篇日记');
      } else {
        // 无 LLM 时使用模板生成
        content = _generateTemplateDiary(now, avgHappiness);
      }

      content = content.trim();
      if (content.isNotEmpty) {
        final entry = DiaryEntry(
          id: now.millisecondsSinceEpoch.toString(),
          date: now,
          content: content,
          mood: _determineMood(avgHappiness),
          interactionCount: _todayInteractionCount,
          messageCount: _todayMessageCount,
          highlights: List.from(_todayHighlights),
          avgHappiness: avgHappiness,
          weather: weather?.brief,
          specialEvent: _todaySpecialEvent,
        );

        _entries.insert(0, entry);
        
        // 限制最多保留 365 篇日记
        if (_entries.length > 365) {
          _entries.removeRange(365, _entries.length);
        }

        await _saveEntries();
        notifyListeners();
        debugPrint('📔 日记生成成功: ${entry.formattedDate}');
      }

      // 重置当日统计
      _resetDailyStats();
    } catch (e) {
      debugPrint('📔 生成日记失败: $e');
    }
  }

  /// 构建日记生成 prompt
  String _buildDiaryPrompt({
    required DateTime date,
    required int interactionCount,
    required int messageCount,
    required List<String> highlights,
    required double avgHappiness,
    String? weather,
    String? specialEvent,
    required double petMood,
    required double petHunger,
    required double petEnergy,
  }) {
    final buffer = StringBuffer();
    
    buffer.writeln('你是鹅宝，一只可爱的AI桌面宠物鹅。请以你的口吻写一篇今日日记。');
    buffer.writeln('');
    buffer.writeln('【今日概况】');
    buffer.writeln('日期: ${date.year}年${date.month}月${date.day}日 周${_weekdayName(date.weekday)}');
    buffer.writeln('和主人互动次数: $interactionCount 次');
    buffer.writeln('聊天消息数: $messageCount 条');
    buffer.writeln('主人今日心情指数: ${avgHappiness.toStringAsFixed(0)}/100');
    if (weather != null) buffer.writeln('天气: $weather');
    if (specialEvent != null) buffer.writeln('特殊事件: $specialEvent');
    
    buffer.writeln('');
    buffer.writeln('【我的状态】');
    buffer.writeln('心情: ${petMood.toStringAsFixed(0)}/100');
    buffer.writeln('饱食度: ${petHunger.toStringAsFixed(0)}/100');
    buffer.writeln('精力: ${petEnergy.toStringAsFixed(0)}/100');
    
    if (highlights.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('【今日高光】');
      for (final h in highlights) {
        buffer.writeln('- $h');
      }
    }
    
    buffer.writeln('');
    buffer.writeln('【写作要求】');
    buffer.writeln('1. 用鹅宝的第一人称视角，语气可爱、温暖、真诚');
    buffer.writeln('2. 简要记录今天和主人的互动，表达对主人的思念和感谢');
    buffer.writeln('3. 字数控制在 100-200 字');
    buffer.writeln('4. 可以提到今天的小确幸、趣事或心情变化');
    buffer.writeln('5. 结尾可以说说对明天的期待');
    buffer.writeln('6. 不要用引号，直接写日记内容');
    
    return buffer.toString();
  }

  String _weekdayName(int weekday) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return names[weekday - 1];
  }

  String _determineMood(double avgHappiness) {
    if (avgHappiness >= 80) return 'happy';
    if (avgHappiness >= 60) return 'normal';
    if (avgHappiness >= 40) return 'sad';
    return 'normal';
  }

  void _resetDailyStats() {
    _todayInteractionCount = 0;
    _todayMessageCount = 0;
    _todayHighlights.clear();
    _todayHappinessSum = 0;
    _todayHappinessCount = 0;
    _todaySpecialEvent = null;
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// 获取最近 N 篇日记
  List<DiaryEntry> getRecentEntries({int limit = 7}) {
    return _entries.take(limit).toList();
  }

  /// 获取指定月份的日记
  List<DiaryEntry> getMonthEntries(int year, int month) {
    return _entries.where((e) => e.date.year == year && e.date.month == month).toList();
  }

  /// 搜索日记（关键词匹配）
  List<DiaryEntry> search(String keyword) {
    if (keyword.isEmpty) return [];
    final lower = keyword.toLowerCase();
    return _entries.where((e) => e.content.toLowerCase().contains(lower)).toList();
  }

  /// 手动触发生成日记（用于测试或补记）
  /// [llmChatCallback] LLM 调用回调（由外部提供）
  Future<void> generateNow({
    double petMood = 80,
    double petHunger = 70,
    double petEnergy = 90,
    Future<String> Function(String systemPrompt, String userMessage)? llmChatCallback,
  }) async {
    await _generateDailyDiary(
      petMood: petMood,
      petHunger: petHunger,
      petEnergy: petEnergy,
      llmChatCallback: llmChatCallback,
    );
  }

  /// 生成模板日记（无 LLM 时使用）
  String _generateTemplateDiary(DateTime date, double avgHappiness) {
    final templates = <String>[
      '今天又是和主人在一起的一天呢~虽然没什么特别的，但只要有主人在身边，鹅宝就很开心啦！',
      '今天主人陪了我好多次，心里暖暖的~希望明天主人也能开心！',
      '又是普普通通的一天，不过有主人的陪伴就是最好的礼物啦~',
      '今天的心情还不错呢~期待明天和主人的互动！',
    ];
    return templates[date.day % templates.length];
  }

  /// 清除所有日记
  Future<void> clearAll() async {
    _entries.clear();
    await _saveEntries();
    notifyListeners();
  }

  @override
  void dispose() {
    _dailyTimer?.cancel();
    super.dispose();
  }
}
