import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../utils/type_utils.dart';
import 'skill_base.dart';
import 'skill_file_utils.dart';

/// Agent 技能 - 支持类 Claude Code（龙虾）格式的 SKILL.md 技能
///
/// ### 完整目录结构（遵循 agentskills.io 规范）
/// ```
/// skill-name/
///   SKILL.md          ← 必需：YAML frontmatter + Markdown 内容（技能说明书）
///   _meta.json        ← 可选：元数据（ownerId, slug, version, publishedAt）
///   scripts/          ← 可选：可执行脚本目录
///     fetch.js
///     helper.sh
///     process.py
///   references/       ← 可选：参考文档目录
///     REFERENCE.md
///     EXAMPLES.md
///   assets/           ← 可选：模板和资源文件
/// ```
///
/// ### SKILL.md 格式
/// ```markdown
/// ---
/// name: Agent Browser
/// description: A fast headless browser automation CLI...
/// read_when:
///   - Automating web interactions
///   - Extracting structured data from pages
/// metadata: {"clawdbot":{"emoji":"🌐","requires":{"bins":["node","npm"]}}}
/// allowed-tools: Bash(agent-browser:*)
/// ---
///
/// # Browser Automation with agent-browser
///
/// 运行脚本：scripts/extract.py
/// 参考文档：[详情](references/REFERENCE.md)
/// ```
///
/// ### 工作原理
/// Agent Skill 不直接执行规则引擎，而是：
/// 1. 将 SKILL.md 的内容注入到 LLM 的 system prompt 中
/// 2. 扫描 scripts/ 目录中的可执行脚本，告知 LLM 可调用的脚本列表
/// 3. 按需加载 references/ 中的参考文档，补充到上下文中
/// 4. LLM 根据说明书内容理解如何使用该工具
/// 5. 当用户请求相关功能时，LLM 生成 shell 命令或调用本地脚本
/// 6. 鹅宝执行命令（支持 scripts/ 下脚本的相对路径解析）并反馈结果
class AgentSkill extends GooseSkill {
  final String _id;
  final String _name;
  final String _description;
  final String _icon;
  final String _category;

  /// SKILL.md 的完整 Markdown 内容（包含使用说明）
  final String markdownContent;

  /// YAML frontmatter 中的 read_when 条件列表
  final List<String> readWhen;

  /// YAML frontmatter 中的 allowed-tools 配置
  final String allowedTools;

  /// YAML frontmatter 中的 license（agentskills.io 标准字段）
  final String license;

  /// YAML frontmatter 中的 compatibility（agentskills.io 标准字段，描述环境要求）
  final String compatibility;

  /// _meta.json 中的元数据
  final AgentSkillMeta? meta;

  /// YAML frontmatter 中的 metadata（如 requires 等）
  final Map<String, dynamic> frontmatterMetadata;

  /// 技能来源目录路径
  final String? sourcePath;

  /// 需要的外部依赖（如 node, npm 等）
  final List<String> requiredBins;

  /// scripts/ 目录下的脚本文件列表（相对路径，如 "scripts/fetch.js"）
  final List<SkillScript> scripts;

  /// references/ 目录下的参考文档列表（相对路径，如 "references/REFERENCE.md"）
  final List<String> referenceFiles;

  /// assets/ 目录下的资源文件列表
  final List<String> assetFiles;

  AgentSkill({
    required String id,
    required String name,
    required String description,
    String icon = '🤖',
    String category = 'Agent 技能',
    required this.markdownContent,
    this.readWhen = const [],
    this.allowedTools = '',
    this.license = '',
    this.compatibility = '',
    this.meta,
    this.frontmatterMetadata = const {},
    this.sourcePath,
    this.requiredBins = const [],
    this.scripts = const [],
    this.referenceFiles = const [],
    this.assetFiles = const [],
  })  : _id = id,
        _name = name,
        _description = description,
        _icon = icon,
        _category = category;

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

  /// Agent 技能的参数：command（shell 命令）或 script + script_args（本地脚本调用）
  @override
  List<SkillParam> get params => [
        const SkillParam(
          name: 'command',
          description: '要执行的 shell 命令（由 AI 根据 SKILL.md 说明书生成）。'
              '也可以直接填写 scripts/ 下的脚本相对路径（如 "scripts/fetch.js arg1 arg2"），'
              '系统会自动解析为技能目录下的绝对路径执行。',
          type: 'string',
          required: true,
        ),
      ];

