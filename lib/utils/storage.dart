import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';

/// 本地存储管理
class StorageManager {
  static bool _initialized = false;

  StorageManager._();

  /// 初始化 Hive 存储
  static Future<void> initialize() async {
    if (_initialized) return;

    // Web 平台使用 IndexedDB，桌面平台使用文件系统
    if (kIsWeb) {
      await Hive.initFlutter();
    } else {
      await Hive.initFlutter('goose_baby_data');
    }

    // 打开常用 Box
    await Hive.openBox('settings');
    await Hive.openBox('memory');
    await Hive.openBox('pet_state');
    await Hive.openBox('chat_history');

    _initialized = true;
    debugPrint('🦢 存储系统初始化完成');
  }

  /// 获取设置值
  static T? getSetting<T>(String key, {T? defaultValue}) {
    final box = Hive.box('settings');
    return box.get(key, defaultValue: defaultValue) as T?;
  }

  /// 保存设置值
  static Future<void> setSetting(String key, dynamic value) async {
    final box = Hive.box('settings');
    await box.put(key, value);
  }

  /// 获取宠物状态
  static Map<String, dynamic> getPetState() {
    final box = Hive.box('pet_state');
    return {
      'happiness': box.get('happiness', defaultValue: 80),
      'hunger': box.get('hunger', defaultValue: 70),
      'energy': box.get('energy', defaultValue: 90),
      'mood': box.get('mood', defaultValue: 'happy'),
      'level': box.get('level', defaultValue: 1),
      'exp': box.get('exp', defaultValue: 0),
    };
  }

  /// 保存宠物状态
  static Future<void> savePetState(Map<String, dynamic> state) async {
    final box = Hive.box('pet_state');
    for (final entry in state.entries) {
      await box.put(entry.key, entry.value);
    }
  }

  /// 获取LLM配置
  static Map<String, String> getLlmConfig() {
    final box = Hive.box('settings');
    return {
      'provider': box.get('llm_provider', defaultValue: 'qwen') as String,
      'apiKey': box.get('llm_api_key', defaultValue: '') as String,
      'model': box.get('llm_model', defaultValue: 'qwen-turbo') as String,
      'endpoint': box.get('llm_endpoint', defaultValue: '') as String,
    };
  }

  /// 保存LLM配置
  static Future<void> saveLlmConfig(Map<String, String> config) async {
    final box = Hive.box('settings');
    for (final entry in config.entries) {
      await box.put('llm_${entry.key}', entry.value);
    }
  }

  /// 保存聊天历史
  static Future<void> saveChatMessage(Map<String, dynamic> message) async {
    final box = Hive.box('chat_history');
    final history = (box.get('messages', defaultValue: <dynamic>[]) as List).toList();
    history.add(message);
    // 限制历史条数
    if (history.length > 500) {
      history.removeRange(0, history.length - 500);
    }
    await box.put('messages', history);
  }

  // ══════════════════════════════════════════
  // 搜索 / 新闻 API Key 管理
  // key 前缀 "search_key_" 统一存储在 settings box
  // ══════════════════════════════════════════

  /// 保存某个搜索引擎的 API key（key 为空字符串时视为清除）
  static Future<void> saveSearchApiKey(String provider, String apiKey) async {
    final box = Hive.box('settings');
    await box.put('search_key_$provider', apiKey.trim());
  }

  /// 读取某个搜索引擎的 API key，不存在时返回 null
  static String? getSearchApiKey(String provider) {
    final box = Hive.box('settings');
    final val = box.get('search_key_$provider') as String?;
    return (val == null || val.isEmpty) ? null : val;
  }

  /// 读取全部已保存的搜索/新闻 API key
  /// 返回 {provider: apiKey} map
  static Map<String, String> getAllSearchApiKeys() {
    const providers = ['tavily', 'brave', 'exa', 'gnews'];
    final result = <String, String>{};
    for (final p in providers) {
      final v = getSearchApiKey(p);
      if (v != null) result[p] = v;
    }
    return result;
  }

  /// 清除所有数据
  static Future<void> clearAll() async {
    await Hive.box('settings').clear();
    await Hive.box('memory').clear();
    await Hive.box('pet_state').clear();
    await Hive.box('chat_history').clear();
    debugPrint('🦢 所有存储数据已清除');
  }
}
