import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';
import 'api_client.dart';
import 'api_endpoints.dart';

// ── 오목 게임 페이지 ────────────────────────────────────────────────────────────
//
// 백엔드 WebSocket 약속:
//   Subscribe : /sub/couple/{coupleId}/game/gomoku
//   Publish   : /pub/game/gomoku
//   메시지 형식 : { "type": "MOVE"|"RESET"|"SURRENDER", "x": int, "y": int, "coupleId": int, "memberId": int }

class GomokuGamePage extends StatefulWidget {
  final int memberId;
  final int coupleId;

  const GomokuGamePage({
    super.key,
    required this.memberId,
    required this.coupleId,
  });

  @override
  State<GomokuGamePage> createState() => _GomokuGamePageState();
}

class _GomokuGamePageState extends State<GomokuGamePage> {
  static const int _size = 15;

  // 0 = 빈칸, 1 = 나(흑), 2 = 상대(백)
  List<List<int>> _board = List.generate(_size, (_) => List.filled(_size, 0));

  bool _myTurn = true; // 방장(먼저 접속)이 흑, 나중 접속이 백
  bool _isBlack = true; // 내가 흑인지
  bool _gameOver = false;
  String? _winnerMsg;
  List<_Pos>? _winLine;

  StompClient? _stomp;
  bool _connected = false;
  bool _partnerConnected = false;