  /// 执行 Agent 技能 = 执行 shell 命令或本地脚本
  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final rawCommand = args['command'] as String? ?? '';
    if (rawCommand.isEmpty) {
      return SkillResult.fail('未提供要执行的命令');
    }

    // 运行时依赖检查：确保 requiredBins 中的二进制可用
    if (requiredBins.isNotEmpty) {
      final missingBins = await _checkRequiredBins();
      if (missingBins.isNotEmpty) {
        return SkillResult.fail(
          '缺少必要依赖: ${missingBins.join(", ")}\n'
          '请先安装这些工具并确保已添加到系统 PATH。',
        );
      }
    }

    // 解析命令：如果引用了 scripts/ 下的脚本，自动替换为绝对路径
    final command = _resolveScriptPaths(rawCommand);

    // 安全检查：只允许执行 allowed-tools 配置的命令或 scripts/ 下的脚本
    if (!_isCommandAllowed(command) && !_isLocalScript(rawCommand)) {
      return SkillResult.fail('命令不在允许范围内: $command\n允许的工具: $allowedTools');
    }

    // 如果是本地脚本，额外校验脚本文件存在性
    if (_isLocalScript(rawCommand)) {
      final scriptPath = _extractScriptPath(rawCommand);
      if (scriptPath != null && !File(scriptPath).existsSync()) {
        return SkillResult.fail('脚本文件不存在: $scriptPath');
      }
    }

    try {
      debugPrint('🤖 Agent Skill [$name] 执行命令: $command');

      // 工作目录设为技能目录，这样脚本内的相对路径引用也能正常工作
      final workDir = sourcePath;

      // 记录执行前已有文件（用于 diff，只收集新生成的文件）
      final existingFiles =
          workDir != null ? await SkillFileUtils.listFilePaths(workDir) : <String>{};

      ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run(
          'cmd',
          ['/c', command],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
          workingDirectory: workDir,
        ).timeout(const Duration(seconds: 120));
      } else {
        result = await Process.run(
          'bash',
          ['-c', command],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
          workingDirectory: workDir,
        ).timeout(const Duration(seconds: 120));
      }

      final stdout = (result.stdout as String).trim();
      final stderr = (result.stderr as String).trim();

      // 收集新生成的文件
      final outputFiles = workDir != null
          ? await SkillFileUtils.collectNewFiles(workDir, existingFiles)
          : <Map<String, dynamic>>[];

