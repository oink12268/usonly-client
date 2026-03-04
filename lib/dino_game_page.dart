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
        title: const Text('디노 런 🦖'),
        backgroundColor: const Color(0xFF8B7E74),
        foregroundColor: Colors.white,
      ),
      body: GameWidget<DinoGame>(
        game: DinoGame(),
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

class DinoGame extends FlameGame
    with TapCallbacks, HasCollisionDetection, KeyboardEvents {
  static const double _groundH = 70.0;

  late DinoComponent _dino;
  late TextComponent _scoreText;

  double _score = 0;
  double _gameSpeed = 280;
  double _obstacleTimer = 0;
  double _obstacleInterval = 1.8;
  bool _running = false;
  bool _over = false;

  double get groundY => size.y - _groundH;

  @override
  Color backgroundColor() => const Color(0xFFEEF9FF);

  @override
  Future<void> onLoad() async {
    // Ground fill
    add(RectangleComponent(
      position: Vector2(0, groundY),
      size: Vector2(size.x, _groundH),
      paint: Paint()..color = const Color(0xFF8B7E74),
    ));
    // Ground top border
    add(RectangleComponent(
      position: Vector2(0, groundY),
      size: Vector2(size.x, 3),
      paint: Paint()..color = const Color(0xFF5D4037),
    ));

    _dino = DinoComponent();
    add(_dino);

    _scoreText = TextComponent(
      text: '점수: 0',
      position: Vector2(size.x - 16, 16),
      anchor: Anchor.topRight,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFF333333),
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    add(_scoreText);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_running || _over) return;

    _score += dt * 10;
    _scoreText.text = '점수: ${_score.toInt()}';
    _gameSpeed = 280 + _score * 0.4;

    _obstacleTimer += dt;
    if (_obstacleTimer >= _obstacleInterval) {
      _obstacleTimer = 0;
      _obstacleInterval = max(0.7, 1.8 - _score * 0.001);
      add(ObstacleComponent(speed: _gameSpeed));
    }
  }

  @override
  void onTapDown(TapDownEvent event) {
    if (!_running) {
      _start();
    } else {
      _dino.jump();
    }
  }

  @override
  KeyEventResult onKeyEvent(
      KeyEvent event, Set<LogicalKeyboardKey> keysPressed) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.arrowUp)) {
      if (!_running) {
        _start();
      } else {
        _dino.jump();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _start() {
    _running = true;
    overlays.remove('Start');
  }

  void triggerGameOver() {
    _over = true;
    pauseEngine();
    overlays.add('GameOver');
  }

  void restart() {
    _score = 0;
    _gameSpeed = 280;
    _obstacleTimer = 0;
    _obstacleInterval = 1.8;
    _over = false;
    _running = true;
    children
        .whereType<ObstacleComponent>()
        .toList()
        .forEach((c) => c.removeFromParent());
    _dino.reset();
    overlays.remove('GameOver');
    resumeEngine();
  }
}

// ── Dino ──────────────────────────────────────────────────────────────────────

class DinoComponent extends PositionComponent with CollisionCallbacks {
  static const double _gravity = 1400.0;
  static const double _jumpV = -620.0;

  double _vy = 0;
  bool _onGround = true;

  DinoComponent() : super(size: Vector2(42, 48));

  DinoGame get _game => game as DinoGame;

  @override
  Future<void> onLoad() async {
    position = Vector2(80, _game.groundY - size.y);
    add(RectangleHitbox(
      position: Vector2(3, 2),
      size: Vector2(size.x - 6, size.y - 2),
    ));
  }

  @override
  void update(double dt) {
    if (_onGround) return;
    _vy += _gravity * dt;
    position.y += _vy * dt;
    final floor = _game.groundY - size.y;
    if (position.y >= floor) {
      position.y = floor;
      _vy = 0;
      _onGround = true;
    }
  }

  @override
  void render(Canvas canvas) {
    final green = Paint()..color = const Color(0xFF4CAF50);
    final darkGreen = Paint()..color = const Color(0xFF388E3C);

    // Body
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(0, size.y * 0.35, size.x, size.y * 0.65),
            const Radius.circular(8)),
        green);
    // Head
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(size.x * 0.28, 0, size.x * 0.72, size.y * 0.52),
            const Radius.circular(7)),
        green);
    // Eye white
    canvas.drawCircle(
        Offset(size.x - 7, size.y * 0.18), 5, Paint()..color = Colors.white);
    // Eye pupil
    canvas.drawCircle(
        Offset(size.x - 5.5, size.y * 0.18), 3, Paint()..color = Colors.black87);
    // Legs
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(5, size.y - 11, 12, 11), const Radius.circular(3)),
        darkGreen);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(size.x * 0.42, size.y - 11, 12, 11),
            const Radius.circular(3)),
        darkGreen);
  }

  void jump() {
    if (_onGround) {
      _vy = _jumpV;
      _onGround = false;
    }
  }

  void reset() {
    _vy = 0;
    _onGround = true;
    position.y = _game.groundY - size.y;
  }

  @override
  void onCollisionStart(
      Set<Vector2> intersectionPoints, PositionComponent other) {
    if (other is ObstacleComponent) {
      _game.triggerGameOver();
    }
  }
}

// ── Obstacle (Cactus) ─────────────────────────────────────────────────────────

class ObstacleComponent extends PositionComponent {
  final double speed;
  static final _rng = Random();

  ObstacleComponent({required this.speed});

  @override
  Future<void> onLoad() async {
    final g = game as DinoGame;
    final isTall = _rng.nextBool();
    final h = isTall
        ? 60.0 + _rng.nextDouble() * 25
        : 32.0 + _rng.nextDouble() * 18;
    final w = isTall ? 22.0 : 30.0;
    size = Vector2(w, h);
    position = Vector2(g.size.x + 10, g.groundY - h);
    add(RectangleHitbox(
      position: Vector2(2, 0),
      size: Vector2(size.x - 4, size.y),
    ));
  }

  @override
  void update(double dt) {
    position.x -= speed * dt;
    if (position.x + size.x < 0) removeFromParent();
  }

  @override
  void render(Canvas canvas) {
    final paint = Paint()..color = const Color(0xFF2E7D32);
    // Main stem
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(size.x * 0.3, 0, size.x * 0.4, size.y),
            const Radius.circular(4)),
        paint);
    // Arms
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(0, size.y * 0.25, size.x, size.y * 0.2),
            const Radius.circular(4)),
        paint);
  }
}

// ── Overlays ──────────────────────────────────────────────────────────────────

class _StartOverlay extends StatelessWidget {
  final DinoGame game;
  const _StartOverlay({required this.game});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🦖', style: TextStyle(fontSize: 64)),
          const SizedBox(height: 12),
          const Text('디노 런',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('탭 or 스페이스바로 점프!',
              style: TextStyle(fontSize: 14, color: Colors.grey[600])),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => game._start(),
            icon: const Icon(Icons.play_arrow),
            label: const Text('시작하기'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B7E74),
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _GameOverOverlay extends StatelessWidget {
  final DinoGame game;
  const _GameOverOverlay({required this.game});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('💥', style: TextStyle(fontSize: 52)),
          const SizedBox(height: 8),
          const Text('게임 오버!',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: game.restart,
            icon: const Icon(Icons.refresh),
            label: const Text('다시 시작'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B7E74),
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }
}
