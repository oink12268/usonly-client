import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api_client.dart';
import 'api_endpoints.dart';

// ── Score Service ─────────────────────────────────────────────────────────────

class _SnakeScoreService {
  static Future<Map<String, dynamic>?> submitScore(int score) async {
    try {
      final res = await ApiClient.post(
        Uri.parse(ApiEndpoints.gameScores),
        body: jsonEncode({'gameType': 'snake', 'score': score}),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        return decoded['data'] as Map<String, dynamic>?;
      }
    } catch (_) {}
    return null;
  }

  static Future<List<dynamic>?> getTop10() async {
    try {
      final res = await ApiClient.get(
        Uri.parse(ApiEndpoints.gameScoresTop10(gameType: 'snake')),
      );
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        return decoded['data'] as List<dynamic>?;
      }
    } catch (_) {}
    return null;
  }
}

// ── 방향 ──────────────────────────────────────────────────────────────────────

enum _Dir { up, down, left, right }

extension _DirOpp on _Dir {
  bool isOpposite(_Dir other) {
    return (this == _Dir.up && other == _Dir.down) ||
        (this == _Dir.down && other == _Dir.up) ||
        (this == _Dir.left && other == _Dir.right) ||
        (this == _Dir.right && other == _Dir.left);
  }
}

// ── Snake Game Page ───────────────────────────────────────────────────────────

class SnakeGamePage extends StatefulWidget {
  const SnakeGamePage({super.key});

  @override
  State<SnakeGamePage> createState() => _SnakeGamePageState();
}

class _SnakeGamePageState extends State<SnakeGamePage> {
  static const int _cols = 20;
  static const int _rows = 20;

  List<Point<int>> _snake = [];
  Point<int> _food = const Point(10, 10);
  _Dir _dir = _Dir.right;
  _Dir _nextDir = _Dir.right;
  int _score = 0;
  bool _running = false;
  bool _gameOver = false;
  bool _started = false;
  Timer? _timer;
  final Random _rng = Random();
  final FocusNode _focusNode = FocusNode();

  Duration get _speed {
    if (_score < 5) return const Duration(milliseconds: 200);
    if (_score < 15) return const Duration(milliseconds: 160);
    if (_score < 30) return const Duration(milliseconds: 130);
    if (_score < 50) return const Duration(milliseconds: 100);
    return const Duration(milliseconds: 80);
  }

  @override
  void initState() {
    super.initState();
    _reset(start: false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _reset({bool start = true}) {
    _timer?.cancel();
    _snake = [
      const Point(10, 10),
      const Point(9, 10),
      const Point(8, 10),
    ];
    _dir = _Dir.right;
    _nextDir = _Dir.right;
    _score = 0;
    _gameOver = false;
    _running = start;
    _started = start;
    _spawnFood();
    if (start) _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_speed, (_) => _tick());
  }

  void _spawnFood() {
    final occupied = _snake.toSet();
    Point<int> pos;
    do {
      pos = Point(_rng.nextInt(_cols), _rng.nextInt(_rows));
    } while (occupied.contains(pos));
    _food = pos;
  }

  void _tick() {
    if (!_running || _gameOver) return;

    _dir = _nextDir;
    final head = _snake.first;
    Point<int> next;
    switch (_dir) {
      case _Dir.up:
        next = Point(head.x, head.y - 1);
      case _Dir.down:
        next = Point(head.x, head.y + 1);
      case _Dir.left:
        next = Point(head.x - 1, head.y);
      case _Dir.right:
        next = Point(head.x + 1, head.y);
    }

    if (next.x < 0 || next.x >= _cols || next.y < 0 || next.y >= _rows) {
      _doGameOver();
      return;
    }
    if (_snake.contains(next)) {
      _doGameOver();
      return;
    }

    setState(() {
      _snake = [next, ..._snake];
      if (next == _food) {
        _score++;
        _spawnFood();
        if ([5, 15, 30, 50].contains(_score)) _startTimer();
      } else {
        _snake.removeLast();
      }
    });
  }

  void _doGameOver() {
    _timer?.cancel();
    setState(() {
      _gameOver = true;
      _running = false;
    });
  }

  void _start() {
    setState(() {
      _started = true;
      _running = true;
    });
    _startTimer();
  }

  void _turn(_Dir newDir) {
    if (!_running || _gameOver) return;
    if (!_nextDir.isOpposite(newDir)) _nextDir = newDir;
  }

  void _handleKey(LogicalKeyboardKey key) {
    if (!_started) {
      _start();
      return;
    }
    if (_gameOver) {
      setState(() => _reset(start: true));
      return;
    }
    if (key == LogicalKeyboardKey.arrowUp) _turn(_Dir.up);
    if (key == LogicalKeyboardKey.arrowDown) _turn(_Dir.down);
    if (key == LogicalKeyboardKey.arrowLeft) _turn(_Dir.left);
    if (key == LogicalKeyboardKey.arrowRight) _turn(_Dir.right);
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (e) {
        if (e is KeyDownEvent) _handleKey(e.logicalKey);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        appBar: AppBar(
          title: const Text('🐍 스네이크'),
          backgroundColor: const Color(0xFF16213E),
          foregroundColor: Colors.white,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '점수: $_score',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(child: _buildBoard()),
            _buildDpad(),
          ],
        ),
      ),
    );
  }

  Widget _buildBoard() {
    return GestureDetector(
      onVerticalDragEnd: (d) {
        if (!_started) {
          _start();
          return;
        }
        if (d.primaryVelocity! < 0) _turn(_Dir.up);
        if (d.primaryVelocity! > 0) _turn(_Dir.down);
      },
      onHorizontalDragEnd: (d) {
        if (!_started) {
          _start();
          return;
        }
        if (d.primaryVelocity! < 0) _turn(_Dir.left);
        if (d.primaryVelocity! > 0) _turn(_Dir.right);
      },
      child: AspectRatio(
        aspectRatio: _cols / _rows,
        child: Stack(
          children: [
            CustomPaint(
              painter: _BoardPainter(
                snake: _snake,
                food: _food,
                cols: _cols,
                rows: _rows,
              ),
              child: const SizedBox.expand(),
            ),
            if (!_started) _buildStartOverlay(),
            if (_gameOver)
              _GameOverOverlay(
                score: _score,
                onRestart: () => setState(() => _reset(start: true)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStartOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🐍', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 12),
            const Text('스네이크',
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
            const SizedBox(height: 8),
            Text('방향키 또는 스와이프로 먹이를 먹어요!',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.85))),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _start,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4CAF50),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                textStyle: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
              ),
              child: const Text('시작하기'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDpad() {
    return Container(
      color: const Color(0xFF16213E),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DpadButton(
            icon: Icons.arrow_drop_up,
            onTap: () => _started ? _turn(_Dir.up) : _start(),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _DpadButton(
                icon: Icons.arrow_left,
                onTap: () => _started ? _turn(_Dir.left) : _start(),
              ),
              const SizedBox(width: 48),
              _DpadButton(
                icon: Icons.arrow_right,
                onTap: () => _started ? _turn(_Dir.right) : _start(),
              ),
            ],
          ),
          _DpadButton(
            icon: Icons.arrow_drop_down,
            onTap: () => _started ? _turn(_Dir.down) : _start(),
          ),
        ],
      ),
    );
  }
}

class _DpadButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _DpadButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: Colors.white, size: 36),
      ),
    );
  }
}

