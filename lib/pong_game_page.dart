import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';
import 'api_client.dart';
import 'api_endpoints.dart';

// ── Pong 실시간 대전 ──────────────────────────────────────────────────────────
//
// 백엔드 WebSocket 약속:
//   Subscribe : /sub/couple/{coupleId}/game/pong
//   Publish   : /pub/game/pong
//   메시지 형식:
//     { type: "JOIN",    memberId, coupleId }
//     { type: "ROLE",    isLeft: bool, memberId }   ← 서버가 역할 배정
//     { type: "PADDLE",  y: double(0~1), memberId, coupleId }
//     { type: "BALL",    bx, by, vx, vy, memberId, coupleId }  ← 왼쪽 플레이어만 전송
//     { type: "SCORE",   left: int, right: int, memberId, coupleId }
//     { type: "READY",   memberId, coupleId }
//
// 역할:
//   isLeft=true  → 왼쪽 패들, 공 물리 담당(authoritative), BALL 메시지 전송
//   isLeft=false → 오른쪽 패들, 상대 BALL 위치 수신 후 보간

class PongGamePage extends StatefulWidget {
  final int memberId;
  final int coupleId;

  const PongGamePage({
    super.key,
    required this.memberId,
    required this.coupleId,
  });

  @override
  State<PongGamePage> createState() => _PongGamePageState();
}

