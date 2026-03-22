import 'package:flutter/material.dart';

/// 삭제 확인 다이얼로그 - 여러 화면에서 공통 사용
class ConfirmDeleteDialog {
  static Future<bool> show(
    BuildContext context, {
    String title = '삭제 확인',
    required String content,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('삭제', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ) ??
        false;
  }
}

/// 스와이프 삭제 배경 위젯 (endToStart 방향)
class DismissDeleteBackground extends StatelessWidget {
  final Color color;

  const DismissDeleteBackground({
    super.key,
    this.color = const Color(0xFF8B7E74),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onPrimary),
    );
  }
}