// ── Board Painter ─────────────────────────────────────────────────────────────

class _BoardPainter extends CustomPainter {
  final List<Point<int>> snake;
  final Point<int> food;
  final int cols;
  final int rows;

  const _BoardPainter({
    required this.snake,
    required this.food,
    required this.cols,
    required this.rows,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width / cols;
    final ch = size.height / rows;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF0F3460),
    );

    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 0.5;
    for (int x = 0; x <= cols; x++) {
      canvas.drawLine(
          Offset(x * cw, 0), Offset(x * cw, size.height), gridPaint);
    }
    for (int y = 0; y <= rows; y++) {
      canvas.drawLine(
          Offset(0, y * ch), Offset(size.width, y * ch), gridPaint);
    }

    for (int i = 0; i < snake.length; i++) {
      final p = snake[i];
      final isHead = i == 0;
      final ratio = 1.0 - (i / snake.length) * 0.45;
      final color = isHead
          ? const Color(0xFF4CAF50)
          : Color.lerp(
              const Color(0xFF388E3C), const Color(0xFF1B5E20), 1 - ratio)!;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(p.x * cw + 1, p.y * ch + 1, cw - 2, ch - 2),
        Radius.circular(isHead ? 5 : 3),
      );
      canvas.drawRRect(rect, Paint()..color = color);

      if (isHead) {
        canvas.drawCircle(
            Offset(p.x * cw + cw * 0.65, p.y * ch + ch * 0.3),
            3.5,
            Paint()..color = Colors.white);
        canvas.drawCircle(
            Offset(p.x * cw + cw * 0.67, p.y * ch + ch * 0.32),
            1.8,
            Paint()..color = Colors.black);
      }
    }

    final fc = Offset(food.x * cw + cw / 2, food.y * ch + ch / 2);
    final fr = min(cw, ch) * 0.38;
    canvas.drawCircle(fc, fr, Paint()..color = const Color(0xFFE53935));
    canvas.drawCircle(
      Offset(fc.dx - fr * 0.2, fc.dy - fr * 0.3),
      fr * 0.35,
      Paint()..color = const Color(0xFFEF9A9A),
    );
    final stemPaint = Paint()
      ..color = const Color(0xFF4CAF50)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(fc.dx, fc.dy - fr),
      Offset(fc.dx + fr * 0.3, fc.dy - fr * 1.4),
      stemPaint,
    );
  }

  @override
  bool shouldRepaint(_BoardPainter old) =>
      old.snake != snake || old.food != food;
}

// ── Game Over Overlay ─────────────────────────────────────────────────────────

class _GameOverOverlay extends StatefulWidget {
  final int score;
  final VoidCallback onRestart;

  const _GameOverOverlay({required this.score, required this.onRestart});

