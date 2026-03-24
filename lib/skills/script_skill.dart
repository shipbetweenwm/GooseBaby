import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'skill_base.dart';
import 'agent_skill.dart';

/// 脚本技能 - 从 JSON 配置文件动态加载的技能
///
/// 支持两种格式：
///
/// ### 格式 1：鹅宝原生格式（基于规则引擎）
/// ```json
/// {
///   "id": "my_greeting",
///   "name": "打招呼",
///   "description": "根据时间打招呼",
///   "icon": "👋",
///   "category": "自定义",
///   "params": [{"name": "name", "description": "名字", "type": "string"}],
///   "rules": [
///     {"condition": "hour < 12", "response": "早上好，{name}！"},
///     {"condition": "default", "response": "你好，{name}！"}
///   ]
/// }
/// ```
///
/// ### 格式 2：OpenAI Function Calling 标准格式
/// ```json
/// {
///   "type": "function",
///   "function": {
///     "name": "get_weather",
///     "description": "获取天气信息",
///     "parameters": {
///       "type": "object",
///       "properties": {
///         "location": {"type": "string", "description": "城市名"}
///       },
///       "required": ["location"]
///     }
///   },
///   "icon": "🌤️",
///   "category": "工具",
///   "rules": [...],
///   "default_response": "..."
/// }
/// ```
///
/// ### 格式 3：技能包（文件夹格式）
/// ```
/// my_skill_pack/
///   manifest.json    ← 技能包清单
///   skills/
///     skill_a.json
///     skill_b.json
///   assets/           ← 可选：资源文件
/// ```
///
/// manifest.json:
/// ```json
/// {
///   "name": "我的技能包",
///   "version": "1.0.0",
///   "author": "xxx",
///   "description": "技能包描述",
///   "skills": ["skills/skill_a.json", "skills/skill_b.json"]
/// }
/// ```
class ScriptSkill extends GooseSkill {
  final String _id;
  final String _name;
  final String _description;
  final String _icon;
  final String _category;
  final List<SkillParam> _params;
  final List<Map<String, dynamic>> _rules;
  final String _defaultResponse;

  /// 脚本技能的来源文件路径
  final String? sourcePath;

  /// 所属技能包名称
  final String? packName;

  ScriptSkill({
    required String id,
    required String name,
    required String description,
    required String icon,
    String category = '自定义技能',
    required List<SkillParam> params,
    required List<Map<String, dynamic>> rules,
    required String defaultResponse,
    this.sourcePath,
    this.packName,
  })  : _id = id,
        _name = name,
        _description = description,
        _icon = icon,
        _category = category,
        _params = params,
        _rules = rules,
        _defaultResponse = defaultResponse;

  @override
  String get id => _id;

  @override
  String get name => _name;

  @override
  String get description => _description;

  @override
  String get icon => _icon;

  @override
  String get category => _category;

  @override
  List<SkillParam> get params => _params;

  @override
  Future<SkillResult> execute(Map<String, dynamic> args) async {
    try {
      for (final rule in _rules) {
        final condition = rule['condition'] as String? ?? 'default';
        if (_evaluateCondition(condition, args)) {
          final template = rule['response'] as String? ?? _defaultResponse;
          final result = _expandTemplate(template, args);
          return SkillResult.ok(result);
        }
      }
      return SkillResult.ok(_expandTemplate(_defaultResponse, args));
    } catch (e) {
      return SkillResult.fail('脚本执行出错: $e');
    }
  }

