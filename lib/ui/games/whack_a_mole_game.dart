import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/pet_engine.dart';

/// 打地鼠游戏
/// 地鼠从洞里冒出来，玩家点击锤击。30秒内尽可能多地击中地鼠。
/// 击中得分，最高分记录，游戏结束奖励经验值。
class WhackAMoleGame extends StatefulWidget {
  const WhackAMoleGame({super.key});

  @override
  State<WhackAMoleGame> createState() => _WhackAMoleGameState();
}

class _WhackAMoleGameState extends State<WhackAMoleGame>
    with TickerProviderStateMixin {
  /// 游戏时长（秒）
  static const int _gameDuration = 30;

  /// 3x3 网格
  static const int _gridSize = 9;

  /// 地鼠出现间隔范围（毫秒）
  static const int _minInterval = 500;
  static const int _maxInterval = 1200;

  /// 地鼠显示时长范围（毫秒）
  static const int _minShowTime = 600;
  static const int _maxShowTime = 1500;

  /// 金色地鼠概率
  static const double _goldenChance = 0.15;

  final Random _random = Random();

  /// 游戏状态
  bool _gameStarted = false;
  bool _gameOver = false;
  int _score = 0;
  int _timeLeft = _gameDuration;
  int _combo = 0;
  int _maxCombo = 0;

  /// 每个洞的状态：-1=隐藏, 0=普通地鼠, 1=金色地鼠
  final List<int> _holes = List.filled(_gridSize, -1);

  /// 地鼠动画状态：每个洞的地鼠是否正在被锤击（缩小动画）
  final List<bool> _hitAnimating = List.filled(_gridSize, false);

  /// 锤子动画控制器
  late AnimationController _hammerController;

  /// 计时器
  Timer? _gameTimer;
  Timer? _spawnTimer;

  @override
  void initState() {
    super.initState();
    _hammerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _gameTimer?.cancel();
    _spawnTimer?.cancel();
    _hammerController.dispose();
    super.dispose();
  }

  /// 开始游戏
  void _startGame() {
    setState(() {
      _gameStarted = true;
      _gameOver = false;
      _score = 0;
      _timeLeft = _gameDuration;
      _combo = 0;
      _maxCombo = 0;
      _holes.fillRange(0, _gridSize, -1);
      _hitAnimating.fillRange(0, _gridSize, false);
    });

    // 倒计时
    _gameTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _timeLeft--);
      if (_timeLeft <= 0) {
        _endGame();
      }
    });

    // 开始生成地鼠
    _spawnMole();
  }

  /// 生成地鼠
  void _spawnMole() {
    if (!mounted || _gameOver) return;

    // 找一个空闲的洞
    final emptyHoles = <int>[];
    for (int i = 0; i < _gridSize; i++) {
      if (_holes[i] == -1) emptyHoles.add(i);
    }
    if (emptyHoles.isEmpty || !_gameStarted) {
      _scheduleNextSpawn();
      return;
    }

    final holeIndex = emptyHoles[_random.nextInt(emptyHoles.length)];
    final isGolden = _random.nextDouble() < _goldenChance;

    setState(() {
      _holes[holeIndex] = isGolden ? 1 : 0;
    });

    // 地鼠显示一段时间后消失
    final showTime = _minShowTime + _random.nextInt(_maxShowTime - _minShowTime);
    Timer(Duration(milliseconds: showTime), () {
      if (!mounted || _gameOver) return;
      if (_holes[holeIndex] != -1 && !_hitAnimating[holeIndex]) {
        setState(() {
          _holes[holeIndex] = -1;
          // 未击中，重置连击
          _combo = 0;
        });
      }
    });

    _scheduleNextSpawn();
  }

  /// 安排下一次地鼠生成
  void _scheduleNextSpawn() {
    if (!mounted || _gameOver) return;
    final interval = _minInterval + _random.nextInt(_maxInterval - _minInterval);
    // 随时间推移加快速度
    final elapsed = _gameDuration - _timeLeft;
    final speedFactor = max(0.5, 1.0 - elapsed / _gameDuration * 0.5);
    final adjustedInterval = (interval * speedFactor).round();

    _spawnTimer = Timer(Duration(milliseconds: adjustedInterval), _spawnMole);
  }

  /// 锤击地鼠
  void _hitMole(int index, Offset position) {
    if (!_gameStarted || _gameOver) return;
    if (_holes[index] == -1 || _hitAnimating[index]) return;

    final isGolden = _holes[index] == 1;

    setState(() {
      _hitAnimating[index] = true;
      _combo++;
      if (_combo > _maxCombo) _maxCombo = _combo;

      // 计分：普通1分，金色3分，连击加成
      final baseScore = isGolden ? 3 : 1;
      final comboBonus = min(_combo ~/ 3, 5);
      _score += baseScore + comboBonus;
    });

    _hammerController.forward(from: 0);

    // 延迟后重置
    Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {
        _holes[index] = -1;
        _hitAnimating[index] = false;
      });
    });
  }

  /// 结束游戏
  void _endGame() {
    _gameTimer?.cancel();
    _spawnTimer?.cancel();

    if (!mounted) return;

    // 发放奖励：每2分1经验，最少2经验
    final expReward = max(2, _score ~/ 2);

    setState(() => _gameOver = true);

    // 延迟显示结算
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _showResult(expReward);
    });
  }

  /// 显示结算界面
  void _showResult(int expReward) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        // 先发放奖励
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (ctx.mounted) {
            try {
              context.read<PetEngine>().grantAchievementReward(exp: expReward);
            } catch (_) {}
          }
        });

        return Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 400),
            curve: Curves.elasticOut,
            builder: (context, value, child) {
              return Transform.scale(
                scale: value,
                child: child,
              );
            },
            child: Container(
              width: 300,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.orange.withOpacity(0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🔨', style: TextStyle(fontSize: 48)),
                  const SizedBox(height: 8),
                  const Text(
                    '游戏结束！',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF37474F)),
                  ),
                  const SizedBox(height: 16),
                  _ResultRow(label: '得分', value: '$_score', color: Colors.orange),
                  _ResultRow(label: '最大连击', value: '$_maxCombo', color: Colors.blue),
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
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.grey.shade600,
                          ),
                          child: const Text('返回'),
                        ),
                      ),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _startGame();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF8F00),
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
          width: 380,
          padding: const EdgeInsets.all(16),
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
          child: _gameStarted ? _buildGameBoard() : _buildStartScreen(),
        ),
      ),
    );
  }

  /// 开始界面
  Widget _buildStartScreen() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('🔨', style: TextStyle(fontSize: 64)),
        const SizedBox(height: 12),
        const Text(
          '打地鼠',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF37474F)),
        ),
        const SizedBox(height: 8),
        Text(
          '$_gameDuration秒内尽可能多地锤击地鼠！',
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFFECB3),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('🐹 普通 +1分', style: TextStyle(fontSize: 12, color: Color(0xFFFF8F00))),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('⭐ 金色 +3分', style: TextStyle(fontSize: 12, color: Color(0xFFFFD700))),
            ),
          ],
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _startGame,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFF8F00),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          child: const Text('开始游戏'),
        ),
      ],
    );
  }

  /// 游戏棋盘
  Widget _buildGameBoard() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部状态栏
        _buildStatusBar(),
        const SizedBox(height: 12),
        // 3x3 网格
        _buildGrid(),
        const SizedBox(height: 12),
        // 连击提示
        if (_combo >= 3)
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.8, end: 1.2),
            duration: const Duration(milliseconds: 200),
            curve: Curves.elasticOut,
            builder: (context, value, child) {
              return Transform.scale(scale: value, child: child);
            },
            child: Text(
              '${_combo}连击！🔥',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange),
            ),
          ),
      ],
    );
  }

  /// 状态栏：时间+分数
  Widget _buildStatusBar() {
    final timeColor = _timeLeft <= 5 ? Colors.red : _timeLeft <= 10 ? Colors.orange : Colors.grey.shade700;
    return Row(
      children: [
        // 时间
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: timeColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(Icons.timer, size: 16, color: timeColor),
              const SizedBox(width: 4),
              Text(
                '${_timeLeft}s',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: timeColor),
              ),
            ],
          ),
        ),
        const Spacer(),
        // 分数
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Text('⭐', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 4),
              Text(
                '$_score',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFFF8F00)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 3x3 网格
  Widget _buildGrid() {
    return GestureDetector(
      onTapDown: _onGridTapDown,
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: _gridSize,
        itemBuilder: (context, index) {
          return _buildHole(index);
        },
      ),
    );
  }

  /// 处理网格点击
  void _onGridTapDown(TapDownDetails details) {
    if (_gameOver) return;
    _hammerController.forward(from: 0);
  }

  /// 单个地洞
  Widget _buildHole(int index) {
    final moleState = _holes[index];
    final isHit = _hitAnimating[index];

    return GestureDetector(
      onTapDown: (details) => _hitMole(index, details.localPosition),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          color: const Color(0xFF8D6E63),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.brown.withOpacity(0.3),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 洞的内部（深色椭圆）
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF5D4037),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              // 地鼠
              if (moleState != -1)
                AnimatedScale(
                  scale: isHit ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  curve: isHit ? Curves.easeIn : Curves.elasticOut,
                  child: _buildMoleEmoji(moleState == 1),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 地鼠 emoji
  Widget _buildMoleEmoji(bool isGolden) {
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: isGolden ? const Color(0xFFFFF8E1) : const Color(0xFFFFECB3),
        shape: BoxShape.circle,
        border: isGolden ? Border.all(color: const Color(0xFFFFD700), width: 2) : null,
        boxShadow: [
          BoxShadow(
            color: isGolden ? Colors.amber.withOpacity(0.4) : Colors.brown.withOpacity(0.2),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Text(
          isGolden ? '⭐' : '🐹',
          style: const TextStyle(fontSize: 28),
        ),
      ),
    );
  }
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
      padding: const EdgeInsets.symmetric(vertical: 4),
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
