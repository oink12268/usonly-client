import 'dart:convert';
import 'dart:math';
import 'package:flame/game.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/collisions.dart';
import 'package:flutter/material.dart' hide Gradient;
import 'package:flutter/services.dart';
import 'api_client.dart';
import 'api_endpoints.dart';

// ── Score Service ─────────────────────────────────────────────────────────────

class _GameScoreService {
  static Future<Map<String, dynamic>?> submitScore(int score) async {
    try {
      final res = await ApiClient.post(
        Uri.parse(ApiEndpoints.gameScores),
        body: jsonEncode({'gameType': 'flappy', 'score': score}),
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
        Uri.parse(ApiEndpoints.gameScoresTop10()),
      );
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        return decoded['data'] as List<dynamic>?;
      }
    } catch (_) {}
    return null;
  }
}

// ── Flutter Page ──────────────────────────────────────────────────────────────

class DinoGamePage extends StatelessWidget {
  const DinoGamePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('플래피 버드 🐦'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      body: GameWidget<FlappyGame>(
        game: FlappyGame(),
        overlayBuilderMap: {
          'Start': (context, game) => _StartOverlay(game: game),
          'GameOver': (context, game) => _GameOverOverlay(game: game),
        },
        initialActiveOverlays: const ['Start'],
      ),
    );
  }
}

// ── Flame Game ────────────────────────────────────────────────────────────────

class FlappyGame extends FlameGame
    with TapCallbacks, HasCollisionDetection, KeyboardEvents {
  static const double _pipeGap = 170.0;
  static const double _pipeWidth = 58.0;
  static const double _pipeSpeed = 180.0;
  static const double _pipeInterval = 2.2;

  late BirdComponent _bird;
  late TextComponent _scoreText;

  int _score = 0;
  double _pipeTimer = 0;
  bool _running = false;
  bool _over = false;

  @override
  Color backgroundColor() => const Color(0xFF87CEEB);

  @override
  Future<void> onLoad() async {
    add(_GroundComponent());
    _bird = BirdComponent();
    add(_bird);

    _scoreText = TextComponent(
      text: '0',
      position: Vector2(size.x / 2, 48),
      anchor: Anchor.center,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFFFFEE58),
          fontSize: 46,
          fontWeight: FontWeight.bold,
          shadows: [
            Shadow(blurRadius: 2, color: Colors.black, offset: Offset(-2, -2)),
            Shadow(blurRadius: 2, color: Colors.black, offset: Offset(2, -2)),
            Shadow(blurRadius: 2, color: Colors.black, offset: Offset(-2, 2)),
            Shadow(blurRadius: 2, color: Colors.black, offset: Offset(2, 2)),
            Shadow(blurRadius: 8, color: Colors.black87),
          ],
        ),
      ),
    );
    add(_scoreText);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_running || _over) return;

    _pipeTimer += dt;
    if (_pipeTimer >= _pipeInterval) {
      _pipeTimer = 0;
      _spawnPipe();
    }
  }

  void _spawnPipe() {
    final rng = Random();
    final minTop = size.y * 0.15;
    final maxTop = size.y - _GroundComponent.groundHeight - _pipeGap - size.y * 0.15;
    final topH = minTop + rng.nextDouble() * (maxTop - minTop);
    add(PipePair(topHeight: topH, game: this));
  }

  @override
  void onTapDown(TapDownEvent event) => _flap();

  @override
  KeyEventResult onKeyEvent(
      KeyEvent event, Set<LogicalKeyboardKey> keysPressed) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.arrowUp)) {
      _flap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _flap() {
    if (_over) return;
    if (!_running) {
      _running = true;
      overlays.remove('Start');
    }
    _bird.flap();
  }

  void addScore() {
    _score++;
    _scoreText.text = '$_score';
  }

  void triggerGameOver() {
    if (_over) return;
    _over = true;
    pauseEngine();
    overlays.add('GameOver');
  }

  void restart() {
    _score = 0;
    _pipeTimer = 0;
    _over = false;
    _running = true;
    _scoreText.text = '0';
    children.whereType<PipePair>().toList().forEach((c) => c.removeFromParent());
    _bird.reset();
    overlays.remove('GameOver');
    resumeEngine();
  }

  int get score => _score;
}

// ── Ground ────────────────────────────────────────────────────────────────────

class _GroundComponent extends PositionComponent
    with HasGameRef<FlappyGame>, CollisionCallbacks {
  static const double groundHeight = 80.0;

  _GroundComponent() : super();

  @override
  Future<void> onLoad() async {
    size = Vector2(gameRef.size.x, groundHeight);
    position = Vector2(0, gameRef.size.y - groundHeight);
    add(RectangleHitbox());
  }

  @override
  void render(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, 14),
      Paint()..color = const Color(0xFF5DBB37),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 14, size.x, size.y - 14),
      Paint()..color = const Color(0xFFDEB887),
    );
  }
}

