import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:any_link_preview/any_link_preview.dart';
import '../utils/date_formatter.dart';
import '../chat_search_page.dart';
import '../pdf_viewer_page.dart';

class ChatBubble extends StatelessWidget {
  final Map<String, dynamic> chat;
  final String myUid;
  final bool showDateDivider;
  final bool isHighlighted;
  final Key? targetKey;
  final Map<String, String> nicknameCache;
  final Map<String, String?> profileImageCache;
  final List<dynamic> allChats; // fallback for image gallery
  final void Function(dynamic chat) onReply;
  final void Function(dynamic chat) onLongPress;
  final void Function(int id) onScrollToReply;
  final VoidCallback? onRetry;
  final Set<String> couponImageUrls;

  const ChatBubble({
    super.key,
    required this.chat,
    required this.myUid,
    required this.showDateDivider,
    required this.isHighlighted,
    this.targetKey,
    required this.nicknameCache,
    required this.profileImageCache,
    required this.allChats,
    required this.onReply,
    required this.onLongPress,
    required this.onScrollToReply,
    this.onRetry,
    this.couponImageUrls = const {},
  });

  String _replyPreviewText(String message) {
    if (message.startsWith('IMAGE:')) return '사진';
    if (message.startsWith('FILE:')) return '파일';
    if (message.length > 30) return '${message.substring(0, 30)}...';
    return message;
  }

  String? _extractFirstUrl(String text) {
    final urlRegex = RegExp(r'(https?://[^\s]+)', caseSensitive: false);
    return urlRegex.firstMatch(text)?.group(0);
  }

  Widget _buildLinkPreview(BuildContext context, String url, bool isMe) {
    return GestureDetector(
      onTap: () async {
        final uri = Uri.tryParse(url);
        if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        constraints: const BoxConstraints(maxWidth: 280),
        child: AnyLinkPreview(
          link: url,
          displayDirection: UIDirection.uiDirectionVertical,
          showMultimedia: true,
          bodyMaxLines: 2,
          bodyTextOverflow: TextOverflow.ellipsis,
          titleStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          bodyStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
          errorWidget: const SizedBox.shrink(),
          placeholderWidget: Container(
            height: 60,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          backgroundColor: isMe
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: 8,
          removeElevation: true,
        ),
      ),
    );
  }

  Color _myBubbleColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? const Color(0xFF424242) : const Color(0xFF3A3A3A);
  }

