import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/pet_engine.dart';

/// 猜数字游戏
/// 猜一个1~100的数字，每次猜测会提示偏大或偏小。
/// 猜对后根据猜测次数给予经验奖励（次数越少奖励越多）。
class GuessNumberGame extends StatefulWidget {
  const GuessNumberGame({super.key});

  @override
  State<GuessNumberGame> createState() => _GuessNumberGameState();
}

class _GuessNumberGameState extends State<GuessNumberGame> with TickerProviderStateMixin {
  static const int _minNumber = 1;
  static const int _maxNumber = 100;

  final Random _random = Random();
  final TextEditingController _inputController = TextEditingController();

  int _targetNumber = 1;
  int _attempts = 0;
  String? _hint;
  bool _gameWon = false;
  bool _gameOver = false;

  /// 猜测历史记录
  final List<_GuessRecord> _history = [];

  /// 晃动动画控制器（猜错时）
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  /// 弹跳动画控制器（猜对时）
  late AnimationController _bounceController;
  late Animation<double> _bounceAnimation;

  /// 范围指示（当前可能的最小和最大值）
  int _rangeMin = _minNumber;
  int _rangeMax = _maxNumber;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -8), weight: 20),
      TweenSequenceItem(tween: Tween(begin: -8, end: 8), weight: 20),
      TweenSequenceItem(tween: Tween(begin: 8, end: -6), weight: 20),
      TweenSequenceItem(tween: Tween(begin: -6, end: 6), weight: 20),
      TweenSequenceItem(tween: Tween(begin: 6, end: 0), weight: 20),
    ]).animate(_shakeController);

    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _bounceAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.3), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 0.9), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 0.9, end: 1.0), weight: 30),
    ]).animate(CurvedAnimation(parent: _bounceController, curve: Curves.easeOut));

    _newGame();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _shakeController.dispose();
    _bounceController.dispose();
    super.dispose();
  }

  void _newGame() {
    setState(() {
      _targetNumber = _minNumber + _random.nextInt(_maxNumber - _minNumber + 1);
      _attempts = 0;
      _hint = null;
      _gameWon = false;
      _gameOver = false;
      _history.clear();
      _rangeMin = _minNumber;
      _rangeMax = _maxNumber;
    });
    _inputController.clear();
  }

  void _submitGuess() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final guess = int.tryParse(text);
    if (guess == null || guess < _minNumber || guess > _maxNumber) {
      _shakeController.forward(from: 0);
      setState(() => _hint = '请输入 $_minNumber~$_maxNumber 之间的数字');
      return;
    }

    if (_gameWon || _gameOver) return;

    setState(() {
      _attempts++;

      if (guess == _targetNumber) {
        _gameWon = true;
        _hint = null;
        _history.add(_GuessRecord(guess, _GuessResult.correct));
        _bounceController.forward(from: 0);
        // 延迟显示结算
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) _showResult();
        });
      } else if (guess < _targetNumber) {
        _hint = '🟢 太小了，再大一点！';
        _history.add(_GuessRecord(guess, _GuessResult.tooSmall));
        _rangeMin = max(_rangeMin, guess + 1);
        _shakeController.forward(from: 0);
      } else {
        _hint = '🔴 太大了，再小一点！';
        _history.add(_GuessRecord(guess, _GuessResult.tooBig));
        _rangeMax = min(_rangeMax, guess - 1);
        _shakeController.forward(from: 0);
      }
    });
    _inputController.clear();
  }

  /// 放弃当前游戏
  void _giveUp() {
    if (_gameWon || _gameOver) return;
    setState(() {
      _gameOver = true;
      _hint = '放弃了！答案是 $_targetNumber';
      _history.add(_GuessRecord(_targetNumber, _GuessResult.correct));
    });
  }
  void _showResult() {
    // 计算经验奖励：7次以内=10exp，每多一次-1，最少2exp
    final expReward = max(2, 10 - (_attempts - 7));

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        // 发放奖励
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (ctx.mounted) {
            try {
              context.read<PetEngine>().grantAchievementReward(exp: expReward);
            } catch (_) {}
          }
        });

        String rank;
        String rankEmoji;
        if (_attempts <= 4) { rank = '天才'; rankEmoji = '🏆'; }
        else if (_attempts <= 6) { rank = '厉害'; rankEmoji = '🌟'; }
        else if (_attempts <= 8) { rank = '不错'; rankEmoji = '👍'; }
        else { rank = '继续加油'; rankEmoji = '💪'; }

        return Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 400),
            curve: Curves.elasticOut,
            builder: (context, value, child) {
              return Transform.scale(scale: value, child: child);
            },
            child: Container(
              width: 280,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(rankEmoji, style: const TextStyle(fontSize: 48)),
                  const SizedBox(height: 8),
                  Text(
                    '$rank！猜对了！',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF37474F)),
                  ),
                  const SizedBox(height: 16),
                  _ResultRow(label: '答案', value: '$_targetNumber', color: Colors.blue),
                  _ResultRow(label: '猜测次数', value: '$_attempts 次', color: Colors.orange),
                  _ResultRow(label: '奖励经验', value: '+$expReward', color: Colors.green),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            Navigator.of(context).pop();
                          },
                          style: TextButton.styleFrom(foregroundColor: Colors.grey.shade600),
                          child: const Text('返回'),
                        ),
                      ),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _newGame();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4FC3F7),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('再来一局'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Container(
          width: 340,
          padding: const EdgeInsets.all(20),
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
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题
              const Text('🔢', style: TextStyle(fontSize: 40)),
              const SizedBox(height: 4),
              const Text(
                '猜数字',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF37474F)),
              ),
              Text(
                '猜一个 $_minNumber~$_maxNumber 的数字',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 16),

              // 范围指示条
              _buildRangeBar(),
              const SizedBox(height: 12),

              // 输入区域
              AnimatedBuilder(
                animation: _shakeAnimation,
                builder: (context, child) {
                  return Transform.translate(
                    offset: Offset(_shakeAnimation.value, 0),
                    child: child,
                  );
                },
                child: _buildInputArea(),
              ),
              const SizedBox(height: 12),

              // 提示文字
              if (_hint != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _hint!,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _gameWon ? Colors.green : Colors.red.shade700,
                    ),
                  ),
                ),

              // 猜对动画
              if (_gameWon)
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.elasticOut,
                  builder: (context, value, child) {
                    return Transform.scale(scale: _bounceAnimation.value, child: child);
                  },
                  child: const Text(
                    '🎉 猜对了！🎉',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green),
                  ),
                ),

              // 猜测历史
              if (_history.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                _buildHistory(),
              ],

              // 底部操作
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (!_gameWon && !_gameOver)
                    TextButton(
                      onPressed: _giveUp,
                      style: TextButton.styleFrom(foregroundColor: Colors.grey.shade500),
                      child: const Text('放弃', style: TextStyle(fontSize: 13)),
                    )
                  else
                    const SizedBox.shrink(),
                  Text(
                    '第 $_attempts 次',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 范围指示条
  Widget _buildRangeBar() {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalRange = _maxNumber - _minNumber + 1;
          final leftFraction = (_rangeMin - _minNumber) / totalRange;
          final rightFraction = (_rangeMax - _minNumber + 1) / totalRange;

          return Stack(
            children: [
              // 可能范围高亮
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: rightFraction - leftFraction,
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: 1.0 / (1.0 - leftFraction + 0.001),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF4FC3F7).withOpacity(0.3),
                          const Color(0xFF4FC3F7).withOpacity(0.5),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              // 范围文字
              Center(
                child: Text(
                  '$_rangeMin ~ $_rangeMax',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF0288D1),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 输入区域
  Widget _buildInputArea() {
    if (_gameWon || _gameOver) {
      return const SizedBox(height: 48);
    }

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _inputController,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 3,
            onSubmitted: (_) => _submitGuess(),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              counterText: '',
              hintText: '?',
              hintStyle: TextStyle(fontSize: 20, color: Colors.grey.shade300),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: const Color(0xFF4FC3F7).withOpacity(0.5)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: const Color(0xFF4FC3F7).withOpacity(0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF4FC3F7), width: 2),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 48,
          height: 48,
          child: ElevatedButton(
            onPressed: _submitGuess,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4FC3F7),
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('猜', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  /// 猜测历史
  Widget _buildHistory() {
    // 只显示最近的记录
    final records = _history.length > 8 ? _history.sublist(_history.length - 8) : _history;

    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: records.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final record = records[index];
          final bgColor = switch (record.result) {
            _GuessResult.tooSmall => Colors.green.shade50,
            _GuessResult.tooBig => Colors.red.shade50,
            _GuessResult.correct => Colors.amber.shade50,
          };
          final borderColor = switch (record.result) {
            _GuessResult.tooSmall => Colors.green,
            _GuessResult.tooBig => Colors.red,
            _GuessResult.correct => Colors.amber,
          };
          final icon = switch (record.result) {
            _GuessResult.tooSmall => '↑',
            _GuessResult.tooBig => '↓',
            _GuessResult.correct => '✓',
          };

          return Container(
            width: 40,
            height: 36,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor.withOpacity(0.5)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${record.guess}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: borderColor,
                  ),
                ),
                Text(icon, style: TextStyle(fontSize: 8, color: borderColor)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 猜测记录
enum _GuessResult { tooSmall, tooBig, correct }

class _GuessRecord {
  final int guess;
  final _GuessResult result;

  const _GuessRecord(this.guess, this.result);
}

/// 结算行
class _ResultRow extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _ResultRow({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}