  bool _evaluateCondition(String condition, Map<String, dynamic> args) {
    if (condition == 'default' || condition.isEmpty) return true;

    final now = DateTime.now();
    // 使用 word boundary 避免参数名包含 hour/minute/weekday 时被误替换
    String resolved = condition.trim()
        .replaceAllMapped(RegExp(r'\bhour\b'), (_) => now.hour.toString())
        .replaceAllMapped(RegExp(r'\bminute\b'), (_) => now.minute.toString())
        .replaceAllMapped(RegExp(r'\bweekday\b'), (_) => now.weekday.toString());

    for (final entry in args.entries) {
      resolved = resolved.replaceAll(entry.key, entry.value.toString());
    }

    if (resolved.contains('<=')) {
      final parts = resolved.split('<=').map((s) => s.trim()).toList();
      return _toNum(parts[0]) <= _toNum(parts[1]);
    }
    if (resolved.contains('>=')) {
      final parts = resolved.split('>=').map((s) => s.trim()).toList();
      return _toNum(parts[0]) >= _toNum(parts[1]);
    }
    if (resolved.contains('!=')) {
      final parts = resolved.split('!=').map((s) => s.trim()).toList();
      return parts[0] != parts[1];
    }
    if (resolved.contains('==')) {
      final parts = resolved.split('==').map((s) => s.trim()).toList();
      return parts[0] == parts[1];
    }
    if (resolved.contains('<')) {
      final parts = resolved.split('<').map((s) => s.trim()).toList();
      return _toNum(parts[0]) < _toNum(parts[1]);
    }
    if (resolved.contains('>')) {
      final parts = resolved.split('>').map((s) => s.trim()).toList();
      return _toNum(parts[0]) > _toNum(parts[1]);
    }

    return false;
  }

  double _toNum(String s) => double.tryParse(s.trim()) ?? 0;

  String _expandTemplate(String template, Map<String, dynamic> args) {
    String result = template;
    for (final entry in args.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value.toString());
    }
    final now = DateTime.now();
    result = result
        .replaceAll('{hour}', now.hour.toString().padLeft(2, '0'))
        .replaceAll('{minute}', now.minute.toString().padLeft(2, '0'))
        .replaceAll('{date}', '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}')
        .replaceAll('{weekday}', _weekdayName(now.weekday));
    return result;
  }

  String _weekdayName(int weekday) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return '星期${names[weekday - 1]}';
  }

  /// 从鹅宝原生格式 JSON 解析
  factory ScriptSkill.fromJson(Map<String, dynamic> json, {String? sourcePath, String? packName}) {
    final paramsList = _parseParams(json['params']);
    final rules = _parseRules(json['rules']);

    return ScriptSkill(
      id: json['id'] as String? ?? 'unknown',
      name: json['name'] as String? ?? '未命名技能',
      description: json['description'] as String? ?? '',
      icon: json['icon'] as String? ?? '🔧',
      category: json['category'] as String? ?? '自定义技能',
      params: paramsList,
      rules: rules,
      defaultResponse: json['default_response'] as String? ?? '技能已执行',
      sourcePath: sourcePath,
      packName: packName,
    );
  }

  /// 从 OpenAI Function Calling 标准格式解析
  factory ScriptSkill.fromOpenAIFormat(Map<String, dynamic> json, {String? sourcePath, String? packName}) {
    final funcDef = json['function'] as Map<String, dynamic>? ?? {};
    final params = funcDef['parameters'] as Map<String, dynamic>? ?? {};
    final properties = params['properties'] as Map<String, dynamic>? ?? {};
    final required = (params['required'] as List?)?.cast<String>() ?? [];

    final paramsList = <SkillParam>[];
    for (final entry in properties.entries) {
      final propDef = entry.value as Map<String, dynamic>? ?? {};
      paramsList.add(SkillParam(
        name: entry.key,
        description: propDef['description'] as String? ?? '',
        type: _mapOpenAIType(propDef['type'] as String? ?? 'string'),
        required: required.contains(entry.key),
        enumValues: (propDef['enum'] as List?)?.cast<String>(),
      ));
    }

    final rules = _parseRules(json['rules']);

    return ScriptSkill(
      id: funcDef['name'] as String? ?? 'unknown',
      name: json['name'] as String? ?? funcDef['name'] as String? ?? '未命名技能',
      description: funcDef['description'] as String? ?? '',
      icon: json['icon'] as String? ?? '🔧',
      category: json['category'] as String? ?? '外部技能',
      params: paramsList,
      rules: rules,
      defaultResponse: json['default_response'] as String? ?? '技能已执行',
      sourcePath: sourcePath,
      packName: packName,
    );
  }

  /// 智能解析：自动检测格式
  factory ScriptSkill.fromAnyFormat(Map<String, dynamic> json, {String? sourcePath, String? packName}) {
    // 检测是否为 OpenAI Function Calling 格式
    if (json.containsKey('type') && json['type'] == 'function' && json.containsKey('function')) {
      return ScriptSkill.fromOpenAIFormat(json, sourcePath: sourcePath, packName: packName);
    }
    // 否则使用鹅宝原生格式
    return ScriptSkill.fromJson(json, sourcePath: sourcePath, packName: packName);
  }

  static String _mapOpenAIType(String openAIType) {
    switch (openAIType) {
      case 'integer': return 'int';
      case 'number': return 'double';
      case 'boolean': return 'bool';
      default: return 'string';
    }
  }

  static List<SkillParam> _parseParams(dynamic paramsData) {
    final paramsList = <SkillParam>[];
    if (paramsData is List) {
      for (final p in paramsData) {
        if (p is Map) {
          paramsList.add(SkillParam(
            name: p['name'] as String? ?? '',
            description: p['description'] as String? ?? '',
            type: p['type'] as String? ?? 'string',
            required: p['required'] as bool? ?? true,
            defaultValue: p['defaultValue'],
            enumValues: (p['enumValues'] as List?)?.cast<String>(),
          ));
        }
      }
    }
    return paramsList;
  }

  static List<Map<String, dynamic>> _parseRules(dynamic rulesData) {
    final rules = <Map<String, dynamic>>[];
    if (rulesData is List) {
      for (final r in rulesData) {
        if (r is Map) {
          rules.add(Map<String, dynamic>.from(r));
        }
      }
    }
    return rules;
  }
}

