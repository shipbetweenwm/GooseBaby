/// 鹅宝技能系统 - 基础协议定义
/// 所有技能都需要实现 [GooseSkill] 抽象类

/// 技能执行结果
class SkillResult {
  final bool success;
  final String message;
  final Map<String, dynamic>? data;
  final String? displayWidget; // 可选：前端渲染提示

  const SkillResult({
    required this.success,
    required this.message,
    this.data,
    this.displayWidget,
  });

  factory SkillResult.ok(String message, {Map<String, dynamic>? data, String? displayWidget}) {
    return SkillResult(success: true, message: message, data: data, displayWidget: displayWidget);
  }

  factory SkillResult.fail(String message) {
    return SkillResult(success: false, message: message);
  }

  Map<String, dynamic> toJson() => {
    'success': success,
    'message': message,
    if (data != null) 'data': data,
    if (displayWidget != null) 'displayWidget': displayWidget,
  };
}

/// 技能参数定义
class SkillParam {
  final String name;
  final String description;
  final String type; // string, int, double, bool, enum
  final bool required;
  final dynamic defaultValue;
  final List<String>? enumValues; // type=enum时的可选值

  const SkillParam({
    required this.name,
    required this.description,
    this.type = 'string',
    this.required = true,
    this.defaultValue,
    this.enumValues,
  });

  Map<String, dynamic> toFunctionParam() {
    final param = <String, dynamic>{
      'type': _mapType(type),
      'description': description,
    };
    if (enumValues != null && enumValues!.isNotEmpty) {
      param['enum'] = enumValues;
    }
    return param;
  }

  String _mapType(String t) {
    switch (t) {
      case 'int':
      case 'double':
        return 'number';
      case 'bool':
        return 'boolean';
      case 'enum':
        return 'string';
      default:
        return 'string';
    }
  }
}

/// 技能基类 - 所有技能必须继承
abstract class GooseSkill {
  /// 技能唯一标识
  String get id;

  /// 技能显示名称
  String get name;

  /// 技能描述（给LLM看的）
  String get description;

  /// 技能图标（emoji）
  String get icon;

  /// 技能分类
  String get category;

  /// 参数定义列表
  List<SkillParam> get params;

  /// 是否启用
  bool get enabled => true;

  /// 执行技能
  Future<SkillResult> execute(Map<String, dynamic> args);

  /// 生成 Function Calling 的 tool 定义
  Map<String, dynamic> toFunctionTool() {
    final properties = <String, dynamic>{};
    final requiredParams = <String>[];

    for (final param in params) {
      properties[param.name] = param.toFunctionParam();
      if (param.required) {
        requiredParams.add(param.name);
      }
    }

    return {
      'type': 'function',
      'function': {
        'name': id,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          'required': requiredParams,
        },
      },
    };
  }
}