// ── Bird ──────────────────────────────────────────────────────────────────────

class BirdComponent extends PositionComponent
    with CollisionCallbacks, HasGameRef<FlappyGame> {
  static const double _gravity = 1500.0;
  static const double _flapV = -520.0;
  static const double _maxFallV = 900.0;
  static const double _birdSize = 36.0;

  double _vy = 0;
  double _angle = 0;

  BirdComponent() : super(size: Vector2(_birdSize, _birdSize));

  @override
  Future<void> onLoad() async {
    position = Vector2(gameRef.size.x * 0.25, gameRef.size.y * 0.45);
    anchor = Anchor.center;
    add(CircleHitbox(radius: _birdSize / 2 - 4));
  }

  @override
  void update(double dt) {
    final g = gameRef;
    if (!g._running) return;

    _vy = min(_vy + _gravity * dt, _maxFallV);
    position.y += _vy * dt;
    _angle = (_vy / _maxFallV * 1.1).clamp(-0.5, 1.1);

    if (position.y - size.y / 2 < 0) {
      position.y = size.y / 2;
      _vy = 0;
    }

    if (position.y + size.y / 2 >= g.size.y - _GroundComponent.groundHeight) {
      g.triggerGameOver();
    }
  }

  @override
  void render(Canvas canvas) {
    canvas.save();
    canvas.translate(size.x / 2, size.y / 2);
    canvas.rotate(_angle);
    canvas.translate(-size.x / 2, -size.y / 2);

    final r = size.x / 2;
    final bodyPaint = Paint()..color = const Color(0xFFFFD700);
    final wingPaint = Paint()..color = const Color(0xFFFFA500);
    final eyeWhite = Paint()..color = Colors.white;
    final eyePupil = Paint()..color = Colors.black;
    final beak = Paint()..color = const Color(0xFFFF6B00);

    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(size.x * 0.28, size.y * 0.55),
            width: size.x * 0.55,
            height: size.y * 0.32),
        wingPaint);
    canvas.drawCircle(Offset(r, r), r, bodyPaint);
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(size.x * 0.58, size.y * 0.62),
            width: size.x * 0.45,
            height: size.y * 0.38),
        Paint()..color = const Color(0xFFFFF9C4));
    canvas.drawCircle(Offset(size.x * 0.7, size.y * 0.32), 6.5, eyeWhite);
    canvas.drawCircle(Offset(size.x * 0.72, size.y * 0.32), 3.5, eyePupil);
    final beakPath = Path()
      ..moveTo(size.x * 0.88, size.y * 0.44)
      ..lineTo(size.x * 1.12, size.y * 0.5)
      ..lineTo(size.x * 0.88, size.y * 0.58)
      ..close();
    canvas.drawPath(beakPath, beak);

    canvas.restore();
  }

  void flap() {
    _vy = _flapV;
  }

  void reset() {
    position = Vector2(gameRef.size.x * 0.25, gameRef.size.y * 0.45);
    _vy = 0;
    _angle = 0;
  }

  @override
  void onCollisionStart(
      Set<Vector2> intersectionPoints, PositionComponent other) {
    super.onCollisionStart(intersectionPoints, other);
    if (other is _PipeBody || other is _GroundComponent) {
      gameRef.triggerGameOver();
    }
  }
}

// ── Pipe Pair ─────────────────────────────────────────────────────────────────

class PipePair extends PositionComponent with HasGameRef<FlappyGame> {
  final double topHeight;
  bool _scored = false;

  PipePair({required this.topHeight, required FlappyGame game});

  @override
  Future<void> onLoad() async {
    position = Vector2(gameRef.size.x + FlappyGame._pipeWidth, 0);
    final groundTop = gameRef.size.y - _GroundComponent.groundHeight;

    add(_PipeBody(
      pipePosition: Vector2(0, 0),
      pipeSize: Vector2(FlappyGame._pipeWidth, topHeight),
      isTop: true,
    ));
    final bottomY = topHeight + FlappyGame._pipeGap;
    add(_PipeBody(
      pipePosition: Vector2(0, bottomY),
      pipeSize: Vector2(FlappyGame._pipeWidth, groundTop - bottomY),
      isTop: false,
    ));
  }

  @override
  void update(double dt) {
    position.x -= FlappyGame._pipeSpeed * dt;

    if (!_scored && position.x + FlappyGame._pipeWidth < gameRef._bird.x) {
      _scored = true;
      gameRef.addScore();
    }

    if (position.x + FlappyGame._pipeWidth < 0) removeFromParent();
  }
}