class _PongGamePageState extends State<PongGamePage>
    with SingleTickerProviderStateMixin {
  // 게임 상수
  static const double _paddleH = 0.18; // 패들 높이 (화면 비율)
  static const double _paddleW = 0.025;
  static const double _ballR = 0.018;
  static const double _paddleX = 0.04;
  static const double _initialSpeed = 0.55; // 초당 이동 (화면 비율)
  static const double _speedUp = 0.04; // 랠리마다 속도 증가
  static const int _winScore = 5;

  // 게임 상태
  double _myPaddleY = 0.5; // 내 패들 중심 y
  double _opPaddleY = 0.5; // 상대 패들 중심 y
  double _bx = 0.5, _by = 0.5; // 공 위치
  double _vx = 0.0, _vy = 0.0; // 공 속도
  int _myScore = 0, _opScore = 0;
  int _rally = 0;

  bool _isLeft = true; // 내 역할 (서버가 배정)
  bool _connected = false;
  bool _partnerConnected = false;
  bool _gameOver = false;
  bool _waitingBall = true; // 서브 대기 중
  String? _winnerMsg;

  // 드래그
  double? _dragStartY;
  double? _paddleStartY;

  // WebSocket
  StompClient? _stomp;

  // 게임 루프 (왼쪽 플레이어만 물리 담당)
  late final Ticker _ticker; // flutter/scheduler.dart Ticker
  DateTime? _lastTime;

  // 상대 공 보간용 (오른쪽 플레이어)
  double _remoteBx = 0.5, _remoteBy = 0.5;
  double _remoteVx = 0.0, _remoteVy = 0.0;

  // 공 전송 타이머 (왼쪽)
  Timer? _ballSyncTimer;
  Timer? _serveTimer; // 득점 후 서브 지연 타이머

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _connect();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _ballSyncTimer?.cancel();
    _serveTimer?.cancel();
    _stomp?.deactivate();
    super.dispose();
  }

  // ── WebSocket ────────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    final headers = await ApiClient.stompHeaders();
    _stomp = StompClient(
      config: StompConfig(
        url: ApiEndpoints.wsUrl,
        stompConnectHeaders: headers,
        onConnect: _onConnect,
        onWebSocketError: (e) => debugPrint('Pong 소켓 에러: $e'),
      ),
    );
    _stomp!.activate();
  }

  void _onConnect(StompFrame _) {
    _stomp!.subscribe(
      destination: '/sub/couple/${widget.coupleId}/game/pong',
      callback: _onMessage,
    );
    _send({'type': 'JOIN', 'memberId': widget.memberId, 'coupleId': widget.coupleId});
    if (mounted) setState(() => _connected = true);
  }

  void _onMessage(StompFrame frame) {
    if (frame.body == null || !mounted) return;
    final msg = jsonDecode(frame.body!) as Map<String, dynamic>;
    final type = msg['type'] as String? ?? '';
    final senderId = msg['memberId'] as int?;
    final isMe = senderId == widget.memberId;

    if (type == 'ROLE') {
      if (isMe) {
        _isLeft = msg['isLeft'] as bool? ?? true;
        // 내 ROLE 확정 시점에만 서브 — 브로드캐스트로 두 ROLE을 받더라도 이중 서브 방지
        if (_isLeft) _serveBall();
      }
      _partnerConnected = true;
      setState(() {});
    } else if (type == 'JOIN' && !isMe) {
      setState(() => _partnerConnected = true);
    } else if (type == 'PADDLE' && !isMe) {
      setState(() => _opPaddleY = (msg['y'] as num).toDouble());
    } else if (type == 'BALL' && !isMe) {
      // 오른쪽 플레이어: 수신 즉시 공 위치 스냅 + 속도 저장 (dead reckoning 기준점)
      setState(() {
        _remoteBx = (msg['bx'] as num).toDouble();
        _remoteBy = (msg['by'] as num).toDouble();
        _remoteVx = (msg['vx'] as num).toDouble();
        _remoteVy = (msg['vy'] as num).toDouble();
        _bx = _remoteBx;
        _by = _remoteBy;
        _waitingBall = false; // 공이 날아오기 시작했으므로 해제
        _lastTime = DateTime.now(); // 보간 기준점 리셋
      });
    } else if (type == 'SCORE') {
      setState(() {
        _myScore = isMe
            ? (msg['myScore'] as int? ?? _myScore)
            : (msg['opScore'] as int? ?? _myScore);
        _opScore = isMe
            ? (msg['opScore'] as int? ?? _opScore)
            : (msg['myScore'] as int? ?? _opScore);
        if (!isMe) _waitingBall = true; // 오른쪽 플레이어: 서브 대기로 전환
      });
      if (_myScore >= _winScore || _opScore >= _winScore) {
        setState(() {
          _gameOver = true;
          _winnerMsg = _myScore >= _winScore ? '내가 이겼어요! 🎉' : '상대방이 이겼어요 😢';
        });
      }
    } else if (type == 'RESET') {
      setState(() {
        _myScore = 0;
        _opScore = 0;
        _gameOver = false;
        _winnerMsg = null;
        _waitingBall = true;
        _rally = 0;
      });
      if (_isLeft) _serveBall();
    }
  }

  void _send(Map<String, dynamic> data) {
    if (_stomp?.connected != true) return;
    _stomp!.send(destination: '/pub/game/pong', body: jsonEncode(data));
  }

  // ── 게임 로직 ────────────────────────────────────────────────────────────────

  void _serveBall() {
    final rng = Random();
    final angle = (rng.nextDouble() * 0.6 - 0.3);
    final speed = _initialSpeed;
    setState(() {
      _bx = 0.5;
      _by = 0.5;
      _vx = speed * cos(angle) * (rng.nextBool() ? 1 : -1);
      _vy = speed * sin(angle);
      _waitingBall = false;
      _rally = 0;
    });
    // 공 위치 20fps 동기화 타이머 (왼쪽 플레이어만)
    _ballSyncTimer?.cancel();
    _ballSyncTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_stomp?.connected == true) {
        _send({
          'type': 'BALL',
          'bx': _bx,
          'by': _by,
          'vx': _vx,
          'vy': _vy,
          'memberId': widget.memberId,
          'coupleId': widget.coupleId,
        });
      }
    });
  }

  void _onTick(Duration elapsed) {
    if (!mounted || _gameOver || _waitingBall || !_partnerConnected) return;

    final now = DateTime.now();
    if (_lastTime == null) {
      _lastTime = now;
      return;
    }
    final dt = (now.difference(_lastTime!).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _lastTime = now;

    if (_isLeft) {
      _updateBallPhysics(dt);
    } else {
      // 마지막 수신 위치 기준으로 dead reckoning (수신 기준점은 덮어쓰지 않음)
      final nbx = _remoteBx + _remoteVx * dt;
      final nby = _remoteBy + _remoteVy * dt;
      setState(() {
        _bx = nbx.clamp(0.0, 1.0);
        _by = nby.clamp(0.0, 1.0);
        // clamp 전 값으로 벽 반사 여부 판단
        if (nby <= _ballR || nby >= 1 - _ballR) _remoteVy = -_remoteVy;
        _remoteBx = _bx;
        _remoteBy = _by;
      });
    }
  }

  void _updateBallPhysics(double dt) {
    double nx = _bx + _vx * dt;
    double ny = _by + _vy * dt;
    double nvx = _vx;
    double nvy = _vy;

    // 위아래 벽
    if (ny - _ballR < 0) {
      ny = _ballR;
      nvy = nvy.abs();
    } else if (ny + _ballR > 1) {
      ny = 1 - _ballR;
      nvy = -nvy.abs();
    }

    // 내 패들 (왼쪽)
    final myPaddleTop = _myPaddleY - _paddleH / 2;
    final myPaddleBot = _myPaddleY + _paddleH / 2;
    if (nvx < 0 && nx - _ballR <= _paddleX + _paddleW && nx - _ballR > _paddleX) {
      if (ny >= myPaddleTop && ny <= myPaddleBot) {
        final rel = (ny - _myPaddleY) / (_paddleH / 2); // -1 ~ 1
        final speed = _initialSpeed + _rally * _speedUp;
        final angle = rel * 0.9;
        nvx = speed * cos(angle);
        nvy = speed * sin(angle);
        nx = _paddleX + _paddleW + _ballR;
        _rally++;
      }
    }

    // 상대 패들 (오른쪽)
    final opPaddleTop = _opPaddleY - _paddleH / 2;
    final opPaddleBot = _opPaddleY + _paddleH / 2;
    if (nvx > 0 && nx + _ballR >= 1 - _paddleX - _paddleW && nx + _ballR < 1 - _paddleX) {
      if (ny >= opPaddleTop && ny <= opPaddleBot) {
        final rel = (ny - _opPaddleY) / (_paddleH / 2);
        final speed = _initialSpeed + _rally * _speedUp;
        final angle = rel * 0.9;
        nvx = -speed * cos(angle);
        nvy = speed * sin(angle);
        nx = 1 - _paddleX - _paddleW - _ballR;
        _rally++;
      }
    }

    // 득점
    if (nx < 0) {
      _opScore++;
      _sendScore();
      _serveAfterDelay();
      return;
    } else if (nx > 1) {
      _myScore++;
      _sendScore();
      _serveAfterDelay();
      return;
    }

    setState(() {
      _bx = nx;
      _by = ny;
      _vx = nvx;
      _vy = nvy;
    });
  }

  void _sendScore() {
    _send({
      'type': 'SCORE',
      'myScore': _myScore,
      'opScore': _opScore,
      'memberId': widget.memberId,
      'coupleId': widget.coupleId,
    });
    if (_myScore >= _winScore || _opScore >= _winScore) {
      setState(() {
        _gameOver = true;
        _winnerMsg = _myScore >= _winScore ? '내가 이겼어요! 🎉' : '상대방이 이겼어요 😢';
        _waitingBall = true;
      });
    }
  }

  void _serveAfterDelay() {
    setState(() => _waitingBall = true);
    _ballSyncTimer?.cancel();
    _ballSyncTimer = null;
    _serveTimer?.cancel();
    _serveTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_gameOver && _isLeft) _serveBall();
    });
  }

  void _requestReset() {
    _serveTimer?.cancel(); // 득점 후 지연 서브가 남아있으면 취소
    setState(() {
      _myScore = 0;
      _opScore = 0;
      _gameOver = false;
      _winnerMsg = null;
      _waitingBall = true;
      _rally = 0;
    });
    _send({'type': 'RESET', 'memberId': widget.memberId, 'coupleId': widget.coupleId});
    // 서브는 RESET 에코를 받을 때 한 번만 실행 (이중 서브 방지)
  }

  // ── 드래그 (패들 조작) ───────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails d, double boardH) {
    _dragStartY = d.localPosition.dy;
    _paddleStartY = _myPaddleY;
  }

  void _onPanUpdate(DragUpdateDetails d, double boardH) {
    if (_dragStartY == null || _paddleStartY == null) return;
    final delta = (d.localPosition.dy - _dragStartY!) / boardH;
    final newY = (_paddleStartY! + delta).clamp(_paddleH / 2, 1 - _paddleH / 2);
    setState(() => _myPaddleY = newY);
    _send({
      'type': 'PADDLE',
      'y': _myPaddleY,
      'memberId': widget.memberId,
      'coupleId': widget.coupleId,
    });
  }

  // ── UI ───────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('🏓 Pong'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (_gameOver)
            TextButton(
              onPressed: _connected ? _requestReset : null,
              child: const Text('다시', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildScoreBar(),
          Expanded(child: _buildArena()),
          _buildGuide(),
        ],
      ),
    );
  }

  Widget _buildScoreBar() {
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('나  $_myScore',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(':', style: TextStyle(color: Colors.white54, fontSize: 24)),
          ),
          Text('$_opScore  상대',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildArena() {
    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      return GestureDetector(
        onPanStart: (d) => _onPanStart(d, h),
        onPanUpdate: (d) => _onPanUpdate(d, h),
        child: Stack(
          children: [
            CustomPaint(
              painter: _PongPainter(
                myPaddleY: _myPaddleY,
                opPaddleY: _opPaddleY,
                bx: _bx,
                by: _by,
                paddleH: _paddleH,
                paddleW: _paddleW,
                paddleX: _paddleX,
                ballR: _ballR,
                isLeft: _isLeft,
              ),
              child: const SizedBox.expand(),
            ),
            if (!_connected || !_partnerConnected)
              Container(
                color: Colors.black.withValues(alpha: 0.7),
                child: Center(
                  child: Text(
                    !_connected ? '연결 중...' : '상대방 기다리는 중...',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            if (_waitingBall && _partnerConnected && !_gameOver)
              const Center(
                child: Text('🏓',
                    style: TextStyle(fontSize: 48, color: Colors.white54)),
              ),
            if (_gameOver)
              Container(
                color: Colors.black.withValues(alpha: 0.75),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_winnerMsg ?? '',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _requestReset,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                        ),
                        child: const Text('다시 하기'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }

  Widget _buildGuide() {
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        _isLeft ? '← 왼쪽 패들 (드래그로 조작)' : '오른쪽 패들 → (드래그로 조작)',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
      ),
    );
  }
}

// ── Pong CustomPainter ────────────────────────────────────────────────────────

class _PongPainter extends CustomPainter {
  final double myPaddleY, opPaddleY;
  final double bx, by;
  final double paddleH, paddleW, paddleX, ballR;
  final bool isLeft;

  const _PongPainter({
    required this.myPaddleY,
    required this.opPaddleY,
    required this.bx,
    required this.by,
    required this.paddleH,
    required this.paddleW,
    required this.paddleX,
    required this.ballR,
    required this.isLeft,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 배경
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black);

    // 중앙선
    final dashPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 2;
    for (double y = 0; y < h; y += 20) {
      canvas.drawLine(Offset(w / 2, y), Offset(w / 2, y + 10), dashPaint);
    }

    // 내 패들 (왼쪽이면 왼쪽, 오른쪽이면 오른쪽)
    final myPaddlePaint = Paint()..color = Colors.blue.shade300;
    final opPaddlePaint = Paint()..color = Colors.red.shade300;

    final myX = isLeft ? paddleX * w : (1 - paddleX - paddleW) * w;
    final opX = isLeft ? (1 - paddleX - paddleW) * w : paddleX * w;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(myX, (myPaddleY - paddleH / 2) * h, paddleW * w, paddleH * h),
        const Radius.circular(6),
      ),
      myPaddlePaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(opX, (opPaddleY - paddleH / 2) * h, paddleW * w, paddleH * h),
        const Radius.circular(6),
      ),
      opPaddlePaint,
    );

    // 공
    canvas.drawCircle(
      Offset(bx * w, by * h),
      ballR * w,
      Paint()..color = Colors.white,
    );
    // 공 광택
    canvas.drawCircle(
      Offset(bx * w - ballR * w * 0.3, by * h - ballR * w * 0.3),
      ballR * w * 0.35,
      Paint()..color = Colors.white.withValues(alpha: 0.6),
    );
  }

  @override
  bool shouldRepaint(_PongPainter old) => true;
}