  @override
  State<_GameOverOverlay> createState() => _GameOverOverlayState();
}

class _GameOverOverlayState extends State<_GameOverOverlay> {
  Map<String, dynamic>? _summary;
  List<dynamic>? _top10;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _submitAndFetch();
  }

  Future<void> _submitAndFetch() async {
    final summary = await _SnakeScoreService.submitScore(widget.score);
    final top10 = await _SnakeScoreService.getTop10();
    if (mounted) {
      setState(() {
        _summary = summary;
        _top10 = top10;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(blurRadius: 20, color: Colors.black38)
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('💀', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 6),
              const Text('게임 오버!',
                  style: TextStyle(
                      fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('이번 점수: ${widget.score}',
                  style: TextStyle(
                      fontSize: 18,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              if (_loading)
                const SizedBox(
                  height: 32,
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (_summary != null)
                _ScoreBanner(summary: _summary!),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_top10 != null && _top10!.isNotEmpty) ...[
                    OutlinedButton.icon(
                      onPressed: () => showDialog(
                        context: context,
                        builder: (_) =>
                            _LeaderboardDialog(entries: _top10!),
                      ),
                      icon: const Icon(Icons.emoji_events),
                      label: const Text('명예의 전당'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  ElevatedButton.icon(
                    onPressed: widget.onRestart,
                    icon: const Icon(Icons.refresh),
                    label: const Text('다시 시작'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      textStyle: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Score Banner ──────────────────────────────────────────────────────────────

class _ScoreBanner extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _ScoreBanner({required this.summary});

  @override
  Widget build(BuildContext context) {
    final myBest = summary['myBest'] as int? ?? 0;
    final partnerBest = summary['partnerBest'] as int?;
    final partnerNickname = summary['partnerNickname'] as String?;
    final myWinning = partnerBest == null || myBest >= partnerBest;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ScoreCol(
                  label: '나',
                  score: myBest,
                  isCrown: myWinning && partnerBest != null,
                  highlight: true),
              Container(width: 1, height: 40, color: Colors.grey.shade300),
              if (partnerBest != null && partnerNickname != null)
                _ScoreCol(
                    label: partnerNickname,
                    score: partnerBest,
                    isCrown: !myWinning,
                    highlight: false)
              else
                const Text('파트너 기록 없음',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
          if (partnerBest != null) ...[
            const SizedBox(height: 8),
            Text(
              myBest > partnerBest
                  ? '앞서고 있어요! 🎉'
                  : myBest == partnerBest
                      ? '동점이에요! 🤝'
                      : '따라잡아야 해요! 💪',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color:
                      myBest >= partnerBest ? Colors.green : Colors.orange),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScoreCol extends StatelessWidget {
  final String label;
  final int score;
  final bool isCrown;
  final bool highlight;

  const _ScoreCol({
    required this.label,
    required this.score,
    required this.isCrown,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (isCrown)
          const Text('👑', style: TextStyle(fontSize: 16))
        else
          const SizedBox(height: 20),
        Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 2),
        Text('최고 $score점',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: highlight
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black87)),
      ],
    );
  }
}

// ── Leaderboard Dialog ────────────────────────────────────────────────────────

class _LeaderboardDialog extends StatelessWidget {
  final List<dynamic> entries;
  const _LeaderboardDialog({required this.entries});

  static const _rankEmoji = ['🥇', '🥈', '🥉'];

  String _formatDate(String? isoDate) {
    if (isoDate == null) return '';
    try {
      final dt = DateTime.parse(isoDate);
      return '${dt.month}/${dt.day}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text('🏆', style: TextStyle(fontSize: 24)),
                const SizedBox(width: 8),
                const Text('명예의 전당',
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('우리 커플 TOP ${entries.length}',
                style:
                    TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 12),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: entries.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: Colors.grey.shade200),
                itemBuilder: (context, i) {
                  final e = entries[i] as Map<String, dynamic>;
                  final rank = e['rank'] as int? ?? (i + 1);
                  final isMe = e['isMe'] as bool? ?? false;
                  final rankLabel =
                      rank <= 3 ? _rankEmoji[rank - 1] : '$rank위';

                  return Container(
                    color: isMe
                        ? theme.colorScheme.primary.withValues(alpha: 0.07)
                        : null,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 36,
                          child: Text(rankLabel,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: rank <= 3 ? 20 : 14,
                                  fontWeight: FontWeight.bold,
                                  color: rank <= 3
                                      ? null
                                      : Colors.grey.shade600)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Row(
                            children: [
                              Text(
                                e['nickname'] as String? ?? '?',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: isMe
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: isMe
                                        ? theme.colorScheme.primary
                                        : null),
                              ),
                              if (isMe) ...[
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    borderRadius:
                                        BorderRadius.circular(8),
                                  ),
                                  child: Text('나',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color:
                                              theme.colorScheme.onPrimary,
                                          fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Text('${e['score']}점',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: isMe
                                    ? theme.colorScheme.primary
                                    : Colors.black87)),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 36,
                          child: Text(
                            _formatDate(e['playedAt'] as String?),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