      if (result.exitCode == 0) {
        debugPrint('🤖 Agent Skill [$name] 命令执行成功');
        return SkillResult.ok(
          stdout.isNotEmpty ? stdout : '命令执行成功（无输出）',
          data: {
            'exitCode': result.exitCode,
            'stdout': stdout,
            'stderr': stderr,
            'command': command,
            'outputFiles': outputFiles,
          },
        );
      } else {
        debugPrint('🤖 Agent Skill [$name] 命令执行失败: exit=${result.exitCode}');
        return SkillResult.fail(
          '命令执行失败 (exit code: ${result.exitCode})\n'
          '${stderr.isNotEmpty ? "错误: $stderr" : ""}'
          '${stdout.isNotEmpty ? "\n输出: $stdout" : ""}',
        );
      }
    } on TimeoutException {
      return SkillResult.fail('命令执行超时（120秒），请检查命令是否正常');
    } catch (e) {
      debugPrint('🤖 Agent Skill [$name] 执行异常: $e');
      return SkillResult.fail('命令执行异常: $e');
    }
  }

  /// 解析命令中的脚本相对路径，替换为绝对路径
  /// 支持格式：
  ///   - "scripts/fetch.js arg1" → "绝对路径/scripts/fetch.js arg1"
  ///   - "python scripts/process.py" → "python 绝对路径/scripts/process.py"
  ///   - "./scripts/helper.sh" → "绝对路径/scripts/helper.sh"
  /// 会自动处理 ZIP 包内多层目录的情况
  String _resolveScriptPaths(String command) {
    if (sourcePath == null) return command;

    String resolved = command;

    // 模式 1：命令以 "scripts/" 或 "./scripts/" 开头
    if (resolved.startsWith('scripts/') || resolved.startsWith('./scripts/')) {
      final clean = resolved.startsWith('./') ? resolved.substring(2) : resolved;
      final scriptPath = _findActualScriptPath(clean);
      resolved = scriptPath;
    }
    // 模式 2：命令中包含 " scripts/" 参数（如 "python scripts/xxx.py arg1"）
    else if (resolved.contains(' scripts/')) {
      resolved = _replaceScriptPath(resolved, ' scripts/');
    }
    // 模式 3：命令中包含 " ./scripts/"
    else if (resolved.contains(' ./scripts/')) {
      resolved = _replaceScriptPath(resolved, ' ./scripts/');
    }

    // 统一路径分隔符（Windows 下将 / 替换为 \）
    if (Platform.isWindows) {
      resolved = resolved.replaceAll('/', '\\');
    }

    return resolved;
  }

  /// 查找脚本的实际路径（处理 ZIP 包多层目录问题）
  String _findActualScriptPath(String scriptRelPath) {
    final sep = Platform.isWindows ? '\\' : '/';
    
    // 1. 直接拼接 sourcePath
    final directPath = '$sourcePath$sep$scriptRelPath';
    if (File(directPath).existsSync()) {
      return directPath;
    }
    
    // 2. 在父目录中查找（处理 ZIP 包一层包裹的情况）
    final parentDir = Directory(sourcePath!).parent;
    try {
      for (final entity in parentDir.listSync()) {
        if (entity is Directory) {
          final candidatePath = '${entity.path}$sep$scriptRelPath';
          if (File(candidatePath).existsSync()) {
            debugPrint('🤖 脚本路径修正: $directPath → $candidatePath');
            return candidatePath;
          }
        }
      }
    } catch (_) {}
    
    // 3. 都找不到，返回原始路径（后续会报文件不存在错误）
    return directPath;
  }

  /// 替换命令中的脚本路径
  String _replaceScriptPath(String command, String pattern) {
    final idx = command.indexOf(pattern);
    if (idx < 0) return command;
    
    // 提取 scripts/xxx 部分
    final afterPattern = command.substring(idx + pattern.length);
    final spaceIdx = afterPattern.indexOf(' ');
    final scriptPart = spaceIdx > 0 ? afterPattern.substring(0, spaceIdx) : afterPattern;
    final restPart = spaceIdx > 0 ? afterPattern.substring(spaceIdx) : '';
    
    final scriptRelPath = 'scripts/$scriptPart';
    final actualPath = _findActualScriptPath(scriptRelPath);
    
    return command.substring(0, idx) + ' ' + actualPath + restPart;
  }

  /// 检查命令是否引用了 scripts/ 下的本地脚本
  bool _isLocalScript(String command) {
    final cmd = command.trim();
    return cmd.startsWith('scripts/') ||
        cmd.startsWith('./scripts/') ||
        cmd.contains(' scripts/') ||
        cmd.contains(' ./scripts/');
  }

  /// 从命令中提取脚本的绝对路径（用于存在性校验）
  /// 会自动处理 ZIP 包内多层目录的情况
  String? _extractScriptPath(String command) {
    if (sourcePath == null) return null;
    final sep = Platform.isWindows ? '\\' : '/';

    // 提取 "scripts/xxx" 部分
    final scriptPattern = RegExp(r'(?:^|\s)\.?/?scripts/(\S+)');
    final match = scriptPattern.firstMatch(command);
    if (match != null) {
      final relPath = 'scripts/${match.group(1)!}';
      // 只取脚本文件名部分（去掉后续参数）
      final parts = relPath.split(' ');
      final scriptRelPath = parts[0];
      
      // 尝试多种可能的路径
      final candidatePaths = <String>[
        // 1. 直接拼接 sourcePath
        '$sourcePath$sep$scriptRelPath',
        // 2. sourcePath 可能已经是子目录，尝试向上查找
        ..._findScriptInParentDirs(sourcePath!, scriptRelPath),
      ];
      
      for (final path in candidatePaths) {
        if (File(path).existsSync()) {
          return path;
        }
      }
      
      // 都不存在，返回默认路径（后续会报文件不存在错误）
      return '$sourcePath$sep$scriptRelPath';
    }
    return null;
  }

  /// 在父目录中查找脚本文件（处理 ZIP 包多层目录问题）
  List<String> _findScriptInParentDirs(String basePath, String scriptRelPath) {
    final results = <String>[];
    final sep = Platform.isWindows ? '\\' : '/';
    
    // 向上最多查找 2 层目录
    String currentPath = basePath;
    for (int i = 0; i < 2; i++) {
      final parentDir = Directory(currentPath).parent;
      if (parentDir.path == currentPath) break; // 已到达根目录
      
      // 在父目录的子目录中查找 scripts/
      try {
        for (final entity in parentDir.listSync()) {
          if (entity is Directory) {
            final candidatePath = '${entity.path}$sep$scriptRelPath';
            if (File(candidatePath).existsSync()) {
              results.add(candidatePath);
            }
          }
        }
      } catch (_) {}
      
      currentPath = parentDir.path;
    }
    
    return results;
  }

  /// 检查命令是否在允许范围内
  bool _isCommandAllowed(String command) {
    // 本地脚本始终允许（已有路径安全校验）
    if (_isLocalScript(command)) {
      return _isScriptPathSafe(command);
    }

    if (allowedTools.isEmpty) return true; // 未配置限制时允许所有

    // 检查 allowed-tools 中是否包含 "Bash" 关键字（允许所有 Bash 命令）
    if (allowedTools.contains('Bash') && !allowedTools.contains('Bash(')) {
      return true;
    }

    // 解析 allowed-tools 格式，如 "Bash(agent-browser:*)"
    // 提取允许的命令前缀
    final allowedPrefixes = _parseAllowedTools(allowedTools);
    if (allowedPrefixes.isEmpty) return true;

    final cmdLower = command.trim().toLowerCase();
    return allowedPrefixes.any((prefix) => cmdLower.startsWith(prefix.toLowerCase()));
  }

  /// 安全检查：确保脚本路径没有目录遍历攻击（如 ../）
  bool _isScriptPathSafe(String command) {
    if (sourcePath == null) return false;

    // 提取脚本路径部分
    final scriptPattern = RegExp(r'(?:^|\s)\.?/?scripts/(\S+)');
    final match = scriptPattern.firstMatch(command);
    if (match == null) return false;

    final scriptRelPath = match.group(1)!;

    // 禁止目录遍历
    if (scriptRelPath.contains('..')) {
      debugPrint('🤖 安全拦截：脚本路径包含 ".." 遍历: $scriptRelPath');
      return false;
    }

    // 禁止绝对路径
    if (scriptRelPath.startsWith('/') || scriptRelPath.contains(':')) {
      debugPrint('🤖 安全拦截：脚本路径是绝对路径: $scriptRelPath');
      return false;
    }

    return true;
  }

  /// 解析 allowed-tools 字符串
  /// 支持格式：
  ///   - "Bash(agent-browser:*)" → ["agent-browser"]
  ///   - "Bash(npm:*, node:*)" → ["npm", "node"]
  ///   - "agent-browser" → ["agent-browser"]
  static List<String> _parseAllowedTools(String allowedTools) {
    final prefixes = <String>[];

    // 匹配 Bash(xxx:*) 格式
    final bashPattern = RegExp(r'Bash\(([^)]+)\)');
    final bashMatch = bashPattern.firstMatch(allowedTools);
    if (bashMatch != null) {
      final inner = bashMatch.group(1)!;
      // 解析逗号分隔的 "tool:*" 或 "tool:command" 格式
      for (final part in inner.split(',')) {
        final colonIdx = part.trim().indexOf(':');
        if (colonIdx > 0) {
          prefixes.add(part.trim().substring(0, colonIdx));
        } else {
          prefixes.add(part.trim());
        }
      }
    } else {
      // 简单格式：直接作为命令前缀
      for (final part in allowedTools.split(',')) {
        final trimmed = part.trim();
        if (trimmed.isNotEmpty) {
          prefixes.add(trimmed);
        }
      }
    }

    return prefixes;
  }

  /// Level 1: 轻量元数据提示（~100 tokens），始终注入 system prompt（OpenClaw 目录模式）
  /// 仅包含 name + description + location，让 LLM 判断是否需要激活此技能
  String getPromptInjection() {
    final sb = StringBuffer();
    sb.writeln('- **$name** (`$name`)');
    sb.writeln('  $description');
    return sb.toString();
  }

  /// Level 2: 完整使用说明（< 5000 tokens），在技能被调用时注入
  /// 包含 SKILL.md 正文、可用脚本、资源文件列表
  String getLevel2Prompt() {
    final sb = StringBuffer();
    sb.writeln('\n### $name 使用说明');
    sb.writeln(markdownContent);

    // 注入可用脚本列表
    if (scripts.isNotEmpty) {
      sb.writeln();
      sb.writeln('#### 可用脚本');
      sb.writeln('此技能的 scripts/ 目录下包含以下可执行脚本，你可以直接在 command 参数中调用：');
      for (final script in scripts) {
        sb.write('- `scripts/${script.relativePath}`');
        if (script.description.isNotEmpty) {
          sb.write(' — ${script.description}');
        }
        sb.writeln(' (${script.language})');
      }
      sb.writeln();
      sb.writeln('调用脚本示例：`scripts/helper.sh arg1 arg2`（会自动解析为技能目录下的绝对路径执行）');
    }

    // 注入可用资产文件列表
    if (assetFiles.isNotEmpty) {
      sb.writeln();
      sb.writeln('#### 可用资源文件');
      sb.writeln('此技能的 assets/ 目录下包含以下资源文件：');
      for (final asset in assetFiles) {
        sb.writeln('- `assets/$asset`');
      }
      sb.writeln('你可以在命令中引用这些资源文件的绝对路径来使用它们。');
    }

    // 注入参考文档列表（内容在 Level 3 按需加载）
    if (referenceFiles.isNotEmpty) {
      sb.writeln();
      sb.writeln('#### 参考文档');
      sb.writeln('此技能附带以下参考文档：');
      for (final ref in referenceFiles) {
        sb.writeln('- `$ref`');
      }
    }

    return sb.toString();
  }

  /// 按需加载参考文档内容（用于扩展上下文）
  Future<String> loadReferenceContent() async {
    if (sourcePath == null || referenceFiles.isEmpty) return '';

    final sb = StringBuffer();
    for (final refFile in referenceFiles) {
      final file = File('$sourcePath/$refFile');
      if (await file.exists()) {
        try {
          final content = await file.readAsString(encoding: utf8);
          sb.writeln('\n### 参考文档: $refFile');
          sb.writeln(content);
        } catch (e) {
          debugPrint('🤖 加载参考文档失败: $refFile - $e');
        }
      }
    }
    return sb.toString();
  }

  /// 从 SKILL.md 文件和可选的 _meta.json 解析创建 AgentSkill
  static Future<AgentSkill?> fromDirectory(String dirPath) async {
    try {
      final skillMdFile = File('$dirPath/SKILL.md');
      if (!await skillMdFile.exists()) return null;

      // 使用 allowMalformed 防止非 UTF-8 文件导致 FormatException
      final mdBytes = await skillMdFile.readAsBytes();
      final mdContent = const Utf8Decoder(allowMalformed: true).convert(mdBytes);

      // 解析 YAML frontmatter
      final frontmatter = _parseFrontmatter(mdContent);
      final body = _extractBody(mdContent);

      // 解析 _meta.json（可选）
      AgentSkillMeta? meta;
      final metaFile = File('$dirPath/_meta.json');
      if (await metaFile.exists()) {
        try {
          final metaContent = await metaFile.readAsString(encoding: utf8);
          final metaJson = safeMap(jsonDecode(metaContent));
          meta = AgentSkillMeta.fromJson(metaJson);
        } catch (e) {
          debugPrint('🤖 _meta.json 解析失败: $e');
        }
      }

      // 提取字段
      final name = frontmatter['name'] as String? ?? _dirName(dirPath);
      final description = frontmatter['description'] as String? ?? '';
      final readWhen = _parseStringList(frontmatter['read_when']);
      final allowedTools = frontmatter['allowed-tools'] as String? ?? '';
      final license = frontmatter['license'] as String? ?? '';
      final compatibility = frontmatter['compatibility'] as String? ?? '';

      // agentskills.io name 规范校验
      _validateSkillName(name, dirPath);

      // SKILL.md 行数建议校验
      _validateSkillMdLength(body, name);

      // 解析 metadata 中的 emoji 和 requires
      String icon = '🤖';
      List<String> requiredBins = [];
      Map<String, dynamic> fmMetadata = {};

      final metadataRaw = frontmatter['metadata'];
      if (metadataRaw is String) {
        try {
          fmMetadata = safeMap(jsonDecode(metadataRaw));
        } catch (_) {}
      } else if (metadataRaw is Map) {
        fmMetadata = Map<String, dynamic>.from(metadataRaw);
      }

      // 提取 emoji
      if (fmMetadata.containsKey('clawdbot')) {
        final cb = fmMetadata['clawdbot'] is Map ? safeMap(fmMetadata['clawdbot']) : {};
        icon = cb['emoji'] as String? ?? '🤖';
        final requires = cb['requires'] is Map ? safeMap(cb['requires']) : {};
        requiredBins = _parseStringList(requires['bins']);
      }

      // 生成 ID：优先用 meta.slug，否则用目录名
      final id = meta?.slug ?? _dirName(dirPath).replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

      // 扫描 scripts/ 目录
      final scriptsList = await _scanScriptsDir(dirPath);

      // 扫描 references/ 目录
      final refFiles = await _scanSubDir(dirPath, 'references');

      // 扫描 assets/ 目录
      final assetFilesList = await _scanSubDir(dirPath, 'assets');

      debugPrint('🤖 加载 Agent Skill: $name ($id) from $dirPath'
          '${scriptsList.isNotEmpty ? " [${scriptsList.length} scripts]" : ""}'
          '${refFiles.isNotEmpty ? " [${refFiles.length} refs]" : ""}');

      return AgentSkill(
        id: id,
        name: name,
        description: description,
        icon: icon,
        category: 'Agent 技能',
        markdownContent: body,
        readWhen: readWhen,
        allowedTools: allowedTools,
        license: license,
        compatibility: compatibility,
        meta: meta,
        frontmatterMetadata: fmMetadata,
        sourcePath: dirPath,
        requiredBins: requiredBins,
        scripts: scriptsList,
        referenceFiles: refFiles,
        assetFiles: assetFilesList,
      );
    } catch (e) {
      debugPrint('🤖 Agent Skill 加载失败: $dirPath - $e');
      return null;
    }
  }

  /// 从实体路径中安全提取相对于基础目录的相对路径
  /// Windows 兼容：处理路径分隔符不一致的问题
  static String _safeRelPath(String entityPath, String basePath) {
    // 统一分隔符为 /
    final normalized = entityPath.replaceAll('\\', '/');
    final baseNormalized = basePath.replaceAll('\\', '/');
    String rel = normalized;
    if (rel.startsWith(baseNormalized)) {
      rel = rel.substring(baseNormalized.length);
      // 去掉开头的 /
      if (rel.startsWith('/')) rel = rel.substring(1);
    }
    return rel;
  }

  /// 扫描 scripts/ 目录，返回脚本文件列表
  static Future<List<SkillScript>> _scanScriptsDir(String dirPath) async {
    final scripts = <SkillScript>[];
    final scriptsDir = Directory('$dirPath/scripts');
    // 也支持简写的 s/ 目录
    final sDirShort = Directory('$dirPath/s');

    final targetDir = await scriptsDir.exists()
        ? scriptsDir
        : (await sDirShort.exists() ? sDirShort : null);

    if (targetDir == null) return scripts;

    try {
      await for (final entity in targetDir.list(recursive: true)) {
        if (entity is File) {
          final relPath = _safeRelPath(entity.path, dirPath);
          // 统一使用 "scripts/" 前缀（即使实际目录是 s/）
          final normalizedPath = relPath.startsWith('s/')
              ? 'scripts/${relPath.substring(2)}'
              : relPath;
          final fileName = entity.path.split('/').last.split('\\').last;
          scripts.add(SkillScript(
            relativePath: normalizedPath.startsWith('scripts/')
                ? normalizedPath.substring('scripts/'.length)
                : normalizedPath,
            fileName: fileName,
            language: _detectLanguage(fileName),
            description: await _extractScriptDescription(entity.path),
          ));
        }
      }
    } catch (e) {
      debugPrint('🤖 扫描 scripts/ 目录失败: $e');
    }

    return scripts;
  }

  /// 扫描指定子目录，返回文件相对路径列表
  static Future<List<String>> _scanSubDir(String dirPath, String subDirName) async {
    final files = <String>[];
    final subDir = Directory('$dirPath/$subDirName');
    if (!await subDir.exists()) return files;

    try {
      await for (final entity in subDir.list(recursive: true)) {
        if (entity is File) {
          final relPath = _safeRelPath(entity.path, dirPath);
          files.add(relPath);
        }
      }
    } catch (e) {
      debugPrint('🤖 扫描 $subDirName/ 目录失败: $e');
    }

    return files;
  }

  /// 根据文件扩展名检测脚本语言
  static String _detectLanguage(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'py':
      case 'pyw':
        return 'Python';
      case 'js':
      case 'mjs':
      case 'cjs':
        return 'JavaScript';
      case 'ts':
        return 'TypeScript';
      case 'sh':
      case 'bash':
        return 'Shell';
      case 'ps1':
      case 'psm1':
        return 'PowerShell';
      case 'rb':
        return 'Ruby';
      case 'go':
        return 'Go';
      case 'rs':
        return 'Rust';
      case 'dart':
        return 'Dart';
      case 'bat':
      case 'cmd':
        return 'Batch';
      default:
        return ext.isNotEmpty ? ext.toUpperCase() : 'Unknown';
    }
  }

  /// agentskills.io name 规范校验
  /// 规则: 最多64字符、仅小写字母+数字+连字符、不能以连字符开头结尾
  static void _validateSkillName(String name, String dirPath) {
    final warnings = <String>[];
    if (name.length > 64) {
      warnings.add('name 长度 ${name.length} 超过 64 字符限制');
    }
    if (!RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$').hasMatch(name)) {
      warnings.add('name 应仅包含小写字母、数字和连字符，且不能以连字符开头/结尾');
    }
    if (warnings.isNotEmpty) {
      debugPrint('⚠️ Agent Skill name 不符合 agentskills.io 规范 ($name): ${warnings.join("; ")}');
    }
  }

  /// 检查 SKILL.md body 行数建议（规范建议 <500 行）
  static void _validateSkillMdLength(String body, String name) {
    final lineCount = '\n'.allMatches(body).length + 1;
    if (lineCount > 500) {
      debugPrint('⚠️ Agent Skill "$name" 的 SKILL.md 正文有 $lineCount 行，'
          '规范建议保持在 500 行以内。建议将详细内容移至 references/ 目录。');
    }
  }

  /// 解析 YAML frontmatter（增强实现，支持引号字符串、多行值）
  static Map<String, dynamic> _parseFrontmatter(String content) {
    final fm = <String, dynamic>{};
    if (!content.startsWith('---')) return fm;

    final endIdx = content.indexOf('---', 3);
    if (endIdx < 0) return fm;

    final yamlBlock = content.substring(3, endIdx).trim();
    String? currentKey;
    List<String>? currentList;
    String? multilineValue; // 多行值累积

    for (final line in yamlBlock.split('\n')) {
      final trimmed = line.trimRight();

      // 多行值模式（缩进行）
      if (multilineValue != null) {
        if (trimmed.isEmpty || !RegExp(r'^\s').hasMatch(line)) {
          // 多行值结束，保存
          fm[currentKey!] = multilineValue.trim();
          multilineValue = null;
          currentKey = null;
        } else {
          multilineValue = '$multilineValue\n${trimmed}';
        }
        continue;
      }

      // 列表项（缩进 + "- "）
      if (trimmed.startsWith('  - ') || trimmed.startsWith('    - ')) {
        if (currentKey != null) {
          currentList ??= [];
          currentList.add(_unquote(trimmed.trim().substring(2).trim()));
        }
        continue;
      }

      // 保存之前的列表
      if (currentKey != null && currentList != null) {
        fm[currentKey] = currentList;
        currentList = null;
      }

      // 键值对
      final colonIdx = trimmed.indexOf(':');
      if (colonIdx > 0) {
        final key = trimmed.substring(0, colonIdx).trim();
        final rawValue = trimmed.substring(colonIdx + 1).trim();
        if (rawValue.isEmpty) {
          currentKey = key;
          currentList = [];
        } else if (rawValue == '|') {
          // 多行值开始（保留换行）
          currentKey = key;
          multilineValue = '';
        } else if (rawValue == '>') {
          // 折叠多行值（单行化）
          currentKey = key;
          multilineValue = '';
        } else {
          fm[key] = _unquote(rawValue);
          currentKey = null;
          currentList = null;
        }
      }
    }

    // 处理最后一个未保存的列表/值
    if (currentKey != null) {
      if (currentList != null && currentList.isNotEmpty) {
        fm[currentKey] = currentList;
      } else if (multilineValue != null) {
        fm[currentKey] = multilineValue.trim();
      }
    }

    return fm;
  }

  /// 去掉 YAML 值两端的引号（支持单引号、双引号）
  static String _unquote(String value) {
    if (value.length >= 2) {
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        return value.substring(1, value.length - 1);
      }
    }
    return value;
  }

  /// 提取 Markdown body（去掉 frontmatter）
  static String _extractBody(String content) {
    if (!content.startsWith('---')) return content;
    final endIdx = content.indexOf('---', 3);
    if (endIdx < 0) return content;
    return content.substring(endIdx + 3).trim();
  }

  /// 解析字符串列表
  static List<String> _parseStringList(dynamic data) {
    if (data is List) {
      return data.map((e) => e.toString()).toList();
    }
    if (data is String && data.isNotEmpty) {
      return [data];
    }
    return [];
  }

  /// 获取目录名
  static String _dirName(String path) {
    return path.split('/').last.split('\\').last;
  }

  /// 版本号（从 meta 或目录名提取）
  String get version => meta?.version ?? _extractVersion();

  String _extractVersion() {
    final dirName = _dirName(sourcePath ?? '');
    final versionMatch = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(dirName);
    return versionMatch?.group(1) ?? '1.0.0';
  }

  /// 检查 requiredBins 中的依赖是否在系统 PATH 中可用
  Future<List<String>> _checkRequiredBins() async {
    final missing = <String>[];
    final lookupCmd = Platform.isWindows ? 'where' : 'which';
    for (final bin in requiredBins) {
      try {
        final result = await Process.run(
          lookupCmd, [bin],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (result.exitCode != 0) missing.add(bin);
      } catch (_) {
        missing.add(bin);
      }
    }
    return missing;
  }

  /// 从脚本文件首行注释中提取描述文字
  /// 支持 Python (#) 和 JS/TS/Rust (//) 注释风格
  static Future<String> _extractScriptDescription(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return '';
      final content = await file.readAsString(encoding: utf8);
      final lines = const LineSplitter().convert(content).take(5).toList();
      for (final line in lines) {
        final trimmed = line.trim();
        // 跳过 shebang
        if (trimmed.startsWith('#!')) continue;
        // Python/docstring 注释
        if (trimmed.startsWith('# ')) {
          final desc = trimmed.substring(2).trim();
          if (desc.length >= 2 && desc.length <= 100) return desc;
        }
        // JS/TS/Rust/Go 注释
        if (trimmed.startsWith('// ')) {
          final desc = trimmed.substring(3).trim();
          if (desc.length >= 2 && desc.length <= 100) return desc;
        }
      }
    } catch (_) {}
    return '';
  }
}

