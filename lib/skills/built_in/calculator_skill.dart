import '../skill_base.dart';

/// 计算器技能
class CalculatorSkill extends GooseSkill {
  @override
  String get id => 'calculator';

  @override
  String get name => '计算器';

  @override
  String get description => '进行数学计算，支持加减乘除、百分比、单位换算等';

  @override
  String get icon => '🔢';

  @override
  String get category => '效率工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'expression',
      description: '数学表达式，例如 "123 + 456"、"15% * 200"、"sqrt(144)"',
      type: 'string',
      required: true,
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args) async {
    final expression = args['expression'] as String?;
    if (expression == null || expression.isEmpty) {
      return SkillResult.fail('请给鹅宝一个算式~');
    }

    try {
      final result = _evaluate(expression.trim());
      final formatted = _formatNumber(result);
      return SkillResult.ok(
        '$expression = $formatted',
        data: {'expression': expression, 'result': result},
      );
    } catch (e) {
      return SkillResult.fail('鹅宝算不出来呢: $e');
    }
  }

  double _evaluate(String expr) {
    // 预处理: 替换常见写法
    var processed = expr
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('（', '(')
        .replaceAll('）', ')')
        .replaceAll('%', '/100')
        .replaceAll(RegExp(r'\s+'), '');

    // 处理 sqrt
    processed = processed.replaceAllMapped(
      RegExp(r'sqrt\(([^)]+)\)'),
      (m) {
        final inner = _evaluate(m.group(1)!);
        return _sqrt(inner).toString();
      },
    );

    // 处理 pow
    processed = processed.replaceAllMapped(
      RegExp(r'pow\(([^,]+),([^)]+)\)'),
      (m) {
        final base = _evaluate(m.group(1)!);
        final exp = _evaluate(m.group(2)!);
        return _pow(base, exp).toString();
      },
    );

    return _parseExpression(processed, 0).$1;
  }

  (double, int) _parseExpression(String expr, int pos) {
    var (left, i) = _parseTerm(expr, pos);

    while (i < expr.length && (expr[i] == '+' || expr[i] == '-')) {
      final op = expr[i];
      i++;
      final (right, nextI) = _parseTerm(expr, i);
      i = nextI;
      left = op == '+' ? left + right : left - right;
    }

    return (left, i);
  }

  (double, int) _parseTerm(String expr, int pos) {
    var (left, i) = _parseFactor(expr, pos);

    while (i < expr.length && (expr[i] == '*' || expr[i] == '/')) {
      final op = expr[i];
      i++;
      final (right, nextI) = _parseFactor(expr, i);
      i = nextI;
      if (op == '*') {
        left = left * right;
      } else {
        if (right == 0) throw Exception('不能除以零哦');
        left = left / right;
      }
    }

    return (left, i);
  }

  (double, int) _parseFactor(String expr, int pos) {
    // 处理负号
    if (pos < expr.length && expr[pos] == '-') {
      final (value, i) = _parseFactor(expr, pos + 1);
      return (-value, i);
    }

    // 处理括号
    if (pos < expr.length && expr[pos] == '(') {
      final (value, i) = _parseExpression(expr, pos + 1);
      if (i < expr.length && expr[i] == ')') {
        return (value, i + 1);
      }
      throw Exception('括号不匹配');
    }

    // 解析数字
    var i = pos;
    while (i < expr.length && (RegExp(r'[0-9.]').hasMatch(expr[i]))) {
      i++;
    }

    if (i == pos) {
      throw Exception('无法解析: ${expr.substring(pos)}');
    }

    return (double.parse(expr.substring(pos, i)), i);
  }

  double _sqrt(double x) {
    if (x < 0) throw Exception('负数不能开平方根哦');
    double guess = x / 2;
    for (int i = 0; i < 100; i++) {
      final next = (guess + x / guess) / 2;
      if ((next - guess).abs() < 1e-10) return next;
      guess = next;
    }
    return guess;
  }

  double _pow(double base, double exp) {
    if (exp == 0) return 1;
    if (exp == 1) return base;
    if (exp == exp.toInt().toDouble()) {
      double result = 1;
      final n = exp.toInt().abs();
      for (int i = 0; i < n; i++) {
        result *= base;
      }
      return exp > 0 ? result : 1 / result;
    }
    // 简单近似
    return base * _pow(base, exp - 1);
  }

  String _formatNumber(double num) {
    if (num == num.toInt().toDouble()) {
      return num.toInt().toString();
    }
    // 保留合理小数位
    final str = num.toStringAsFixed(6);
    return str.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
}
