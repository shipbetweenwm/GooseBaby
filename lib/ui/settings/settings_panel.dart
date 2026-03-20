import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../ai/llm_manager.dart';
import '../../models/models.dart';
import '../../skills/skill_manager.dart';

/// 设置面板
class SettingsPanel extends StatefulWidget {
  final VoidCallback? onClose;

  const SettingsPanel({super.key, this.onClose});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  int _selectedTab = 0;

  final _tabs = const ['🧠 AI模型', '🎮 技能', '🦢 宠物', '📋 关于'];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 480,
      height: 520,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildTitleBar(),
          _buildTabBar(),
          Expanded(child: _buildTabContent()),
        ],
      ),
    );
  }

  Widget _buildTitleBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      child: Row(
        children: [
          const Text(
            '⚙️ 鹅宝设置',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      child: Row(
        children: List.generate(_tabs.length, (i) {
          final isActive = _selectedTab == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedTab = i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: isActive ? const Color(0xFF4FC3F7) : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                _tabs[i],
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  color: isActive ? const Color(0xFF4FC3F7) : Colors.grey,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_selectedTab) {
      case 0:
        return _AIModelSettings();
      case 1:
        return _SkillSettings();
      case 2:
        return _PetSettings();
      case 3:
        return _AboutPanel();
      default:
        return const SizedBox();
    }
  }
}

/// AI 模型设置
class _AIModelSettings extends StatefulWidget {
  @override
  State<_AIModelSettings> createState() => _AIModelSettingsState();
}

class _AIModelSettingsState extends State<_AIModelSettings> {
  String _selectedProvider = 'qwen';
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  final _endpointController = TextEditingController();

  final _providers = {
    'qwen': {'name': '通义千问', 'icon': '🌐', 'hint': 'DashScope API Key'},
    'hunyuan': {'name': '腾讯混元', 'icon': '🔮', 'hint': '腾讯云 SecretId:SecretKey'},
    'openai': {'name': 'OpenAI', 'icon': '🤖', 'hint': 'OpenAI API Key'},
    'claude': {'name': 'Claude', 'icon': '🧠', 'hint': 'Anthropic API Key'},
    'ollama': {'name': 'Ollama本地', 'icon': '🏠', 'hint': '无需API Key'},
  };

  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelController.dispose();
    _endpointController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '选择 AI 模型',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),

          // 模型选择卡片
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _providers.entries.map((entry) {
              final isSelected = _selectedProvider == entry.key;
              return GestureDetector(
                onTap: () => setState(() => _selectedProvider = entry.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF4FC3F7).withOpacity(0.1) : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? const Color(0xFF4FC3F7) : Colors.grey.shade200,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(entry.value['icon']!, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 6),
                      Text(
                        entry.value['name']!,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          color: isSelected ? const Color(0xFF4FC3F7) : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 20),

          // API Key 输入
          if (_selectedProvider != 'ollama') ...[
            _SettingField(
              label: 'API Key',
              hint: _providers[_selectedProvider]?['hint'] ?? '',
              controller: _apiKeyController,
              isPassword: true,
            ),
            const SizedBox(height: 12),
          ],

          // 模型名称
          _SettingField(
            label: '模型名称',
            hint: _getDefaultModel(),
            controller: _modelController,
          ),
          const SizedBox(height: 12),

          // API 端点
          _SettingField(
            label: 'API 端点 (可选)',
            hint: _getDefaultEndpoint(),
            controller: _endpointController,
          ),

          const SizedBox(height: 20),

          // 保存按钮
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saveSettings,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4FC3F7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('保存配置'),
            ),
          ),
        ],
      ),
    );
  }

  String _getDefaultModel() {
    switch (_selectedProvider) {
      case 'qwen': return 'qwen-turbo';
      case 'hunyuan': return 'hunyuan-lite';
      case 'openai': return 'gpt-4o-mini';
      case 'claude': return 'claude-3-haiku-20240307';
      case 'ollama': return 'llama3';
      default: return '';
    }
  }

  String _getDefaultEndpoint() {
    switch (_selectedProvider) {
      case 'qwen': return 'https://dashscope.aliyuncs.com/compatible-mode/v1';
      case 'hunyuan': return 'https://hunyuan.tencentcloudapi.com';
      case 'openai': return 'https://api.openai.com/v1';
      case 'claude': return 'https://api.anthropic.com';
      case 'ollama': return 'http://localhost:11434';
      default: return '';
    }
  }

  void _saveSettings() {
    final llmManager = context.read<LLMManager>();
    llmManager.setConfig(LLMConfig(
      provider: _selectedProvider,
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim().isEmpty ? _getDefaultModel() : _modelController.text.trim(),
      baseUrl: _endpointController.text.trim().isEmpty ? _getDefaultEndpoint() : _endpointController.text.trim(),
    ));

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('✅ AI模型配置已保存~ 嘎！'),
        backgroundColor: Color(0xFF4FC3F7),
      ),
    );
  }
}