/// 技能包清单
class SkillPackManifest {
  final String name;
  final String version;
  final String author;
  final String description;
  final List<String> skillFiles;

  SkillPackManifest({
    required this.name,
    this.version = '1.0.0',
    this.author = '',
    this.description = '',
    required this.skillFiles,
  });

  factory SkillPackManifest.fromJson(Map<String, dynamic> json) {
    return SkillPackManifest(
      name: json['name'] as String? ?? '未命名技能包',
      version: json['version'] as String? ?? '1.0.0',
      author: json['author'] as String? ?? '',
      description: json['description'] as String? ?? '',
      skillFiles: (json['skills'] as List?)?.cast<String>() ?? [],
    );
  }
}

/// 技能加载器 - 支持文件、目录、ZIP、技能包（文件夹）、Agent Skill（SKILL.md）加载
class SkillLoader {

  /// 从 ZIP 文件加载技能（OpenClaw 标准格式）
  /// 将 ZIP 解压到临时目录，然后按 Agent Skill 格式加载
  static Future<List<GooseSkill>> loadFromZip(String zipPath) async {
    final skills = <GooseSkill>[];

    try {
      final zipFile = File(zipPath);
      if (!await zipFile.exists()) {
        debugPrint('🦢 ZIP 文件不存在: $zipPath');
        return skills;
      }

      // 每次解压到唯一临时目录，避免冲突
      final extractDir = '${zipPath}_extracted';

      // 读取 ZIP 文件
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // 清理旧解压目录
      final extractDirectory = Directory(extractDir);
      if (await extractDirectory.exists()) {
        await extractDirectory.delete(recursive: true);
      }
      await extractDirectory.create(recursive: true);

      for (final file in archive) {
        try {
          final filePath = p.join(extractDir, file.name);
          if (file.isFile) {
            final outFile = File(filePath);
            await outFile.parent.create(recursive: true);
            // content 是 List<int> 类型
            final bytes = Uint8List.fromList(file.content);
            await outFile.writeAsBytes(bytes);
          } else {
            await Directory(filePath).create(recursive: true);
          }
        } catch (e) {
          debugPrint('🦢 解压文件失败: ${file.name} - $e');
        }
      }

      debugPrint('🦢 ZIP 解压完成: $extractDir (${archive.length} 个文件)');

      // 从解压目录加载技能
      final skillMd = File('$extractDir/SKILL.md');
      if (await skillMd.exists()) {
        final skill = await AgentSkill.fromDirectory(extractDir);
        if (skill != null) skills.add(skill);
      } else {
        await for (final entity in extractDirectory.list()) {
          if (entity is Directory) {
            try {
              final subSkillMd = File('${entity.path}/SKILL.md');
              if (await subSkillMd.exists()) {
                final skill = await AgentSkill.fromDirectory(entity.path);
                if (skill != null) skills.add(skill);
              }
            } catch (e) {
              debugPrint('🦢 加载子目录技能失败: ${entity.path} - $e');
            }
          }
        }
      }

      debugPrint('🦢 从 ZIP 加载 ${skills.length} 个技能: ${p.basename(zipPath)}');
    } catch (e, st) {
      debugPrint('🦢 ZIP 加载失败: $zipPath - $e\n$st');
    }

    return skills;
  }