  Color _partnerBubbleColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? const Color(0xFF303030) : const Color(0xFFE8E8E8);
  }

  Color _myTextColor(BuildContext context) => const Color(0xFFEEEEEE);

  Color _partnerTextColor(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;

  Widget _buildMessageContent(BuildContext context, String text, bool isMe) {
    final urlRegex = RegExp(r'(https?://[^\s]+)', caseSensitive: false);
    final matches = urlRegex.allMatches(text);
    if (matches.isEmpty) {
      return Text(
        text,
        style: TextStyle(
          fontSize: 16,
          color: isMe ? _myTextColor(context) : _partnerTextColor(context),
        ),
      );
    }

    final spans = <InlineSpan>[];
    int last = 0;
    for (final m in matches) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: TextStyle(
          color: isMe ? _myTextColor(context) : _partnerTextColor(context),
          decoration: TextDecoration.underline,
          decorationColor: isMe ? _myTextColor(context) : _partnerTextColor(context),
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () async {
            final uri = Uri.tryParse(url);
            if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
          },
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }

    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: 16,
          color: isMe ? _myTextColor(context) : _partnerTextColor(context),
        ),
        children: spans,
      ),
    );
  }

  void _openImageGallery(BuildContext context, String content) {
    final imageUrls = _fallbackImageUrls();
    final initialIndex = imageUrls.indexOf(content).clamp(0, imageUrls.isEmpty ? 0 : imageUrls.length - 1);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenImageView(
          imageUrls: imageUrls.isEmpty ? [content] : imageUrls,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  List<String> _fallbackImageUrls() {
    return allChats
        .where((c) => (c['message'] as String? ?? '').startsWith('IMAGE:'))
        .map((c) => (c['message'] as String).replaceFirst('IMAGE:', ''))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final message = chat['message'] as String? ?? '';
    final String? createdAt = chat['created_at'] ?? chat['createdAt'];
    final isMe = chat['writerUid'] == myUid;
    final String? messageStatus = chat['_status'] as String?;
    final isPending = messageStatus == 'pending';
    final isFailed = messageStatus == 'failed';

    final isImage = message.startsWith('IMAGE:');
    final isFile = message.startsWith('FILE:');
    final String content = isImage
        ? message.replaceFirst('IMAGE:', '')
        : isFile
            ? message.replaceFirst('FILE:', '')
            : message;

    String fileUrl = '';
    String fileName = '';
    if (isFile) {
      final parts = content.split('|||');
      fileUrl = parts[0];
      fileName = parts.length > 1 ? parts[1] : '파일';
    }

    final hasReply = chat['replyToId'] != null;
    final String? replyToMessage = chat['replyToMessage'];
    final String? replyToUid = chat['replyToUid'];

    return KeyedSubtree(
      key: targetKey ?? ValueKey('chat_${chat['id']}'),
      child: Column(
        children: [
          // 날짜 구분선
          if (showDateDivider && createdAt != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    createdAt.split('T')[0],
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 12),
                  ),
                ),
              ),
            ),

          // 하이라이트 배지
          if (isHighlighted)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('검색된 메시지',
                  style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface)),
            ),

          // 말풍선 (스와이프로 답장)
          Dismissible(
            key: ValueKey('dismissible_${chat['id']}'),
            direction: (isPending || isFailed)
                ? DismissDirection.none
                : DismissDirection.startToEnd,
            confirmDismiss: (_) async {
              onReply(chat);
              return false;
            },
            background: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              child: Icon(Icons.reply, color: Theme.of(context).colorScheme.onSurface),
            ),
            child: GestureDetector(
              onLongPress: (isPending || isFailed) ? null : () => onLongPress(chat),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                child: Row(
                  mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 상대방 프로필 이미지
                    if (!isMe)
                      Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: GestureDetector(
                          onTap: () {
                            final imageUrl = profileImageCache[chat['writerUid']?.toString()];
                            if (imageUrl != null) {
                              showDialog(
                                context: context,
                                builder: (_) => Dialog(
                                  backgroundColor: Colors.black,
                                  insetPadding: EdgeInsets.zero,
                                  child: Stack(
                                    children: [
                                      SizedBox.expand(
                                        child: InteractiveViewer(
                                          child: Center(
                                            child: CachedNetworkImage(imageUrl: imageUrl),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        top: 40,
                                        right: 16,
                                        child: IconButton(
                                          icon: const Icon(Icons.close, color: Colors.white, size: 28),
                                          onPressed: () => Navigator.of(context).pop(),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }
                          },
                          child: CircleAvatar(
                            backgroundColor: Theme.of(context).colorScheme.surface,
                            backgroundImage:
                                profileImageCache[chat['writerUid']?.toString()] != null
                                    ? CachedNetworkImageProvider(
                                        profileImageCache[chat['writerUid']!.toString()]!,
                                      )
                                    : null,
                            child: profileImageCache[chat['writerUid']?.toString()] == null
                                ? Icon(Icons.person,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant)
                                : null,
                          ),
                        ),
                      ),

                    // 내 메시지: 시간 or 전송 상태 표시
                    if (isMe)
                      Padding(
                        padding: const EdgeInsets.only(right: 4, top: 4),
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: isPending
                              ? SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                )
                              : isFailed
                                  ? GestureDetector(
                                      onTap: onRetry,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.error_outline,
                                              size: 16, color: Colors.red[400]),
                                          Text(
                                            '재전송',
                                            style: TextStyle(
                                                fontSize: 9, color: Colors.red[400]),
                                          ),
                                        ],
                                      ),
                                    )
                                  : Text(
                                      DateFormatter.formatTime(createdAt),
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant),
                                    ),
                        ),
                      ),

                    // 말풍선 본체
                    Flexible(
                      child: Opacity(
                        opacity: isPending ? 0.55 : 1.0,
                        child: Column(
                        crossAxisAlignment:
                            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        children: [

                          // 답장 인용
                          if (hasReply && replyToMessage != null)
                            GestureDetector(
                              onTap: () {
                                final replyId = chat['replyToId'];
                                if (replyId != null) {
                                  onScrollToReply(int.tryParse(replyId.toString()) ?? 0);
                                }
                              },
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border(
                                    left: BorderSide(
                                        color: Theme.of(context).colorScheme.primary,
                                        width: 3),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      replyToUid != null && replyToUid == myUid
                                          ? "나"
                                          : nicknameCache[replyToUid] ??
                                              replyToUid?.substring(0, 4) ??
                                              "",
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _replyPreviewText(replyToMessage),
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ),

                          // 이미지
                          if (isImage)
                            GestureDetector(
                              onTap: () => _openImageGallery(context, content),
                              child: Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(15),
                                    child: CachedNetworkImage(
                                      imageUrl: content,
                                      width: 200,
                                      height: 200,
                                      fit: BoxFit.cover,
                                      memCacheWidth: 300,
                                      placeholder: (context, url) => Container(
                                          width: 200,
                                          height: 200,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest),
                                      errorWidget: (context, url, error) =>
                                          const Icon(Icons.error),
                                    ),
                                  ),
                                  if (couponImageUrls.contains(content))
                                    Positioned(
                                      bottom: 0,
                                      left: 0,
                                      right: 0,
                                      child: Container(
                                        decoration: const BoxDecoration(
                                          color: Color(0xCC1B5E20),
                                          borderRadius: BorderRadius.only(
                                            bottomLeft: Radius.circular(15),
                                            bottomRight: Radius.circular(15),
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(vertical: 5),
                                        child: const Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.confirmation_num_outlined,
                                                size: 13, color: Colors.white),
                                            SizedBox(width: 4),
                                            Text(
                                              '쿠폰 저장됨',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w600),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            )
                          // 파일
                          else if (isFile)
                            GestureDetector(
                              onTap: () {
                                final isPdf = fileName.toLowerCase().endsWith('.pdf');
                                if (isPdf) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => PdfViewerPage(
                                        url: fileUrl,
                                        fileName: fileName,
                                      ),
                                    ),
                                  );
                                } else {
                                  launchUrl(Uri.parse(fileUrl), mode: LaunchMode.externalApplication);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? _myBubbleColor(context)
                                      : _partnerBubbleColor(context),
                                  borderRadius: BorderRadius.circular(15),
                                  boxShadow: [
                                    BoxShadow(
                                        color: Colors.black.withOpacity(0.05),
                                        blurRadius: 1,
                                        offset: const Offset(1, 1))
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                        fileName.toLowerCase().endsWith('.pdf')
                                            ? Icons.picture_as_pdf
                                            : Icons.insert_drive_file,
                                        size: 28,
                                        color: isMe
                                            ? _myTextColor(context)
                                            : fileName.toLowerCase().endsWith('.pdf')
                                                ? Colors.red[400]
                                                : _partnerTextColor(context)),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        fileName,
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: isMe
                                                ? _myTextColor(context)
                                                : _partnerTextColor(context)),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Icon(
                                        fileName.toLowerCase().endsWith('.pdf')
                                            ? Icons.open_in_new
                                            : Icons.download,
                                        size: 18,
                                        color: isMe
                                            ? _myTextColor(context).withOpacity(0.7)
                                            : Theme.of(context).colorScheme.onSurfaceVariant),
                                  ],
                                ),
                              ),
                            )
                          // 텍스트
                          else
                            Column(
                              crossAxisAlignment:
                                  isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: isMe
                                        ? _myBubbleColor(context)
                                        : _partnerBubbleColor(context),
                                    borderRadius: BorderRadius.only(
                                      topLeft: const Radius.circular(15),
                                      topRight: const Radius.circular(15),
                                      bottomLeft: isMe
                                          ? const Radius.circular(15)
                                          : const Radius.circular(0),
                                      bottomRight: isMe
                                          ? const Radius.circular(0)
                                          : const Radius.circular(15),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                          color: Colors.black.withOpacity(0.05),
                                          blurRadius: 1,
                                          offset: const Offset(1, 1))
                                    ],
                                  ),
                                  child: _buildMessageContent(context, content, isMe),
                                ),
                                if (_extractFirstUrl(content) != null)
                                  _buildLinkPreview(context, _extractFirstUrl(content)!, isMe),
                              ],
                            ),
                        ],
                      ),
                      ), // Opacity
                    ),

                    // 상대 메시지: 시간 오른쪽
                    if (!isMe)
                      Padding(
                        padding: const EdgeInsets.only(left: 4, top: 4),
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: Text(
                            DateFormatter.formatTime(createdAt),
                            style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
