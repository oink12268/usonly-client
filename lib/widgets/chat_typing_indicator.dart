import 'package:flutter/material.dart';

class ChatTypingIndicator extends StatelessWidget {
  final ValueNotifier<bool> typingNotifier;

  const ChatTypingIndicator({super.key, required this.typingNotifier});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: typingNotifier,
      builder: (context, isTyping, _) {
        if (!isTyping) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "입력 중...",
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        );
      },
    );
  }
}