  // 채팅처럼 onConnect 후 구독
  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _stomp?.deactivate();
    super.dispose();
  }

  Future<void> _connect() async {
    final headers = await ApiClient.stompHeaders();
    _stomp = StompClient(
      config: StompConfig(
        url: ApiEndpoints.wsUrl,
        stompConnectHeaders: headers,
        onConnect: _onConnect,
        onWebSocketError: (e) => debugPrint('오목 소켓 에러: $e'),
        onDisconnect: (_) {
          if (mounted) setState(() => _connected = false);
        },
      ),
    );
    _stomp!.activate();
  }

  void _onConnect(StompFrame frame) {
    _stomp!.subscribe(
      destination: '/sub/couple/${widget.coupleId}/game/gomoku',
      callback: _onMessage,
    );
    // 내 접속 알림 (선후 결정)
    _send({'type': 'JOIN', 'memberId': widget.memberId, 'coupleId': widget.coupleId});
    if (mounted) setState(() => _connected = true);
  }

  void _onMessage(StompFrame frame) {
    if (frame.body == null || !mounted) return;
    final msg = jsonDecode(frame.body!) as Map<String, dynamic>;
    final type = msg['type'] as String? ?? '';
    final senderId = msg['memberId'] as int?;
    final isMe = senderId == widget.memberId;

    setState(() {
      if (type == 'JOIN') {
        if (!isMe) _partnerConnected = true;
      } else if (type == 'ROLE') {
        // 서버가 역할 배정: { type: ROLE, isBlack: bool, memberId: ... }
        if (isMe) _isBlack = msg['isBlack'] as bool? ?? true;
        _myTurn = _isBlack; // 흑 선공
        _partnerConnected = true;
      } else if (type == 'MOVE') {
        final x = msg['x'] as int;
        final y = msg['y'] as int;
        // 흑 플레이어가 놓은 돌 = 1, 백 플레이어가 놓은 돌 = 2
        final stone = (isMe == _isBlack) ? 1 : 2;
        if (_board[y][x] == 0 && !_gameOver) {
          _board[y][x] = stone;
          final win = _checkWin(x, y, stone);
          if (win != null) {
            _winLine = win;
            _gameOver = true;
            _winnerMsg = isMe ? '내가 이겼어요! 🎉' : '상대방이 이겼어요 😢';
          } else {
            _myTurn = isMe ? false : true;
          }
        }
      } else if (type == 'RESET') {
        _resetBoard();
      } else if (type == 'SURRENDER') {
        if (!isMe) {
          _gameOver = true;
          _winnerMsg = '상대방이 기권했어요! 🎉';
        }
      }
    });
  }

  void _send(Map<String, dynamic> data) {
    if (_stomp?.connected != true) return;
    _stomp!.send(
      destination: '/pub/game/gomoku',
      body: jsonEncode(data),
    );
  }

  void _placePiece(int x, int y) {
    if (!_connected || !_partnerConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('상대방이 아직 접속하지 않았어요')),
      );
      return;
    }
    if (_gameOver || !_myTurn || _board[y][x] != 0) return;

    // optimistic update
    final myStone = _isBlack ? 1 : 2;
    setState(() {
      _board[y][x] = myStone;
      final win = _checkWin(x, y, myStone);
      if (win != null) {
        _winLine = win;
        _gameOver = true;
        _winnerMsg = '내가 이겼어요! 🎉';
      } else {
        _myTurn = false;
      }
    });

    _send({
      'type': 'MOVE',
      'x': x,
      'y': y,
      'memberId': widget.memberId,
      'coupleId': widget.coupleId,
    });
  }

  void _resetBoard() {
    _board = List.generate(_size, (_) => List.filled(_size, 0));
    _gameOver = false;
    _winnerMsg = null;
    _winLine = null;
    _myTurn = _isBlack;
  }

  void _requestReset() {
    setState(() => _resetBoard());
    _send({'type': 'RESET', 'memberId': widget.memberId, 'coupleId': widget.coupleId});
  }

  void _surrender() {
    setState(() {
      _gameOver = true;
      _winnerMsg = '기권했어요 😔';
    });
    _send({'type': 'SURRENDER', 'memberId': widget.memberId, 'coupleId': widget.coupleId});
  }

  // 5개 연속 체크 → 이기면 위치 목록 반환
  List<_Pos>? _checkWin(int x, int y, int stone) {
    const dirs = [
      [1, 0], [0, 1], [1, 1], [1, -1],
    ];
    for (final d in dirs) {
      final line = <_Pos>[_Pos(x, y)];
      for (final sign in [-1, 1]) {
        var nx = x + d[0] * sign;
        var ny = y + d[1] * sign;
        while (nx >= 0 && nx < _size && ny >= 0 && ny < _size && _board[ny][nx] == stone) {
          line.add(_Pos(nx, ny));
          nx += d[0] * sign;
          ny += d[1] * sign;
        }
      }
      if (line.length >= 5) {
        line.sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
        return line;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5DEB3),
      appBar: AppBar(
        title: const Text('⚫ 오목'),
        backgroundColor: const Color(0xFF8B6914),
        foregroundColor: Colors.white,
        actions: [
          if (!_gameOver)
            TextButton(
              onPressed: _connected ? _surrender : null,
              child: const Text('기권', style: TextStyle(color: Colors.white70)),
            ),
          if (_gameOver)
            TextButton(
              onPressed: _connected ? _requestReset : null,
              child: const Text('다시', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildStatus(),
          Expanded(child: _buildBoard()),
        ],
      ),
    );
  }

  Widget _buildStatus() {
    String text;
    Color bg;
    if (!_connected) {
      text = '연결 중...';
      bg = Colors.grey.shade400;
    } else if (!_partnerConnected) {
      text = '상대방 기다리는 중...';
      bg = Colors.orange.shade300;
    } else if (_gameOver) {
      text = _winnerMsg ?? '';
      bg = _winnerMsg?.contains('내가') == true
          ? Colors.green.shade400
          : Colors.red.shade300;
    } else {
      text = _myTurn ? '내 차례 (${_isBlack ? "⚫" : "⚪"})' : '상대방 차례...';
      bg = _myTurn ? Colors.green.shade400 : Colors.grey.shade400;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      color: bg,
      child: Text(text,
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
    );
  }

  Widget _buildBoard() {
    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final boardSize = constraints.maxWidth;
              final cellSize = boardSize / (_size - 1);
              return GestureDetector(
                onTapDown: (details) {
                  final lp = details.localPosition;
                  final x = (lp.dx / cellSize).round();
                  final y = (lp.dy / cellSize).round();
                  if (x >= 0 && x < _size && y >= 0 && y < _size) {
                    _placePiece(x, y);
                  }
                },
                child: CustomPaint(
                  painter: _GomokuPainter(
                    board: _board,
                    size: _size,
                    winLine: _winLine,
                    isBlack: _isBlack,
                  ),
                  child: const SizedBox.expand(),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Pos {
  final int x, y;
  const _Pos(this.x, this.y);
}

class _GomokuPainter extends CustomPainter {
  final List<List<int>> board;
  final int size;
  final List<_Pos>? winLine;
  final bool isBlack;

  const _GomokuPainter({
    required this.board,
    required this.size,
    required this.winLine,
    required this.isBlack,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final cell = canvasSize.width / (size - 1);

    // 격자
    final linePaint = Paint()
      ..color = const Color(0xFF8B6914)
      ..strokeWidth = 1;
    for (int i = 0; i < size; i++) {
      canvas.drawLine(Offset(i * cell, 0), Offset(i * cell, canvasSize.height), linePaint);
      canvas.drawLine(Offset(0, i * cell), Offset(canvasSize.width, i * cell), linePaint);
    }

    // 화점 (점)
    final dotPaint = Paint()..color = const Color(0xFF8B6914);
    for (final p in [3, 7, 11]) {
      for (final q in [3, 7, 11]) {
        canvas.drawCircle(Offset(p * cell, q * cell), 4, dotPaint);
      }
    }

    // 돌
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final v = board[y][x];
        if (v == 0) continue;
        final center = Offset(x * cell, y * cell);
        final r = cell * 0.44;

        if (v == 1) {
          // 흑돌
          canvas.drawCircle(center, r,
              Paint()..shader = RadialGradient(colors: [Colors.grey.shade600, Colors.black]).createShader(
                Rect.fromCircle(center: center, radius: r)));
        } else {
          // 백돌
          canvas.drawCircle(center, r,
              Paint()..shader = RadialGradient(colors: [Colors.white, Colors.grey.shade300]).createShader(
                Rect.fromCircle(center: center, radius: r)));
          canvas.drawCircle(center, r, Paint()..color = Colors.grey.shade400..style = PaintingStyle.stroke..strokeWidth = 1);
        }
      }
    }

    // 승리 라인 하이라이트
    if (winLine != null) {
      final hlPaint = Paint()
        ..color = Colors.red.withValues(alpha: 0.5)
        ..strokeWidth = cell * 0.3
        ..strokeCap = StrokeCap.round;
      if (winLine!.length >= 2) {
        canvas.drawLine(
          Offset(winLine!.first.x * cell, winLine!.first.y * cell),
          Offset(winLine!.last.x * cell, winLine!.last.y * cell),
          hlPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GomokuPainter old) => true;
}
