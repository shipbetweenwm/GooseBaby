import 'package:flutter/foundation.dart';
import '../skill_base.dart';

/// 系统信息技能
class SystemInfoSkill extends GooseSkill {
  @override
  String get id => 'system_info';

  @override
  String get name => '系统信息';

  @override
  String get description => '查询电脑的系统信息，包括操作系统、内存、CPU等';

  @override
  String get icon => '💻';

  @override
  String get category => '系统工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'info_type',
      description: '要查询的信息类型',
      type: 'enum',
      required: false,
      defaultValue: 'overview',
      enumValues: ['overview', 'os', 'memory', 'disk', 'network'],
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args) async {
    final infoType = args['info_type'] as String? ?? 'overview';

    switch (infoType) {
      case 'overview':
        return _getOverview();
      case 'os':
        return _getOsInfo();
      case 'memory':
        return _getMemoryInfo();
      case 'disk':
        return _getDiskInfo();
      case 'network':
        return _getNetworkInfo();
      default:
        return SkillResult.fail('不支持的信息类型: $infoType');
    }
  }

  SkillResult _getOverview() {
    final platform = defaultTargetPlatform.name;
    final isWeb = kIsWeb;

    if (isWeb) {
      return SkillResult.ok(
        '🌐 你正在使用 Web 版鹅宝~\n'
        '• 平台: Web 浏览器\n'
        '• 模式: ${kDebugMode ? "调试" : "发布"}',
        data: {'platform': 'web'},
      );
    }

    String osEmoji;
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
        osEmoji = '🍎';
        break;
      case TargetPlatform.windows:
        osEmoji = '🪟';
        break;
      case TargetPlatform.linux:
        osEmoji = '🐧';
        break;
      default:
        osEmoji = '💻';
    }

    return SkillResult.ok(
      '$osEmoji 你的电脑信息：\n'
      '• 平台: $platform\n'
      '• 模式: ${kDebugMode ? "调试" : "发布"}',
      data: {'platform': platform},
    );
  }

  SkillResult _getOsInfo() {
    return SkillResult.ok(
      '操作系统: ${defaultTargetPlatform.name}\n'
      '调试模式: ${kDebugMode ? "是" : "否"}\n'
      'Web平台: ${kIsWeb ? "是" : "否"}',
    );
  }

  Future<SkillResult> _getMemoryInfo() async {
    return SkillResult.ok('鹅宝暂时获取不到详细内存信息~ 需要在桌面原生模式下才行哦~');
  }

  Future<SkillResult> _getDiskInfo() async {
    return SkillResult.ok('鹅宝暂时获取不到磁盘信息~ 需要在桌面原生模式下才行哦~');
  }

  Future<SkillResult> _getNetworkInfo() async {
    return SkillResult.ok('鹅宝暂时获取不到网络信息~ 需要在桌面原生模式下才行哦~');
  }
}
