import 'dart:math';
import 'package:flame/game.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/collisions.dart';
import 'package:flutter/material.dart' hide Gradient;
import 'package:flutter/services.dart';

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
    // Ground
    add(_GroundComponent());

    _bird = BirdComponent();
    add(_bird);

    _scoreText = TextComponent(
      text: '0',
      position: Vector2(size.x / 2, 48),
      anchor: Anchor.center,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 44,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(blurRadius: 4, color: Colors.black45)],
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
    // Grass strip
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, 14),
      Paint()..color = const Color(0xFF5DBB37),
    );
    // Dirt
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

    // Tilt: nose up on flap, nose down on fall
    _angle = (_vy / _maxFallV * 1.1).clamp(-0.5, 1.1);

    // Hit ceiling
    if (position.y - size.y / 2 < 0) {
      position.y = size.y / 2;
      _vy = 0;
    }

    // Hit ground
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

    // Wing
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(size.x * 0.28, size.y * 0.55),
            width: size.x * 0.55,
            height: size.y * 0.32),
        wingPaint);
    // Body
    canvas.drawCircle(Offset(r, r), r, bodyPaint);
    // Belly
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(size.x * 0.58, size.y * 0.62),
            width: size.x * 0.45,
            height: size.y * 0.38),
        Paint()..color = const Color(0xFFFFF9C4));
    // Eye white
    canvas.drawCircle(Offset(size.x * 0.7, size.y * 0.32), 6.5, eyeWhite);
    // Pupil
    canvas.drawCircle(Offset(size.x * 0.72, size.y * 0.32), 3.5, eyePupil);
    // Beak
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

    // Top pipe
    add(_PipeBody(
      pipePosition: Vector2(0, 0),
      pipeSize: Vector2(FlappyGame._pipeWidth, topHeight),
      isTop: true,
    ));
    // Bottom pipe
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
      // Pipe body
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(0, 0, size.x, size.y - capH),
              const Radius.circular(3)),
          bodyPaint);
      // Cap at bottom
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(-capExtra, size.y - capH, size.x + capExtra * 2, capH),
              const Radius.circular(5)),
          darkPaint);
    } else {
      // Cap at top
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(-capExtra, 0, size.x + capExtra * 2, capH),
              const Radius.circular(5)),
          darkPaint);
      // Pipe body
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(0, capH, size.x, size.y - capH),
              const Radius.circular(3)),
          bodyPaint);
    }
  }
}

// ── Overlays ──────────────────────────────────────────────────────────────────

class _StartOverlay extends StatelessWidget {
  final FlappyGame game;
  const _StartOverlay({required this.game});

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
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: () => game._flap(),
            icon: const Icon(Icons.play_arrow),
            label: const Text('시작하기'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

class _GameOverOverlay extends StatelessWidget {
  final FlappyGame game;
  const _GameOverOverlay({required this.game});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 40),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.92),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(blurRadius: 16, color: Colors.black26)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💥', style: TextStyle(fontSize: 52)),
            const SizedBox(height: 8),
            const Text('게임 오버!',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('점수: ${game.score}',
                style: TextStyle(
                    fontSize: 20,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 22),
            ElevatedButton.icon(
              onPressed: game.restart,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시작'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
