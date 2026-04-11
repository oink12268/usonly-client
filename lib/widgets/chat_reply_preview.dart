import 'package:flutter/material.dart';

class ChatReplyPreview extends StatelessWidget {
  final Map<String, dynamic> replyTarget;
  final String myUid;
  final Map<String, String> nicknameCache;
  final VoidCallback onCancel;

  const ChatReplyPreview({
    super.key,
    required this.replyTarget,
    required this.myUid,
    required this.nicknameCache,
    required this.onCancel,
  });

  String _replyPreviewText(String message) {
    if (message.startsWith('IMAGE:')) return '사진';
    if (message.startsWith('FILE:')) return '파일';
    if (message.length > 30) return '${message.substring(0, 30)}...';
    return message;
  }

  @override
  Widget build(BuildContext context) {
    final writerUid = replyTarget['writerUid']?.toString() ?? '';
    final isMe = writerUid == myUid;
    final senderLabel = isMe
        ? "나에게 답장"
        : "${nicknameCache[writerUid] ?? writerUid.substring(0, 4)}에게 답장";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Container(
            width: 3,
            height: 36,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  senderLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Text(
                  _replyPreviewText(replyTarget['message'] as String? ?? ''),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onCancel,
            child: Icon(Icons.close, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