class _PipeBody extends PositionComponent
    with HasGameRef<FlappyGame>, CollisionCallbacks {
  final bool isTop;

  _PipeBody({
    required Vector2 pipePosition,
    required Vector2 pipeSize,
    required this.isTop,
  }) : super(position: pipePosition, size: pipeSize);

  @override
  Future<void> onLoad() async {
    add(RectangleHitbox());
  }

  @override
  void render(Canvas canvas) {
    final bodyPaint = Paint()..color = const Color(0xFF4CAF50);
    final darkPaint = Paint()..color = const Color(0xFF2E7D32);
    const capH = 22.0;
    const capExtra = 6.0;

    if (isTop) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(0, 0, size.x, size.y - capH),
              const Radius.circular(3)),
          bodyPaint);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(-capExtra, size.y - capH, size.x + capExtra * 2, capH),
              const Radius.circular(5)),
          darkPaint);
    } else {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(-capExtra, 0, size.x + capExtra * 2, capH),
              const Radius.circular(5)),
          darkPaint);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(0, capH, size.x, size.y - capH),
              const Radius.circular(3)),
          bodyPaint);
    }
  }
}

// ── Start Overlay ─────────────────────────────────────────────────────────────

class _StartOverlay extends StatefulWidget {
  final FlappyGame game;
  const _StartOverlay({required this.game});

  @override
  State<_StartOverlay> createState() => _StartOverlayState();
}

class _StartOverlayState extends State<_StartOverlay> {
  List<dynamic>? _top10;

  @override
  void initState() {
    super.initState();
    _loadTop10();
  }

  Future<void> _loadTop10() async {
    final data = await _GameScoreService.getTop10();
    if (mounted) setState(() => _top10 = data);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🐦', style: TextStyle(fontSize: 72)),
          const SizedBox(height: 12),
          const Text('플래피 버드',
              style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)])),
          const SizedBox(height: 8),
          Text('탭 or 스페이스바로 날아요!',
              style: TextStyle(
                  fontSize: 15,
                  color: Colors.white.withOpacity(0.9),
                  shadows: const [Shadow(blurRadius: 4, color: Colors.black38)])),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () => widget.game._flap(),
            icon: const Icon(Icons.play_arrow),
            label: const Text('시작하기'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          if (_top10 != null && _top10!.isNotEmpty) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => _showLeaderboard(context),
              icon: const Icon(Icons.emoji_events, color: Colors.amber),
              label: const Text('명예의 전당 보기',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black38)])),
            ),
          ],
        ],
      ),
    );
  }

  void _showLeaderboard(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _LeaderboardDialog(entries: _top10!),
    );
  }
}

// ── Game Over Overlay ─────────────────────────────────────────────────────────

class _GameOverOverlay extends StatefulWidget {
  final FlappyGame game;
  const _GameOverOverlay({required this.game});

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
    // 점수 저장 먼저, 완료 후 Top10 조회 (순서 바뀌면 새 기록이 반영 안 됨)
    final summary = await _GameScoreService.submitScore(widget.game.score);
    final top10 = await _GameScoreService.getTop10();
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
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(blurRadius: 16, color: Colors.black26)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💥', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 6),
            const Text('게임 오버!',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('이번 점수: ${widget.game.score}',
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
                          child: CircularProgressIndicator(strokeWidth: 2))))
            else if (_summary != null)
              _ScoreBanner(summary: _summary!),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_top10 != null && _top10!.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => showDialog(
                      context: context,
                      builder: (_) => _LeaderboardDialog(entries: _top10!),
                    ),
                    icon: const Icon(Icons.emoji_events),
                    label: const Text('명예의 전당'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                  ),
                if (_top10 != null && _top10!.isNotEmpty) const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: widget.game.restart,
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
    );
  }
}

// ── Score Banner (내 최고 vs 파트너) ──────────────────────────────────────────

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
              _ScoreColumn(
                  label: '나',
                  score: myBest,
                  isCrown: myWinning && partnerBest != null,
                  highlight: true),
              Container(width: 1, height: 40, color: Colors.grey.shade300),
              if (partnerBest != null && partnerNickname != null)
                _ScoreColumn(
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
                  color: myBest >= partnerBest ? Colors.green : Colors.orange),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScoreColumn extends StatelessWidget {
  final String label;
  final int score;
  final bool isCrown;
  final bool highlight;

  const _ScoreColumn({
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
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 12),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: entries.length,
                separatorBuilder: (context, i) =>
                    Divider(height: 1, color: Colors.grey.shade200),
                itemBuilder: (context, i) {
                  final e = entries[i] as Map<String, dynamic>;
                  final rank = e['rank'] as int? ?? (i + 1);
                  final isMe = e['isMe'] as bool? ?? false;
                  final rankLabel = rank <= 3
                      ? _rankEmoji[rank - 1]
                      : '$rank위';

                  return Container(
                    color: isMe
                        ? theme.colorScheme.primary.withOpacity(0.07)
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
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text('나',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: theme.colorScheme.onPrimary,
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
                                fontSize: 11, color: Colors.grey.shade500),
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
