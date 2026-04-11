import 'package:flutter/material.dart';

class ChatSearchToolbar extends StatelessWidget {
  final VoidCallback onSearch;
  final VoidCallback onCalendar;
  final VoidCallback onAiSearch;
  final VoidCallback onMediaGallery;
  final VoidCallback onClose;

  const ChatSearchToolbar({
    super.key,
    required this.onSearch,
    required this.onCalendar,
    required this.onAiSearch,
    required this.onMediaGallery,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).colorScheme.outline.withOpacity(0.2)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _button(context, Icons.search, '검색', onSearch),
          _button(context, Icons.calendar_month, '날짜', onCalendar),
          _button(context, Icons.auto_awesome, 'AI 검색', onAiSearch),
          _button(context, Icons.photo_library_outlined, '사진 모음', onMediaGallery),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _button(BuildContext context, IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.onSurface, size: 24),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface)),
          ],
        ),
      ),
    );
  }
}
