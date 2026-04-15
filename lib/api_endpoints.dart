import 'api_config.dart';

/// 모든 API 엔드포인트를 한 곳에서 관리합니다.
/// URL 변경이 필요하면 이 파일만 수정하면 됩니다.
class ApiEndpoints {
  static String get _base => ApiConfig.baseUrl;

  // ── WebSocket ─────────────────────────────────────────
  static String get wsUrl => ApiConfig.wsUrl;

  // ── Auth ──────────────────────────────────────────────
  static String get login => '$_base/api/auth/login';

  // ── Member ────────────────────────────────────────────
  static String get me => '$_base/api/members/me';
  static String get profileImage => '$_base/api/members/profile-image';
  static String get nickname => '$_base/api/members/nickname';
  static String get fcmToken => '$_base/api/members/fcm-token';
  static String memberInfo(String providerId) =>
      '$_base/api/members/info?providerId=$providerId';

  // ── Couple ────────────────────────────────────────────
  static String get coupleConnect => '$_base/api/couples/connect';

  // ── Chat ──────────────────────────────────────────────
  static String get chats => '$_base/api/chats';
  static String chatsBefore(int beforeId, {int size = 50}) =>
      '$_base/api/chats?before=$beforeId&size=$size';
  static String chatsAfter(int afterId, {int size = 50}) =>
      '$_base/api/chats?after=$afterId&size=$size';
  static String chatsSize({int size = 50}) =>
      '$_base/api/chats?size=$size';
  static String get chatsByDate => '$_base/api/chats/by-date';
  static String chatsByDateQuery(String date) =>
      '$_base/api/chats/by-date?date=$date';
  static String get chatSearch => '$_base/api/chats/search';
  static String chatSearchQuery(String q) =>
      '$_base/api/chats/search?q=${Uri.encodeComponent(q)}';
  static String get chatCalendar => '$_base/api/chats/calendar';
  static String chatImages({int page = 0, int size = 30}) =>
      '$_base/api/chats/images?page=$page&size=$size';
  static String chatDelete(int id) => '$_base/api/chats/$id';
  static String get chatImageUpload => '$_base/api/chat/image';
  static String get chatFileUpload => '$_base/api/chat/file';
  static String get aiSearch => '$_base/api/chat/ai-search';
  static String aiSearchQuery(String q) =>
      '$_base/api/chat/ai-search?q=${Uri.encodeComponent(q)}';

  // ── Schedule ──────────────────────────────────────────
  static String schedules(int year, int month) =>
      '$_base/api/schedules?year=$year&month=$month';
  static String scheduleById(int id) => '$_base/api/schedules/$id';
  static String get schedulesBase => '$_base/api/schedules';

  // ── Anniversary ───────────────────────────────────────
  static String get anniversaries => '$_base/api/anniversaries';
  static String anniversaryById(int id) => '$_base/api/anniversaries/$id';

  // ── Archive ───────────────────────────────────────────
  static String get archiveCreate => '$_base/api/archives/create';
  static String archiveCreateWithTitle(String title) =>
      '$_base/api/archives/create?title=${Uri.encodeComponent(title)}';
  static String get archiveUpload => '$_base/api/archives/upload';
  static String get archiveMedia => '$_base/api/archives/media';
  static String archiveMediaPaged({int page = 0, int size = 30}) =>
      '$_base/api/archives/media?page=$page&size=$size';
  static String get archiveAlbums => '$_base/api/archives/albums';
  static String archiveAlbumsPaged({int page = 0, int size = 12}) =>
      '$_base/api/archives/albums?page=$page&size=$size';
  static String archiveAlbumById(int albumId) => '$_base/api/archives/$albumId';
  static String archiveAlbumCover(int albumId) =>
      '$_base/api/archives/$albumId/cover';
  static String get archiveReorder => '$_base/api/archives/reorder';
  static String archiveMediaDelete(int mediaId) =>
      '$_base/api/archives/media/$mediaId';
  static String archiveMediaTakenAt(int mediaId) =>
      '$_base/api/archives/media/$mediaId/taken-at';

  // ── Note ──────────────────────────────────────────────
  static String get notes => '$_base/api/notes';
  static String notesWithParent(int parentId) =>
      '$_base/api/notes?parentId=$parentId';
  static String noteById(int id) => '$_base/api/notes/$id';
  static String noteMove(int id) => '$_base/api/notes/$id/move';
  static String get noteReorder => '$_base/api/notes/reorder';
  static String get noteImage => '$_base/api/notes/image';
  static String get noteExtractSchedule => '$_base/api/notes/extract-schedule';

  // ── Work Schedule ─────────────────────────────────────
  static String get workScheduleAnalyze => '$_base/api/work-schedule/analyze';
}
