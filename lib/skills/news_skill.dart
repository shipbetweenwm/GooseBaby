import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../utils/type_utils.dart';
import 'skill_base.dart';

/// 新闻获取技能
///
/// 使用 Free News API 获取最新新闻（免费，无需 API Key）
/// 支持按语言、地区、关键词筛选
class NewsSkill extends GooseSkill {
  /// HTTP 客户端
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  /// API 端点
  static const String _baseUrl = 'https://www.freenewsapi.com';

  @override
  String get id => 'news';

  @override
  String get name => '新闻获取';

  @override
  String get description =>
      '获取最新新闻资讯。使用 Free News API，免费无需 API Key。\n'
      '支持按语言（chinese/english/japanese等）、地区（cn/us/jp等）、关键词筛选。\n'
      '适合用于定时任务，每天推送新闻摘要。';

  @override
  String get icon => '📰';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'language',
      description: '新闻语言: chinese(默认)、english、japanese、korean 等',
      type: 'string',
      required: false,
      defaultValue: 'chinese',
    ),
    const SkillParam(
      name: 'region',
      description: '新闻地区: cn(中国)、us(美国)、jp(日本)、kr(韩国) 等',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'keyword',
      description: '关键词搜索，如 "人工智能"、"科技" 等',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'max_results',
      description: '返回新闻数量，默认 5 条，最多 10 条',
      type: 'int',
      required: false,
      defaultValue: 5,
    ),
    const SkillParam(
      name: 'format',
      description: '输出格式: summary(摘要列表，默认)、bubble(适合气泡展示的单条)',
      type: 'string',
      required: false,
      defaultValue: 'summary',
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final language = args['language'] as String? ?? 'chinese';
    final region = args['region'] as String?;
    final keyword = args['keyword'] as String?;
    final maxResults = ((args['max_results'] as int?) ?? 5).clamp(1, 10);
    final format = args['format'] as String? ?? 'summary';

    try {
      // 构建 URL
      String url;
      if (keyword != null && keyword.isNotEmpty) {
        // 关键词搜索
        url = '$_baseUrl/k/${Uri.encodeComponent(keyword)}';
      } else if (region != null && region.isNotEmpty) {
        // 按地区
        url = '$_baseUrl/r/$region';
      } else {
        // 按语言
        url = '$_baseUrl/l/$language';
      }

      debugPrint('📰 正在获取新闻: $url');

      final response = await _dio.get(
        url,
        options: Options(headers: {
          'Accept': 'application/json',
          'User-Agent': 'GooseBaby/1.0',
        }),
      );

      if (response.statusCode != 200) {
        return SkillResult.fail('获取新闻失败: HTTP ${response.statusCode}');
      }

      final data = response.data;
      if (data is! List || data.isEmpty) {
        return SkillResult.fail('暂无新闻数据');
      }

      // 解析新闻列表
      final news = <Map<String, dynamic>>[];
      for (final item in data.take(maxResults)) {
        final map = safeMap(item);
        news.add({
          'title': map['title'] ?? '无标题',
          'url': map['url'] ?? '',
          'domain': map['domain'] ?? '',
          'region': map['region'] ?? '',
          'lang': map['lang'] ?? '',
          'timestamp': map['sec'] ?? 0,
        });
      }

      // 格式化输出
      if (format == 'bubble') {
        // 单条格式，适合气泡展示
        final item = news.first;
        final title = item['title'] as String;
        final shortTitle = title.length > 40 ? '${title.substring(0, 40)}...' : title;
        return SkillResult.ok('📰 $shortTitle', data: {'news': news});
      } else {
        // 摘要列表格式
        final buffer = StringBuffer();
        buffer.writeln('## 📰 新闻速递 (${news.length} 条)');
        buffer.writeln();
        
        for (int i = 0; i < news.length; i++) {
          final item = news[i];
          final title = item['title'] as String;
          buffer.writeln('${i + 1}. $title');
        }
        
        return SkillResult.ok(buffer.toString().trim(), data: {'news': news});
      }
    } on DioException catch (e) {
      debugPrint('📰 获取新闻异常: ${e.message}');
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return SkillResult.fail('获取新闻超时，请稍后重试');
      }
      return SkillResult.fail('获取新闻失败: ${e.message}');
    } catch (e) {
      debugPrint('📰 获取新闻异常: $e');
      return SkillResult.fail('获取新闻异常: $e');
    }
  }
}