  /// 扫描指定目录下的 .json 技能文件和子文件夹（技能包 / Agent Skill）
  static Future<List<GooseSkill>> loadFromDirectory(String dirPath) async {
    final skills = <GooseSkill>[];
    final dir = Directory(dirPath);

    if (!await dir.exists()) {
      debugPrint('🦢 技能目录不存在: $dirPath');
      return skills;
    }

    try {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final loaded = await _loadSkillFile(entity.path);
          if (loaded != null) skills.add(loaded);
        } else if (entity is Directory) {
          final agentSkill = await _loadAgentSkill(entity.path);
          if (agentSkill != null) {
            skills.add(agentSkill);
          } else {
            final packSkills = await loadFromPack(entity.path);
            skills.addAll(packSkills);
          }
        }
      }
    } catch (e) {
      debugPrint('🦢 扫描技能目录失败: $e');
    }

    return skills;
  }

  /// 尝试从目录加载 Agent Skill（检测 SKILL.md 文件）
  static Future<AgentSkill?> _loadAgentSkill(String dirPath) async {
    final skillMd = File('$dirPath/SKILL.md');
    if (!await skillMd.exists()) return null;

    debugPrint('🤖 检测到 Agent Skill 格式: $dirPath');
    return await AgentSkill.fromDirectory(dirPath);
  }

  /// 加载单个技能文件
  static Future<ScriptSkill?> _loadSkillFile(String filePath, {String? packName}) async {
    try {
      final file = File(filePath);
      final content = await file.readAsString(encoding: utf8);
      final json = jsonDecode(content) as Map<String, dynamic>;
      final skill = ScriptSkill.fromAnyFormat(json, sourcePath: filePath, packName: packName);
      debugPrint('🦢 加载技能: ${skill.name} (${skill.id}) from $filePath');
      return skill;
    } catch (e) {
      debugPrint('🦢 技能文件加载失败: $filePath - $e');
      return null;
    }
  }

  /// 从技能包目录加载（支持 Agent Skill / manifest.json / 直接扫描 .json 文件）
  static Future<List<GooseSkill>> loadFromPack(String packDirPath) async {
    final skills = <GooseSkill>[];
    final packDir = Directory(packDirPath);
    if (!await packDir.exists()) return skills;

    // 优先检测 Agent Skill 格式（含 SKILL.md）
    final agentSkill = await _loadAgentSkill(packDirPath);
    if (agentSkill != null) {
      skills.add(agentSkill);
      return skills;
    }

    final manifestFile = File('$packDirPath/manifest.json');

    if (await manifestFile.exists()) {
      // 有 manifest.json → 按清单加载
      try {
        final content = await manifestFile.readAsString(encoding: utf8);
        final json = jsonDecode(content) as Map<String, dynamic>;
        final manifest = SkillPackManifest.fromJson(json);
        debugPrint('🦢 加载技能包: ${manifest.name} v${manifest.version} by ${manifest.author}');

        for (final skillFile in manifest.skillFiles) {
          final fullPath = '$packDirPath/$skillFile';
          final skill = await _loadSkillFile(fullPath, packName: manifest.name);
          if (skill != null) skills.add(skill);
        }
      } catch (e) {
        debugPrint('🦢 技能包清单加载失败: $packDirPath - $e');
      }
    } else {
      // 无 manifest → 直接扫描目录下的 .json 文件
      final packName = packDirPath.split('/').last.split('\\').last;
      try {
        await for (final entity in packDir.list(recursive: true)) {
          if (entity is File && entity.path.endsWith('.json')) {
            final skill = await _loadSkillFile(entity.path, packName: packName);
            if (skill != null) skills.add(skill);
          }
        }
      } catch (e) {
        debugPrint('🦢 技能包目录扫描失败: $packDirPath - $e');
      }
    }

    return skills;
  }

  /// 从 JSON 字符串加载单个技能（自动检测格式）
  static ScriptSkill? loadFromString(String jsonString) {
    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return ScriptSkill.fromAnyFormat(json);
    } catch (e) {
      debugPrint('🦢 解析技能 JSON 失败: $e');
      return null;
    }
  }
}
