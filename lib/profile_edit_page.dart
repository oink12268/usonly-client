import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'api_config.dart';
import 'api_client.dart';

class ProfileEditPage extends StatefulWidget {
  final int memberId;
  final String? initialNickname;
  final String? initialProfileImageUrl;

  const ProfileEditPage({
    super.key,
    required this.memberId,
    this.initialNickname,
    this.initialProfileImageUrl,
  });

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  late TextEditingController _nicknameController;
  XFile? _pickedImage;
  Uint8List? _pickedImageBytes;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController(text: widget.initialNickname ?? '');
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 800,
    );
    if (picked != null) {
      final bytes = await picked.readAsBytes();
      setState(() {
        _pickedImage = picked;
        _pickedImageBytes = bytes;
      });
    }
  }

  Future<void> _save() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이름을 입력해주세요')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      // 닉네임 변경
      if (nickname != widget.initialNickname) {
        await ApiClient.put(
          Uri.parse('${ApiConfig.baseUrl}/api/members/nickname?nickname=${Uri.encodeComponent(nickname)}'),
        );
      }

      // 프로필 이미지 변경
      if (_pickedImage != null && _pickedImageBytes != null) {
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('${ApiConfig.baseUrl}/api/members/profile-image'),
        );
        request.files.add(http.MultipartFile.fromBytes(
          'file',
          _pickedImageBytes!,
          filename: _pickedImage!.name,
        ));
        await ApiClient.sendMultipart(request);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('프로필이 저장되었습니다')),
        );
        Navigator.pop(context, true); // true = 변경됨
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('프로필 수정'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B7E74)),
                    )
                  : const Text(
                      '저장',
                      style: TextStyle(
                        color: Color(0xFF8B7E74),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            // 프로필 이미지 선택
            GestureDetector(
              onTap: _pickImage,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _buildProfileImage(),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF8B7E74),
                      ),
                      child: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 36),
            // 닉네임 입력
            TextField(
              controller: _nicknameController,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: '이름',
                labelStyle: TextStyle(color: Color(0xFF8B7E74)),
                border: OutlineInputBorder(),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF8B7E74)),
                ),
                counterStyle: TextStyle(color: Colors.grey),
              ),
              cursorColor: const Color(0xFF8B7E74),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileImage() {
    if (_pickedImageBytes != null) {
      return CircleAvatar(
        radius: 60,
        backgroundImage: MemoryImage(_pickedImageBytes!),
      );
    }
    if (widget.initialProfileImageUrl != null) {
      return CircleAvatar(
        radius: 60,
        backgroundImage: CachedNetworkImageProvider(widget.initialProfileImageUrl!),
      );
    }
    return CircleAvatar(
      radius: 60,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.person, size: 60, color: Colors.grey),
    );
  }
}
