import 'package:flutter/material.dart';

class ChatInputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(String) onTypingChanged;
  final VoidCallback onSend;
  final VoidCallback onAttachment;
  final Animation<double> sendScaleAnim;
  final AnimationController sendAnimController;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onTypingChanged,
    required this.onSend,
    required this.onAttachment,
    required this.sendScaleAnim,
    required this.sendAnimController,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.add, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 22),
            onPressed: onAttachment,
            padding: const EdgeInsets.all(2),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                hintText: "",
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                isDense: true,
              ),
              onChanged: onTypingChanged,
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          ScaleTransition(
            scale: sendScaleAnim,
            child: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              radius: 20,
              child: IconButton(
                icon: Icon(Icons.send, color: Theme.of(context).colorScheme.onPrimary, size: 18),
                onPressed: () {
                  sendAnimController.forward(from: 0.0);
                  onSend();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