/// 技能设置
class _SkillSettings extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final skillManager = context.watch<SkillManager>();
    final categories = skillManager.getSkillsByCategory();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: categories.entries.map((entry) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(
                entry.key,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            ...entry.value.map((skill) {
              final isEnabled = skillManager.enabledSkills.contains(skill);
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Text(skill.icon, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            skill.name,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                          ),
                          Text(
                            skill.description,
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: isEnabled,
                      onChanged: (v) => skillManager.setEnabled(skill.id, v),
                      activeColor: const Color(0xFF4FC3F7),
                    ),
                  ],
                ),
              );
            }),
          ],
        );
      }).toList(),
    );
  }
}

/// 宠物设置
class _PetSettings extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '鹅宝个性化',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          _SettingToggle(title: '开机自启动', subtitle: '开机时自动唤醒鹅宝', value: true, onChanged: (_) {}),
          _SettingToggle(title: '始终置顶', subtitle: '鹅宝始终显示在最上层', value: true, onChanged: (_) {}),
          _SettingToggle(title: '自动漫游', subtitle: '鹅宝在桌面上随机走动', value: true, onChanged: (_) {}),
          _SettingToggle(title: '声音效果', subtitle: '鹅宝的嘎嘎叫声', value: false, onChanged: (_) {}),
          _SettingToggle(title: '通知提醒', subtitle: '鹅宝会提醒你休息喝水', value: true, onChanged: (_) {}),
          const SizedBox(height: 20),
          const Text(
            '透明度',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          Slider(
            value: 1.0,
            onChanged: (_) {},
            min: 0.3,
            max: 1.0,
            activeColor: const Color(0xFF4FC3F7),
          ),
          const SizedBox(height: 12),
          const Text(
            '鹅宝大小',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          Slider(
            value: 1.0,
            onChanged: (_) {},
            min: 0.5,
            max: 2.0,
            activeColor: const Color(0xFF4FC3F7),
          ),
        ],
      ),
    );
  }
}

/// 关于面板
class _AboutPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🦢', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 12),
            const Text(
              '鹅宝 GooseBaby',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'v1.0.0',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 16),
            Text(
              'AI 驱动的桌面智能宠物伙伴\n你的专属小白鹅~ 嘎！',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600, height: 1.6),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _InfoRow(label: '框架', value: 'Flutter + Dart'),
                  _InfoRow(label: '平台', value: 'macOS / Windows'),
                  _InfoRow(label: 'AI引擎', value: '千问 / 混元 / OpenAI / Claude / Ollama'),
                  _InfoRow(label: '许可', value: 'MIT License'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 通用设置组件
class _SettingField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool isPassword;

  const _SettingField({
    required this.label,
    required this.hint,
    required this.controller,
    this.isPassword = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: isPassword,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ],
    );
  }
}

class _SettingToggle extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingToggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14)),
                Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFF4FC3F7),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
