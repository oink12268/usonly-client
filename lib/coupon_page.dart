import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'api_client.dart';
import 'api_endpoints.dart';

class CouponPage extends StatefulWidget {
  const CouponPage({super.key});

  @override
  State<CouponPage> createState() => _CouponPageState();
}

class _CouponPageState extends State<CouponPage> {
  List<Map<String, dynamic>> _active = [];
  List<Map<String, dynamic>> _expired = [];
  bool _loading = true;
  bool _showExpired = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiClient.get(Uri.parse(ApiEndpoints.coupons));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final raw = ApiClient.decodeBody(res);
        final list = (raw as List).cast<Map<String, dynamic>>();
        setState(() {
          _active = list.where((c) => c['expired'] == false).toList();
          _expired = list.where((c) => c['expired'] == true).toList();
        });
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteCoupon(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('쿠폰 삭제'),
        content: const Text('이 쿠폰을 삭제할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('삭제', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ApiClient.delete(Uri.parse(ApiEndpoints.couponById(id)));
    _load();
  }

  Future<void> _editCoupon(Map<String, dynamic> coupon) async {
    final storeCtrl = TextEditingController(text: coupon['storeName'] ?? '');
    final discountCtrl = TextEditingController(text: coupon['discount'] ?? '');
    DateTime? expiryDate = coupon['expiryDate'] != null
        ? DateTime.tryParse(coupon['expiryDate'])
        : null;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('쿠폰 정보 수정'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: storeCtrl,
                decoration: const InputDecoration(labelText: '브랜드/가게명'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: discountCtrl,
                decoration: const InputDecoration(labelText: '할인 내용'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('만료일: ', style: TextStyle(fontSize: 14)),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: expiryDate ?? DateTime.now(),
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                      );
                      if (picked != null) setModalState(() => expiryDate = picked);
                    },
                    child: Text(
                      expiryDate != null
                          ? '${expiryDate!.year}.${expiryDate!.month.toString().padLeft(2, '0')}.${expiryDate!.day.toString().padLeft(2, '0')}'
                          : '날짜 선택',
                    ),
                  ),
                  if (expiryDate != null)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setModalState(() => expiryDate = null),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('저장')),
          ],
        ),
      ),
    );

    if (result != true || !mounted) return;

    await ApiClient.put(
      Uri.parse(ApiEndpoints.couponById((coupon['id'] as num).toInt())),
      body: jsonEncode({
        'storeName': storeCtrl.text.trim().isEmpty ? null : storeCtrl.text.trim(),
        'discount': discountCtrl.text.trim().isEmpty ? null : discountCtrl.text.trim(),
        'expiryDate': expiryDate?.toIso8601String().split('T')[0],
      }),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('쿠폰함')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _active.isEmpty && _expired.isEmpty
                  ? _buildEmpty()
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        if (_active.isNotEmpty) ...[
                          _sectionHeader('사용 가능 (${_active.length})', Icons.confirmation_num_outlined),
                          ..._active.map((c) => _CouponCard(
                                coupon: c,
                                onEdit: () => _editCoupon(c),
                                onDelete: () => _deleteCoupon((c['id'] as num).toInt()),
                              )),
                        ],
                        if (_expired.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: () => setState(() => _showExpired = !_showExpired),
                            child: _sectionHeader(
                              '만료됨 (${_expired.length})',
                              Icons.history,
                              trailing: Icon(
                                _showExpired ? Icons.expand_less : Icons.expand_more,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (_showExpired)
                            ..._expired.map((c) => _CouponCard(
                                  coupon: c,
                                  isExpired: true,
                                  onEdit: () => _editCoupon(c),
                                  onDelete: () => _deleteCoupon((c['id'] as num).toInt()),
                                )),
                        ],
                      ],
                    ),
            ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.confirmation_num_outlined, size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.4)),
          const SizedBox(height: 16),
          Text(
            '쿠폰이 없어요',
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '채팅에서 쿠폰 사진을 보내면\n자동으로 여기에 저장돼요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          if (trailing != null) ...[const Spacer(), trailing],
        ],
      ),
    );
  }
}

class _CouponCard extends StatelessWidget {
  final Map<String, dynamic> coupon;
  final bool isExpired;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CouponCard({
    required this.coupon,
    this.isExpired = false,
    required this.onEdit,
    required this.onDelete,
  });

  String _formatDate(String? raw) {
    if (raw == null) return '';
    try {
      final d = DateTime.parse(raw);
      return '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return raw;
    }
  }

  int _daysLeft(String? raw) {
    if (raw == null) return 9999;
    try {
      final d = DateTime.parse(raw);
      return d.difference(DateTime.now()).inDays;
    } catch (_) {
      return 9999;
    }
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = coupon['imageUrl'] as String?;
    final storeName = coupon['storeName'] as String?;
    final discount = coupon['discount'] as String?;
    final expiryDate = coupon['expiryDate'] as String?;
    final daysLeft = _daysLeft(expiryDate);

    Color? expiryColor;
    if (!isExpired && expiryDate != null) {
      if (daysLeft <= 1) {
        expiryColor = Theme.of(context).colorScheme.error;
      } else if (daysLeft <= 7) {
        expiryColor = Colors.orange;
      }
    }

    return Opacity(
      opacity: isExpired ? 0.5 : 1.0,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: imageUrl != null ? () => _openImage(context, imageUrl) : null,
          onLongPress: () => _showOptions(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 썸네일
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: imageUrl != null
                      ? CachedNetworkImage(
                          imageUrl: imageUrl,
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          memCacheWidth: 144,
                          errorWidget: (_, __, ___) => _placeholderIcon(context),
                        )
                      : _placeholderIcon(context),
                ),
                const SizedBox(width: 12),
                // 정보
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (storeName != null)
                        Text(
                          storeName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (discount != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            discount,
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (storeName == null && discount == null)
                        Text(
                          '쿠폰',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      const SizedBox(height: 8),
                      if (expiryDate != null)
                        Row(
                          children: [
                            Icon(Icons.schedule, size: 13,
                                color: expiryColor ?? Theme.of(context).colorScheme.onSurfaceVariant),
                            const SizedBox(width: 3),
                            Text(
                              isExpired
                                  ? '만료: ${_formatDate(expiryDate)}'
                                  : daysLeft == 0
                                      ? '오늘 만료!'
                                      : daysLeft < 0
                                          ? '만료됨'
                                          : 'D-$daysLeft  (${_formatDate(expiryDate)})',
                              style: TextStyle(
                                fontSize: 12,
                                color: expiryColor ?? Theme.of(context).colorScheme.onSurfaceVariant,
                                fontWeight: expiryColor != null ? FontWeight.w600 : null,
                              ),
                            ),
                          ],
                        )
                      else
                        Text(
                          '만료일 없음',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.more_vert,
                    color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholderIcon(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.confirmation_num_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  void _openImage(BuildContext context, String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            SizedBox.expand(
              child: InteractiveViewer(
                child: Center(child: CachedNetworkImage(imageUrl: url)),
              ),
            ),
            Positioned(
              top: 40, right: 16,
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

  void _showOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('수정'),
              onTap: () {
                Navigator.pop(context);
                onEdit();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text('삭제',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}