/// Agent Skill 元数据（来自 _meta.json）
class AgentSkillMeta {
  final String? ownerId;
  final String? slug;
  final String? version;
  final int? publishedAt;

  const AgentSkillMeta({
    this.ownerId,
    this.slug,
    this.version,
    this.publishedAt,
  });

  factory AgentSkillMeta.fromJson(Map<String, dynamic> json) {
    return AgentSkillMeta(
      ownerId: json['ownerId'] as String?,
      slug: json['slug'] as String?,
      version: json['version'] as String?,
      publishedAt: json['publishedAt'] is int ? json['publishedAt'] as int : null,
    );
  }
}

/// Agent Skill 中的脚本文件信息
class SkillScript {
  /// 相对于 scripts/ 目录的路径（如 "fetch.js"、"sub/helper.sh"）
  final String relativePath;

  /// 文件名
  final String fileName;

  /// 检测到的脚本语言
  final String language;

  /// 脚本描述（从文件首行注释提取，或为空）
  final String description;

  const SkillScript({
    required this.relativePath,
    required this.fileName,
    required this.language,
    this.description = '',
  });

  /// 脚本在 command 参数中的引用路径
  String get commandPath => 'scripts/$relativePath';

  @override
  String toString() => 'SkillScript($commandPath [$language])';
}
