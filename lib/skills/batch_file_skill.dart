import 'dart:io';
import 'package:path/path.dart' as p;
import '../utils/type_utils.dart';
import 'skill_base.dart';
import 'skill_file_utils.dart';

/// 批量文件操作技能
/// 
/// 支持：
/// - 批量读取多个文件
/// - 批量编辑文件（查找替换）
/// - 批量删除文件
/// - 正则搜索文件内容
class BatchFileSkill extends GooseSkill {
  @override
  String get id => 'batch_file';

  @override
  String get name => '批量文件操作';

  @override
  String get description =>
      '批量操作多个文件。支持：\n'
      '- read: 批量读取多个文件内容\n'
      '- edit: 批量编辑文件（查找替换）\n'
      '- delete: 批量删除文件\n'
      '- search: 正则搜索文件内容\n'
      '- list: 列出目录下的文件\n'
      '【注意】操作路径相对于当前工作目录';

  @override
  String get icon => '📁';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'action',
      description: '操作类型: read(读取), edit(编辑), delete(删除), search(搜索), list(列表)',
      type: 'string',
      required: true,
    ),
    const SkillParam(
      name: 'paths',
      description: '文件路径列表，多个路径用逗号分隔或使用 JSON 数组格式。例如: "file1.txt,file2.txt" 或 ["file1.txt", "file2.txt"]',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'pattern',
      description: '搜索模式。对于 search 操作是正则表达式，对于 list 操作是 glob 模式（如 "*.dart"）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'find',
      description: '查找内容（用于 edit 操作，支持正则）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'replace',
      description: '替换内容（用于 edit 操作）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'directory',
      description: '目录路径（用于 search 和 list 操作）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'recursive',
      description: '是否递归搜索子目录（用于 search 和 list 操作）',
      type: 'bool',
      required: false,
      defaultValue: true,
    ),
    const SkillParam(
      name: 'encoding',
      description: '文件编码，默认 utf-8',
      type: 'string',
      required: false,
      defaultValue: 'utf-8',
    ),
    const SkillParam(
      name: 'max_files',
      description: '最大处理文件数（防止误操作），默认 50',
      type: 'int',
      required: false,
      defaultValue: 50,
    ),
    const SkillParam(
      name: 'max_size_kb',
      description: '单文件最大大小（KB），超过则跳过，默认 1024',
      type: 'int',
      required: false,
      defaultValue: 1024,
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final action = args['action'] as String?;
    if (action == null || action.isEmpty) {
      return SkillResult.fail('请指定 action 参数');
    }

    switch (action.toLowerCase()) {
      case 'read':
        return _batchRead(args);
      case 'edit':
        return _batchEdit(args);
      case 'delete':
        return _batchDelete(args);
      case 'search':
        return _searchContent(args);
      case 'list':
        return _listFiles(args);
      default:
        return SkillResult.fail('未知操作类型: $action');
    }
  }

  /// 解析路径列表
  List<String> _parsePaths(dynamic paths) {
    if (paths == null) return [];
    
    if (paths is List) {
      return paths.map((e) => e.toString()).toList();
    }
    
    if (paths is String) {
      // 尝试解析 JSON 数组
      if (paths.trim().startsWith('[')) {
        try {
          final decoded = RegExp(r'"([^"]*)"')
              .allMatches(paths)
              .map((m) => m.group(1)!)
              .toList();
          if (decoded.isNotEmpty) return decoded;
        } catch (_) {}
      }
      // 逗号分隔
      return paths.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    }
    
    return [];
  }

  /// 获取有效工作目录
  String get _workDir => SkillFileUtils.effectiveWorkingDir;

  /// 解析文件路径（相对于工作目录）
  String _resolvePath(String path) {
    if (p.isAbsolute(path)) return path;
    return p.join(_workDir, path);
  }

  /// 批量读取文件
  Future<SkillResult> _batchRead(Map<String, dynamic> args) async {
    final paths = _parsePaths(args['paths']);
    final maxSizeKb = (args['max_size_kb'] as int?) ?? 1024;
    final maxFiles = (args['max_files'] as int?) ?? 50;
    
    if (paths.isEmpty) {
      return SkillResult.fail('请指定要读取的文件路径');
    }
    
    if (paths.length > maxFiles) {
      return SkillResult.fail('文件数量超过限制 ($maxFiles)，请减少文件数量或调整 max_files 参数');
    }
    
    final results = <Map<String, dynamic>>[];
    int totalSize = 0;
    
    for (final path in paths) {
      try {
        final filePath = _resolvePath(path);
        final file = File(filePath);
        
        if (!await file.exists()) {
          results.add({
            'path': path,
            'error': '文件不存在',
          });
          continue;
        }
        
        final size = await file.length();
        if (size > maxSizeKb * 1024) {
          results.add({
            'path': path,
            'error': '文件过大 (${(size / 1024).toStringAsFixed(1)}KB > ${maxSizeKb}KB)',
            'size': size,
          });
          continue;
        }
        
        final content = await file.readAsString();
        totalSize += size;
        
        results.add({
          'path': path,
          'content': content,
          'size': size,
          'lines': content.split('\n').length,
        });
      } catch (e) {
        results.add({
          'path': path,
          'error': e.toString(),
        });
      }
    }
    
    // 格式化输出
    final buffer = StringBuffer();
    buffer.writeln('📂 批量读取 ${paths.length} 个文件:');
    
    for (final result in results) {
      buffer.writeln();
      if (result['error'] != null) {
        buffer.writeln('❌ ${result['path']}: ${result['error']}');
      } else {
        buffer.writeln('📄 ${result['path']} (${result['lines']} 行, ${((result['size'] as int) / 1024).toStringAsFixed(1)}KB)');
        buffer.writeln('```');
        final content = result['content'] as String;
        // 限制显示行数
        final lines = content.split('\n');
        if (lines.length > 100) {
          buffer.writeln(lines.take(100).join('\n'));
          buffer.writeln('... (还有 ${lines.length - 100} 行)');
        } else {
          buffer.write(content);
        }
        buffer.writeln('\n```');
      }
    }
    
    buffer.writeln('\n📊 统计: 成功 ${results.where((r) => r['content'] != null).length} 个，失败 ${results.where((r) => r['error'] != null).length} 个');
    
    return SkillResult.ok(buffer.toString(), data: {
      'results': results,
      'total_size': totalSize,
    });
  }

  /// 批量编辑文件（查找替换）
  Future<SkillResult> _batchEdit(Map<String, dynamic> args) async {
    final paths = _parsePaths(args['paths']);
    final find = args['find'] as String?;
    final replace = args['replace'] as String? ?? '';
    final maxFiles = (args['max_files'] as int?) ?? 50;
    
    if (paths.isEmpty) {
      return SkillResult.fail('请指定要编辑的文件路径');
    }
    
    if (find == null || find.isEmpty) {
      return SkillResult.fail('请指定 find 参数（查找内容）');
    }
    
    if (paths.length > maxFiles) {
      return SkillResult.fail('文件数量超过限制 ($maxFiles)');
    }
    
    final results = <Map<String, dynamic>>[];
    int totalReplacements = 0;
    
    for (final path in paths) {
      try {
        final filePath = _resolvePath(path);
        final file = File(filePath);
        
        if (!await file.exists()) {
          results.add({
            'path': path,
            'error': '文件不存在',
          });
          continue;
        }
        
        final content = await file.readAsString();
        String newContent;
        int replacements;
        
        // 尝试作为正则表达式
        try {
          final regex = RegExp(find, multiLine: true);
          newContent = content.replaceAll(regex, replace);
          replacements = regex.allMatches(content).length;
        } catch (_) {
          // 不是有效正则，作为普通文本处理
          newContent = content.replaceAll(find, replace);
          replacements = find.allMatches(content).length;
        }
        
        if (replacements > 0) {
          await file.writeAsString(newContent);
          totalReplacements += replacements;
        }
        
        results.add({
          'path': path,
          'replacements': replacements,
        });
      } catch (e) {
        results.add({
          'path': path,
          'error': e.toString(),
        });
      }
    }
    
    // 格式化输出
    final buffer = StringBuffer();
    buffer.writeln('✏️ 批量编辑 ${paths.length} 个文件:');
    buffer.writeln('   查找: $find');
    buffer.writeln('   替换: ${replace.isEmpty ? "(空字符串)" : replace}');
    buffer.writeln();
    
    for (final result in results) {
      if (result['error'] != null) {
        buffer.writeln('❌ ${result['path']}: ${result['error']}');
      } else {
        final reps = result['replacements'] as int;
        if (reps > 0) {
          buffer.writeln('✅ ${result['path']}: 替换 $reps 处');
        } else {
          buffer.writeln('⏭️ ${result['path']}: 无匹配');
        }
      }
    }
    
    buffer.writeln('\n📊 统计: 共替换 $totalReplacements 处');
    
    return SkillResult.ok(buffer.toString(), data: {
      'results': results,
      'total_replacements': totalReplacements,
    });
  }

  /// 批量删除文件
  Future<SkillResult> _batchDelete(Map<String, dynamic> args) async {
    final paths = _parsePaths(args['paths']);
    final maxFiles = (args['max_files'] as int?) ?? 50;
    
    if (paths.isEmpty) {
      return SkillResult.fail('请指定要删除的文件路径');
    }
    
    if (paths.length > maxFiles) {
      return SkillResult.fail('文件数量超过限制 ($maxFiles)');
    }
    
    // 安全检查：不允许删除工作目录外的文件
    for (final path in paths) {
      final resolved = _resolvePath(path);
      final normalized = p.normalize(resolved);
      if (!normalized.startsWith(p.normalize(_workDir))) {
        return SkillResult.fail('安全限制: 不允许删除工作目录外的文件');
      }
    }
    
    final results = <Map<String, dynamic>>[];
    int deletedCount = 0;
    int deletedSize = 0;
    
    for (final path in paths) {
      try {
        final filePath = _resolvePath(path);
        final file = File(filePath);
        
        if (!await file.exists()) {
          results.add({
            'path': path,
            'error': '文件不存在',
          });
          continue;
        }
        
        final size = await file.length();
        await file.delete();
        deletedCount++;
        deletedSize += size;
        
        results.add({
          'path': path,
          'deleted': true,
          'size': size,
        });
      } catch (e) {
        results.add({
          'path': path,
          'error': e.toString(),
        });
      }
    }
    
    // 格式化输出
    final buffer = StringBuffer();
    buffer.writeln('🗑️ 批量删除 ${paths.length} 个文件:');
    buffer.writeln();
    
    for (final result in results) {
      if (result['error'] != null) {
        buffer.writeln('❌ ${result['path']}: ${result['error']}');
      } else {
        buffer.writeln('✅ ${result['path']} (${((result['size'] as int) / 1024).toStringAsFixed(1)}KB)');
      }
    }
    
    buffer.writeln('\n📊 统计: 删除 $deletedCount 个文件，共 ${(deletedSize / 1024).toStringAsFixed(1)}KB');
    
    return SkillResult.ok(buffer.toString(), data: {
      'results': results,
      'deleted_count': deletedCount,
      'deleted_size': deletedSize,
    });
  }

  /// 正则搜索文件内容
  Future<SkillResult> _searchContent(Map<String, dynamic> args) async {
    final pattern = args['pattern'] as String?;
    final directory = args['directory'] as String?;
    final recursive = (args['recursive'] as bool?) ?? true;
    final maxFiles = (args['max_files'] as int?) ?? 100;
    
    if (pattern == null || pattern.isEmpty) {
      return SkillResult.fail('请指定 pattern 参数（正则表达式）');
    }
    
    final searchDir = directory != null && directory.isNotEmpty
        ? _resolvePath(directory)
        : _workDir;
    
    RegExp regex;
    try {
      regex = RegExp(pattern, multiLine: true);
    } catch (e) {
      return SkillResult.fail('无效的正则表达式: $e');
    }
    
    final results = <Map<String, dynamic>>[];
    int totalMatches = 0;
    int filesSearched = 0;
    
    try {
      final dir = Directory(searchDir);
      if (!await dir.exists()) {
        return SkillResult.fail('目录不存在: $searchDir');
      }
      
      final entities = recursive
          ? dir.list(recursive: true)
          : dir.list(recursive: false);
      
      await for (final entity in entities) {
        if (filesSearched >= maxFiles) break;
        if (entity is! File) continue;
        
        // 跳过二进制文件和隐藏文件
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        
        final ext = p.extension(name).toLowerCase();
        const binaryExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.pdf', '.zip', '.tar', '.gz', '.mp4', '.mp3', '.wav', '.exe', '.dll', '.so', '.dylib'};
        if (binaryExts.contains(ext)) continue;
        
        filesSearched++;
        
        try {
          final content = await entity.readAsString();
          final matches = regex.allMatches(content);
          
          if (matches.isNotEmpty) {
            final relativePath = p.relative(entity.path, from: _workDir);
            final matchList = <Map<String, dynamic>>[];
            int matchCount = 0;
            
            for (final match in matches) {
              if (matchCount >= 50) break; // 每个文件最多显示 50 个匹配
              
              // 获取行号
              final before = content.substring(0, match.start);
              final lineNumber = '\n'.allMatches(before).length + 1;
              
              // 获取上下文
              final lines = content.split('\n');
              final lineContent = lineNumber <= lines.length ? lines[lineNumber - 1] : '';
              
              matchList.add({
                'line': lineNumber,
                'match': match.group(0),
                'context': lineContent.trim(),
              });
              matchCount++;
              totalMatches++;
            }
            
            results.add({
              'path': relativePath,
              'matches': matchList,
              'total_matches': matches.length,
            });
          }
        } catch (_) {
          // 跳过无法读取的文件
        }
      }
    } catch (e) {
      return SkillResult.fail('搜索失败: $e');
    }
    
    // 格式化输出
    final buffer = StringBuffer();
    buffer.writeln('🔍 正则搜索: $pattern');
    buffer.writeln('   目录: ${p.relative(searchDir, from: _workDir)}');
    buffer.writeln('   搜索了 $filesSearched 个文件');
    buffer.writeln();
    
    for (final result in results.take(20)) {
      buffer.writeln('📄 ${result['path']} (${result['total_matches']} 处匹配)');
      for (final match in (result['matches'] as List).take(5)) {
        final m = safeMap(match);
        buffer.writeln('   L${m['line']}: ${m['context']}');
      }
      if ((result['matches'] as List).length > 5) {
        buffer.writeln('   ... 还有 ${(result['matches'] as List).length - 5} 处');
      }
      buffer.writeln();
    }
    
    if (results.length > 20) {
      buffer.writeln('... 还有 ${results.length - 20} 个文件有匹配');
    }
    
    buffer.writeln('📊 统计: ${results.length} 个文件，共 $totalMatches 处匹配');
    
    return SkillResult.ok(buffer.toString(), data: {
      'results': results,
      'total_matches': totalMatches,
      'files_searched': filesSearched,
    });
  }

  /// 列出目录下的文件
  Future<SkillResult> _listFiles(Map<String, dynamic> args) async {
    final pattern = args['pattern'] as String? ?? '*';
    final directory = args['directory'] as String?;
    final recursive = (args['recursive'] as bool?) ?? false;
    
    final listDir = directory != null && directory.isNotEmpty
        ? _resolvePath(directory)
        : _workDir;
    
    final results = <Map<String, dynamic>>[];
    int totalSize = 0;
    int totalFiles = 0;
    int totalDirs = 0;
    
    try {
      final dir = Directory(listDir);
      if (!await dir.exists()) {
        return SkillResult.fail('目录不存在: $listDir');
      }
      
      final globPattern = pattern.replaceAll('*', '.*').replaceAll('?', '.');
      final globRegex = RegExp('^$globPattern\$', caseSensitive: false);
      
      final entities = recursive
          ? dir.list(recursive: true)
          : dir.list(recursive: false);
      
      await for (final entity in entities) {
        final name = p.basename(entity.path);
        
        // 应用 glob 过滤
        if (!globRegex.hasMatch(name) && pattern != '*') continue;
        
        if (entity is File) {
          final size = await entity.length();
          totalSize += size;
          totalFiles++;
          results.add({
            'name': name,
            'path': p.relative(entity.path, from: _workDir),
            'type': 'file',
            'size': size,
          });
        } else if (entity is Directory) {
          totalDirs++;
          results.add({
            'name': name,
            'path': p.relative(entity.path, from: _workDir),
            'type': 'directory',
          });
        }
      }
    } catch (e) {
      return SkillResult.fail('列出文件失败: $e');
    }
    
    // 排序：目录在前，然后按名称
    results.sort((a, b) {
      if (a['type'] != b['type']) {
        return a['type'] == 'directory' ? -1 : 1;
      }
      return (a['name'] as String).compareTo(b['name'] as String);
    });
    
    // 格式化输出
    final buffer = StringBuffer();
    buffer.writeln('📂 目录列表: ${p.relative(listDir, from: _workDir)}');
    buffer.writeln('   模式: $pattern');
    buffer.writeln();
    
    for (final result in results.take(50)) {
      if (result['type'] == 'directory') {
        buffer.writeln('📁 ${result['name']}/');
      } else {
        final size = result['size'] as int;
        buffer.writeln('📄 ${result['name']} (${_formatSize(size)})');
      }
    }
    
    if (results.length > 50) {
      buffer.writeln('... 还有 ${results.length - 50} 个');
    }
    
    buffer.writeln('\n📊 统计: $totalFiles 个文件，$totalDirs 个目录，共 ${_formatSize(totalSize)}');
    
    return SkillResult.ok(buffer.toString(), data: {
      'results': results,
      'total_files': totalFiles,
      'total_dirs': totalDirs,
      'total_size': totalSize,
    });
  }
  
  String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}
