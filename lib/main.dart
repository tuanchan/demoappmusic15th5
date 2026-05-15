// main.dart
// Gộp từ: logic.dart + app.dart + main.dart
// FIX: lưu nhạc portable bằng đường dẫn tương đối + tự quét thư mục Audio khi mở app.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:archive/archive.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// logic.dart


/// ===============================
/// DB schema (single file, no hardcode)
/// ===============================
class TrackRow {
  final String id;
  final String title;
  final String artist;
  final String localPath; // path in app Documents (copied)
  final String signature; // for dedupe
  final String? coverPath; // path in app Documents/Images
  final int durationMs; // cached duration
  final int createdAt;

  TrackRow({
    required this.id,
    required this.title,
    required this.artist,
    required this.localPath,
    required this.signature,
    required this.coverPath,
    required this.durationMs,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'artist': artist,
        'localPath': localPath,
        'signature': signature,
        'coverPath': coverPath,
        'durationMs': durationMs,
        'createdAt': createdAt,
      };

  static TrackRow fromMap(Map<String, Object?> m) => TrackRow(
        id: m['id'] as String,
        title: (m['title'] as String?) ?? '',
        artist: (m['artist'] as String?) ?? '',
        localPath: m['localPath'] as String,
        signature: m['signature'] as String,
        coverPath: m['coverPath'] as String?,
        durationMs: (m['durationMs'] as int?) ?? 0,
        createdAt: (m['createdAt'] as int?) ?? 0,
      );
}

class PlaylistRow {
  final String id;
  final String name;
  final int createdAt;
  final bool isSpecial;

  PlaylistRow({
    required this.id,
    required this.name,
    required this.createdAt,
    this.isSpecial = false,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'isSpecial': isSpecial ? 1 : 0
      };

  static PlaylistRow fromMap(Map<String, Object?> m) => PlaylistRow(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        createdAt: (m['createdAt'] as int?) ?? 0,
        isSpecial: ((m['isSpecial'] as int?) ?? 0) == 1,
      );
}

class FavoriteSegment {
  final String id;
  final String trackId;
  final String name;
  final int startMs;
  final int endMs;
  final int createdAt;

  FavoriteSegment({
    required this.id,
    required this.trackId,
    required this.name,
    required this.startMs,
    required this.endMs,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'trackId': trackId,
        'name': name,
        'startMs': startMs,
        'endMs': endMs,
        'createdAt': createdAt,
      };

  static FavoriteSegment fromMap(Map<String, Object?> m) => FavoriteSegment(
        id: m['id'] as String,
        trackId: m['trackId'] as String,
        name: (m['name'] as String?) ?? '',
        startMs: (m['startMs'] as int?) ?? 0,
        endMs: (m['endMs'] as int?) ?? 0,
        createdAt: (m['createdAt'] as int?) ?? 0,
      );
}

class PlaybackStateRow {
  final String? currentTrackId;
  final int positionMs;
  final bool isPlaying;
  final bool loopOne;
  final bool continuous;

  PlaybackStateRow({
    required this.currentTrackId,
    required this.positionMs,
    required this.isPlaying,
    required this.loopOne,
    required this.continuous,
  });

  Map<String, Object?> toMap() => {
        'k': 1,
        'currentTrackId': currentTrackId,
        'positionMs': positionMs,
        'isPlaying': isPlaying ? 1 : 0,
        'loopOne': loopOne ? 1 : 0,
        'continuous': continuous ? 1 : 0,
      };

  static PlaybackStateRow fromMap(Map<String, Object?> m) => PlaybackStateRow(
        currentTrackId: m['currentTrackId'] as String?,
        positionMs: (m['positionMs'] as int?) ?? 0,
        isPlaying: ((m['isPlaying'] as int?) ?? 0) == 1,
        loopOne: ((m['loopOne'] as int?) ?? 0) == 1,
        continuous: ((m['continuous'] as int?) ?? 1) == 1,
      );
}

/// ===============================
/// Theme Config (A→Z palette) + persistence
/// - Mục tiêu: "quét không chừa 1 cái nào" => gom toàn bộ màu/typography tokens
/// - App.dart sẽ đọc themeConfig để build ThemeData (file app.dart anh bảo OK mới in)
/// ===============================
class ThemeConfig {
  /// Keys chuẩn hoá để app.dart build ThemeData.
  /// Anh có thể thêm key mới mà không phá backward-compat.
  static const keys = <String>[
    // Core
    'primary',
    'secondary',
    'background',
    'surface',
    'card',
    'divider',
    'shadow',

    // Text
    'textPrimary',
    'textSecondary',
    'textTertiary',
    'textOnPrimary',

    // AppBar
    'appBarBg',
    'appBarFg',

    // BottomNav
    'bottomNavBg',
    'bottomNavSelected',
    'bottomNavUnselected',

    // Buttons
    'buttonBg',
    'buttonFg',
    'buttonTonalBg',
    'buttonTonalFg',

    // Inputs
    'inputFill',
    'inputBorder',
    'inputHint',

    // Icons
    'iconPrimary',
    'iconSecondary',

    // Slider
    'sliderActive',
    'sliderInactive',
    'sliderThumb',
    'sliderOverlay',

    // Dialog / Sheet
    'dialogBg',
    'sheetBg',

    // SnackBar
    'snackBg',
    'snackFg',

    // ListTile highlight/selection
    'selectedRowBg',
    'selectedRowFg',

    // Visualizer bars
    'visualizerBar',
  ];

  /// Typography knobs (mà anh nói “font chữ header...”).
  /// Không đổi UI layout, chỉ đổi font family/weight/size tokens từ ThemeData.
  final String? fontFamily;
  final double? headerScale; // 1.0 default
  final double? bodyScale; // 1.0 default

  /// Palette lưu dưới dạng ARGB int.
  final Map<String, int> colors;

  const ThemeConfig({
    required this.colors,
    this.fontFamily,
    this.headerScale,
    this.bodyScale,
  });

  ThemeConfig copyWith({
    Map<String, int>? colors,
    String? fontFamily,
    double? headerScale,
    double? bodyScale,
  }) {
    return ThemeConfig(
      colors: colors ?? this.colors,
      fontFamily: fontFamily ?? this.fontFamily,
      headerScale: headerScale ?? this.headerScale,
      bodyScale: bodyScale ?? this.bodyScale,
    );
  }

  Color getColor(String key, Color fallback) {
    final v = colors[key];
    if (v == null) return fallback;
    return Color(v);
  }

  ThemeConfig setColor(String key, Color color) {
    final next = Map<String, int>.from(colors);
    next[key] = color.value;
    return copyWith(colors: next);
  }

  ThemeConfig resetToDefaults({required bool darkDefault}) {
    return ThemeConfig.defaults(darkDefault: darkDefault);
  }

  Map<String, Object?> toMap() => {
        'colors': colors,
        'fontFamily': fontFamily,
        'headerScale': headerScale,
        'bodyScale': bodyScale,
      };

  static ThemeConfig fromMap(Map<String, Object?> m) {
    final rawColors = (m['colors'] as Map?) ?? const {};
    final parsed = <String, int>{};
    for (final e in rawColors.entries) {
      final k = e.key.toString();
      final v = e.value;
      if (v is int) parsed[k] = v;
      if (v is num) parsed[k] = v.toInt();
      if (v is String) {
        // allow hex strings accidentally stored
        final s = v.trim();
        final maybe = int.tryParse(
          s.startsWith('0x') ? s.substring(2) : s,
          radix: 16,
        );
        if (maybe != null) parsed[k] = maybe;
      }
    }
    return ThemeConfig(
      colors: parsed,
      fontFamily: (m['fontFamily'] as String?)?.trim().isEmpty == true
          ? null
          : (m['fontFamily'] as String?),
      headerScale: (m['headerScale'] as num?)?.toDouble(),
      bodyScale: (m['bodyScale'] as num?)?.toDouble(),
    );
  }

  static ThemeConfig defaults({required bool darkDefault}) {
    // Base giống app.dart hiện tại: cam #FF4A00 + nền đen.
    const orange = 0xFFFF4A00;
    const black = 0xFF000000;
    const white = 0xFFFFFFFF;

    // Một số neutral gần giống anh đang dùng.
    const cardDark = 0xFF1A1A1A;
    const cardLight = 0xFFF6F6F6;
    const dividerDark = 0x33FFFFFF;
    const dividerLight = 0x1F000000;

    final colors = <String, int>{
      'primary': orange,
      'secondary': orange,
      'background': darkDefault ? black : white,
      'surface': darkDefault ? black : white,
      'card': darkDefault ? cardDark : cardLight,
      'divider': darkDefault ? dividerDark : dividerLight,
      'shadow': 0x73000000,
      'textPrimary': darkDefault ? 0xFFFFFFFF : 0xFF000000,
      'textSecondary': darkDefault ? 0xB3FFFFFF : 0x99000000,
      'textTertiary': darkDefault ? 0x80FFFFFF : 0x66000000,
      'textOnPrimary': 0xFFFFFFFF,
      'appBarBg': darkDefault ? black : white,
      'appBarFg': darkDefault ? 0xFFFFFFFF : 0xFF000000,
      'bottomNavBg': darkDefault ? black : white,
      'bottomNavSelected': orange,
      'bottomNavUnselected': darkDefault ? 0xB3FFFFFF : 0x8A000000,
      'buttonBg': orange,
      'buttonFg': 0xFFFFFFFF,
      'buttonTonalBg': darkDefault ? 0x1FFFF4A00 : 0x1AFF4A00,
      'buttonTonalFg': orange,
      'inputFill': darkDefault ? cardDark : cardLight,
      'inputBorder': darkDefault ? 0x33FFFFFF : 0x22000000,
      'inputHint': darkDefault ? 0x80FFFFFF : 0x66000000,
      'iconPrimary': darkDefault ? 0xFFFFFFFF : 0xFF000000,
      'iconSecondary': darkDefault ? 0xB3FFFFFF : 0x8A000000,
      'sliderActive': orange,
      'sliderInactive': darkDefault ? 0x3DFFFFFF : 0x42000000,
      'sliderThumb': orange,
      'sliderOverlay': 0x1FFF4A00,
      'dialogBg': darkDefault ? cardDark : white,
      'sheetBg': darkDefault ? cardDark : white,
      'snackBg': darkDefault ? 0xFF202020 : 0xFF202020,
      'snackFg': 0xFFFFFFFF,
      'selectedRowBg': darkDefault ? 0x1AFF4A00 : 0x14FF4A00,
      'selectedRowFg': darkDefault ? 0xFFFFFFFF : 0xFF000000,
      'visualizerBar': darkDefault ? 0xFF9E9E9E : 0xFF616161,
    };

    // Ensure all keys exist (future-proof)
    for (final k in keys) {
      colors.putIfAbsent(k, () => orange);
    }

    return ThemeConfig(
        colors: colors, fontFamily: null, headerScale: 1.0, bodyScale: 1.0);
  }
}

/// ===============================
/// Settings
/// ===============================
class AppSettings {
  final ThemeMode themeMode;
  final String appTitle;

  /// Theme token map (A→Z), persisted.
  final ThemeConfig themeConfig;

  const AppSettings({
    required this.themeMode,
    required this.appTitle,
    required this.themeConfig,
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? appTitle,
    ThemeConfig? themeConfig,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        appTitle: appTitle ?? this.appTitle,
        themeConfig: themeConfig ?? this.themeConfig,
      );
}

/// ===============================
/// AudioHandler (just_audio + audio_service)
/// ===============================
class PlayerHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final void Function(Duration position) onPosition;
  final void Function(PlaybackEvent e)? onEvent;

  PlayerHandler({required this.onPosition, this.onEvent}) {
    _wire();
  }

  AudioPlayer get player => _player;

  void _wire() {
    // Position stream
    _player.positionStream.listen((pos) {
      onPosition(pos);
    });

    _player.playbackEventStream.listen((event) {
      onEvent?.call(event);
      playbackState.add(_transformEvent(event));
    });

    // Auto set mediaItem when current index changes
    _player.currentIndexStream.listen((i) async {
      if (i == null) return;
      final q = queue.value;
      if (i >= 0 && i < q.length) {
        mediaItem.add(q[i]);
      }
    });
  }

  PlaybackState _transformEvent(PlaybackEvent e) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        _player.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.currentIndex,
    );
  }

  Future<void> setQueueFromTracks(
    List<MediaItem> items, {
    int startIndex = 0,
    Duration? startPos,
  }) async {
    final playableItems = items.where((mi) {
      final path = mi.extras?['path'];
      return path is String && path.isNotEmpty && File(path).existsSync();
    }).toList();

    if (playableItems.isEmpty) {
      queue.add(const <MediaItem>[]);
      await _player.stop();
      return;
    }

    final selectedId =
        (startIndex >= 0 && startIndex < items.length) ? items[startIndex].id : null;

    var fixedStartIndex = selectedId == null
        ? 0
        : playableItems.indexWhere((mi) => mi.id == selectedId);
    if (fixedStartIndex < 0) fixedStartIndex = 0;

    queue.add(playableItems);

    final sources = playableItems.map((mi) {
      final uri = Uri.file(mi.extras?['path'] as String);
      return AudioSource.uri(uri, tag: mi);
    }).toList();

    try {
      await _player.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: fixedStartIndex,
      );

      if (startPos != null) {
        await _player.seek(startPos);
      }
    } catch (_) {
      queue.add(const <MediaItem>[]);
      await _player.stop();
    }
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> skipToNext() => _player.seekToNext();
  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  Future<void> setLoopOne(bool on) async {
    await _player.setLoopMode(on ? LoopMode.one : LoopMode.off);
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> dispose() async {
    await _player.dispose();
    await super.stop();
  }
}

/// ===============================
/// AppLogic (single file state)
/// ===============================
class AppLogic extends ChangeNotifier {
  static const _kPrefTheme = 'settings.themeMode';
  static const _kPrefTitle = 'settings.appTitle';
  bool isConvertingVideo = false;
  double convertProgress = 0.0; // 0..1
  String convertLabel = '';

  // NEW: theme config storage
  static const _kPrefThemeConfig = 'settings.themeConfig.v1';

  late SharedPreferences _prefs;
  Database? _db;

  // Storage folders
  late Directory _rootDir;
  late Directory audioDir;
  late Directory imageDir;

  AppSettings settings = AppSettings(
    themeMode: ThemeMode.dark,
    appTitle: 'Local Player',
    themeConfig: ThemeConfig.defaults(darkDefault: true),
  );

  // Data in memory
  final List<TrackRow> library = [];
  final Set<String> favorites = {};
  final List<PlaylistRow> playlists = [];
  final Map<String, List<String>> playlistItems = {}; // playlistId -> trackIds
  final List<FavoriteSegment> favoriteSegments = [];
  StreamSubscription<MediaItem?>? _mediaItemSub;

  // Player
  late final PlayerHandler handler;
  bool _handlerReady = false;
  Duration position = Duration.zero;

  bool loopOne = false;
  bool continuousPlay = true;

  TrackRow? _current;
  TrackRow? get currentTrack => _current;

  Duration get currentDuration =>
      Duration(milliseconds: _current?.durationMs ?? 0);

  // throttle save playback
  Timer? _saveTimer;

  Future<void> seekRelative(Duration delta) async {
    final cur = position; // Duration hiện tại
    final dur = currentDuration; // Duration tổng

    var next = cur + delta;

    if (next < Duration.zero) next = Duration.zero;
    if (next > dur) next = dur;

    await seek(next);
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _loadSettings();

    await _initFolders();
    await _initDb();

    // Audio phải được khởi tạo trước khi scan/restore gọi setCurrent().
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    handler = await AudioService.init(
      builder: () => PlayerHandler(
        onPosition: (pos) {
          position = pos;
          _scheduleSavePlayback();
          notifyListeners();
        },
        onEvent: (_) {
          _scheduleSavePlayback();
        },
      ),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.tuanchan.localplayer.audio',
        androidNotificationChannelName: 'Local Player',
        androidNotificationOngoing: true,
      ),
    );
    _handlerReady = true;

    // Sync UI currentTrack theo MediaItem thật của player
    _mediaItemSub = handler.mediaItem.listen((mi) {
      if (mi == null) return;
      final id = mi.id;

      final i = library.indexWhere((t) => t.id == id);
      if (i >= 0) {
        _current = library[i];
        notifyListeners();
      }
    });

    await _normalizeDbPathsAndScanAudioFolder();
    await _loadAllFromDb();

    // Restore without autoplay
    await _restorePlaybackStateWithoutAutoPlay();
  }

  void _loadSettings() {
    final themeStr = _prefs.getString(_kPrefTheme) ?? 'dark';
    final titleStr = _prefs.getString(_kPrefTitle) ?? 'Local Player';

    ThemeMode mode = switch (themeStr) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };

    // Theme config decode
    ThemeConfig cfg;
    final rawCfg = _prefs.getString(_kPrefThemeConfig);
    if (rawCfg == null || rawCfg.trim().isEmpty) {
      cfg = ThemeConfig.defaults(darkDefault: mode != ThemeMode.light);
    } else {
      try {
        final m = jsonDecode(rawCfg) as Map<String, Object?>;
        cfg = ThemeConfig.fromMap(m);

        // If cfg is missing keys, patch with defaults
        final patched = Map<String, int>.from(
          ThemeConfig.defaults(darkDefault: mode != ThemeMode.light).colors,
        );
        patched.addAll(cfg.colors);
        cfg = cfg.copyWith(colors: patched);

        // Ensure scalars not null
        cfg = cfg.copyWith(
          headerScale: cfg.headerScale ?? 1.0,
          bodyScale: cfg.bodyScale ?? 1.0,
        );
      } catch (_) {
        cfg = ThemeConfig.defaults(darkDefault: mode != ThemeMode.light);
      }
    }

    settings = AppSettings(
      themeMode: mode,
      appTitle: titleStr,
      themeConfig: cfg,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    settings = settings.copyWith(themeMode: mode);

    await _prefs.setString(
      _kPrefTheme,
      switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
        _ => 'dark'
      },
    );

    // 🔥 FIX: nếu user chưa custom theme (palette = default của mode cũ)
    // thì rebase lại defaults theo mode mới để background/surface đổi đúng.
    final oldIsDark = settings.themeMode == ThemeMode.dark ||
        settings.themeMode == ThemeMode.system;

    final newIsDark = mode == ThemeMode.dark || mode == ThemeMode.system;

    final currentCfg = settings.themeConfig;
    final defaultOld = ThemeConfig.defaults(darkDefault: oldIsDark);

    bool isStillDefault = true;
    for (final k in ThemeConfig.keys) {
      if (currentCfg.colors[k] != defaultOld.colors[k]) {
        isStillDefault = false;
        break;
      }
    }

    if (isStillDefault) {
      settings = settings.copyWith(
        themeConfig: ThemeConfig.defaults(darkDefault: newIsDark),
      );
      await _persistThemeConfig();
    }

    notifyListeners();
  }

  Future<void> setAppTitle(String title) async {
    final t = title.trim().isEmpty ? 'Local Player' : title.trim();
    settings = settings.copyWith(appTitle: t);
    await _prefs.setString(_kPrefTitle, settings.appTitle);
    notifyListeners();
  }

  /// ===============================
  /// NEW: Theme Config APIs (A→Z)
  /// - app.dart sẽ dùng settings.themeConfig để build ThemeData (không đổi UI layout)
  /// ===============================
  Future<void> setThemeColor(String key, Color color) async {
    final cfg = settings.themeConfig.setColor(key, color);
    settings = settings.copyWith(themeConfig: cfg);
    await _persistThemeConfig();
    notifyListeners();
  }

  Future<void> setFontFamily(String? fontFamily) async {
    final ff = (fontFamily?.trim().isEmpty ?? true) ? null : fontFamily!.trim();
    settings = settings.copyWith(
      themeConfig: settings.themeConfig.copyWith(fontFamily: ff),
    );
    await _persistThemeConfig();
    notifyListeners();
  }

  Future<void> setHeaderScale(double scale) async {
    final s = scale.clamp(0.8, 1.6);
    settings = settings.copyWith(
      themeConfig: settings.themeConfig.copyWith(headerScale: s),
    );
    await _persistThemeConfig();
    notifyListeners();
  }

  Future<void> setBodyScale(double scale) async {
    final s = scale.clamp(0.8, 1.6);
    settings = settings.copyWith(
      themeConfig: settings.themeConfig.copyWith(bodyScale: s),
    );
    await _persistThemeConfig();
    notifyListeners();
  }

  Future<void> resetThemeToDefaults({bool? darkDefault}) async {
    final useDark = darkDefault ??
        (settings.themeMode == ThemeMode.dark ||
            settings.themeMode == ThemeMode.system);
    settings = settings.copyWith(
      themeConfig: ThemeConfig.defaults(darkDefault: useDark),
    );
    await _persistThemeConfig();
    notifyListeners();
  }

  Future<void> _persistThemeConfig() async {
    final raw = jsonEncode(settings.themeConfig.toMap());
    await _prefs.setString(_kPrefThemeConfig, raw);
  }

  Future<void> _initFolders() async {
    // Desktop: lưu cùng cấp thư mục chạy app để copy nguyên thư mục sang máy khác vẫn còn nhạc.
    // Mobile: vẫn dùng Documents vì Android/iOS không cho ghi ổn định cạnh file app.
    Directory baseDir;
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      baseDir = Directory(p.dirname(Platform.resolvedExecutable));
    } else {
      baseDir = await getApplicationDocumentsDirectory();
    }

    _rootDir = Directory(p.join(baseDir.path, 'AppMusicVol2'));

    // Một lần đầu chuyển từ Documents/AppMusicVol2 cũ sang thư mục portable cạnh app.
    if (!await _rootDir.exists() &&
        !kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final docs = await getApplicationDocumentsDirectory();
      final oldRoot = Directory(p.join(docs.path, 'AppMusicVol2'));
      if (await oldRoot.exists()) {
        await _copyDirectory(oldRoot, _rootDir);
      }
    }

    audioDir = Directory(p.join(_rootDir.path, 'Audio'));
    imageDir = Directory(p.join(_rootDir.path, 'Images'));
    for (final d in [_rootDir, audioDir, imageDir]) {
      if (!await d.exists()) await d.create(recursive: true);
    }

    // 2 thư mục này không dùng nữa, dữ liệu yêu thích/playlist nằm trong app.db.
    await _deleteUnusedFolderIfExists(p.join(_rootDir.path, 'Favorites'));
    await _deleteUnusedFolderIfExists(p.join(_rootDir.path, 'Playlists'));
  }

  Future<void> _deleteUnusedFolderIfExists(String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _copyDirectory(Directory from, Directory to) async {
    if (!await to.exists()) await to.create(recursive: true);
    await for (final entity in from.list(recursive: false, followLinks: false)) {
      final targetPath = p.join(to.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        await entity.copy(targetPath);
      }
    }
  }

  Future<void> _initDb() async {
    final dbPath = p.join(_rootDir.path, 'app.db');
    _db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            localPath TEXT NOT NULL,
            signature TEXT NOT NULL UNIQUE,
            coverPath TEXT,
            durationMs INTEGER NOT NULL,
            createdAt INTEGER NOT NULL
          );
        ''');

        await db.execute('''
          CREATE TABLE favorites (
            trackId TEXT PRIMARY KEY
          );
        ''');

        await db.execute('''
          CREATE TABLE playlists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            isSpecial INTEGER DEFAULT 0
          );
        ''');

        await db.execute('''
          CREATE TABLE playlist_items (
            playlistId TEXT NOT NULL,
            trackId TEXT NOT NULL,
            pos INTEGER NOT NULL,
            PRIMARY KEY (playlistId, trackId)
          );
        ''');

        await db.execute('''
          CREATE TABLE favorite_segments (
            id TEXT PRIMARY KEY,
            trackId TEXT NOT NULL,
            name TEXT NOT NULL,
            startMs INTEGER NOT NULL,
            endMs INTEGER NOT NULL,
            createdAt INTEGER NOT NULL
          );
        ''');

        await db.execute('''
          CREATE TABLE playback_state (
            k INTEGER PRIMARY KEY,
            currentTrackId TEXT,
            positionMs INTEGER NOT NULL,
            isPlaying INTEGER NOT NULL,
            loopOne INTEGER NOT NULL,
            continuous INTEGER NOT NULL
          );
        ''');

        await db.insert(
          'playback_state',
          PlaybackStateRow(
            currentTrackId: null,
            positionMs: 0,
            isPlaying: false,
            loopOne: false,
            continuous: true,
          ).toMap(),
        );

        // Create default "Phân đoạn yêu thích" playlist
        await db.insert('playlists', {
          'id': 'special_favorite_segments',
          'name': 'Phân đoạn yêu thích',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'isSpecial': 1,
        });
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            ALTER TABLE playlists ADD COLUMN isSpecial INTEGER DEFAULT 0;
          ''');

          await db.execute('''
            CREATE TABLE favorite_segments (
              id TEXT PRIMARY KEY,
              trackId TEXT NOT NULL,
              name TEXT NOT NULL,
              startMs INTEGER NOT NULL,
              endMs INTEGER NOT NULL,
              createdAt INTEGER NOT NULL
            );
          ''');

          // Create default "Phân đoạn yêu thích" playlist if not exists
          final exists = await db.query('playlists',
              where: 'id=?', whereArgs: ['special_favorite_segments']);
          if (exists.isEmpty) {
            await db.insert('playlists', {
              'id': 'special_favorite_segments',
              'name': 'Phân đoạn yêu thích',
              'createdAt': DateTime.now().millisecondsSinceEpoch,
              'isSpecial': 1,
            });
          }
        }
      },
    );
  }

  Future<void> _loadAllFromDb() async {
    final db = _db!;
    final trackMaps = await db.query('tracks', orderBy: 'createdAt DESC');

    library
      ..clear()
      ..addAll(trackMaps.map(_trackFromDbMap));

    favorites
      ..clear()
      ..addAll(
          (await db.query('favorites')).map((m) => m['trackId'] as String));

    playlists
      ..clear()
      ..addAll((await db.query('playlists', orderBy: 'createdAt DESC'))
          .map(PlaylistRow.fromMap));

    playlistItems.clear();
    for (final pl in playlists) {
      final items = await db.query(
        'playlist_items',
        where: 'playlistId=?',
        whereArgs: [pl.id],
        orderBy: 'pos ASC',
      );
      playlistItems[pl.id] = items.map((m) => m['trackId'] as String).toList();
    }

    favoriteSegments
      ..clear()
      ..addAll((await db.query('favorite_segments', orderBy: 'createdAt DESC'))
          .map(FavoriteSegment.fromMap));

    notifyListeners();
  }

  TrackRow _trackFromDbMap(Map<String, Object?> m) {
    final row = TrackRow.fromMap(m);
    return TrackRow(
      id: row.id,
      title: row.title,
      artist: row.artist,
      localPath: _absoluteAppPath(row.localPath),
      signature: row.signature,
      coverPath: row.coverPath == null ? null : _absoluteAppPath(row.coverPath!),
      durationMs: row.durationMs,
      createdAt: row.createdAt,
    );
  }

  Future<void> _normalizeDbPathsAndScanAudioFolder() async {
    await _normalizeDbPaths();
    await _importLooseAudioFilesBesideRoot();
    await scanAppAudioFolder();
  }

  Future<void> _normalizeDbPaths() async {
    final rows = await _db!.query('tracks');
    for (final m in rows) {
      final id = m['id'] as String;
      final currentLocal = (m['localPath'] as String?) ?? '';
      final currentCover = m['coverPath'] as String?;

      final fixedLocal = _portableStoredPath(currentLocal, folder: audioDir);
      final fixedCover = currentCover == null
          ? null
          : _portableStoredPath(currentCover, folder: imageDir);

      if (fixedLocal != currentLocal || fixedCover != currentCover) {
        await _db!.update(
          'tracks',
          {'localPath': fixedLocal, 'coverPath': fixedCover},
          where: 'id=?',
          whereArgs: [id],
        );
      }
    }
  }

  Future<void> scanAppAudioFolder() async {
    if (!await audioDir.exists()) return;

    final files = audioDir
        .listSync(recursive: false, followLinks: false)
        .whereType<File>()
        .where((f) => _isAudioPath(f.path))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    var imported = 0;
    for (final file in files) {
      imported += await _addAudioFileToDb(file, copyIntoAudioDir: false);
    }

    if (imported > 0) {
      await _loadAllFromDb();
      if (_current == null && library.isNotEmpty) {
        await setCurrent(library.first.id, autoPlay: false);
      }
    }
  }


  Future<void> _importLooseAudioFilesBesideRoot() async {
    final dropDir = _rootDir.parent;
    if (!await dropDir.exists()) return;

    final files = dropDir
        .listSync(recursive: false, followLinks: false)
        .whereType<File>()
        .where((f) => _isAudioPath(f.path))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    var imported = 0;
    for (final file in files) {
      final stat = await file.stat();
      final signature = '${p.basename(file.path)}::${stat.size}';
      final existed = await _db!.query(
        'tracks',
        where: 'signature=?',
        whereArgs: [signature],
        limit: 1,
      );

      if (existed.isNotEmpty) {
        try {
          await file.delete();
        } catch (_) {}
        continue;
      }

      final added = await _addAudioFileToDb(file, copyIntoAudioDir: true);
      imported += added;
      if (added > 0) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }

    if (imported > 0) {
      await _loadAllFromDb();
    }
  }

  Future<int> _addAudioFileToDb(
    File sourceFile, {
    required bool copyIntoAudioDir,
  }) async {
    if (!await sourceFile.exists()) return 0;
    if (!_isAudioPath(sourceFile.path)) return 0;

    final stat = await sourceFile.stat();
    final signature = '${p.basename(sourceFile.path)}::${stat.size}';

    final existsBySignature = await _db!.query(
      'tracks',
      where: 'signature=?',
      whereArgs: [signature],
      limit: 1,
    );
    if (existsBySignature.isNotEmpty) return 0;

    final portableSourcePath = _portableStoredPath(sourceFile.path, folder: audioDir);
    final existsByPath = await _db!.query(
      'tracks',
      where: 'localPath=?',
      whereArgs: [portableSourcePath],
      limit: 1,
    );
    if (existsByPath.isNotEmpty) return 0;

    final id = _uuid();
    final safeName = _safeFileName(p.basename(sourceFile.path));
    late final String realPath;
    late final String storedPath;

    if (copyIntoAudioDir) {
      realPath = p.join(audioDir.path, '${id}_$safeName');
      await sourceFile.copy(realPath);
      storedPath = _portableStoredPath(realPath, folder: audioDir);
    } else {
      realPath = sourceFile.path;
      storedPath = _portableStoredPath(realPath, folder: audioDir);
    }

    final durationMs = await _probeDurationMs(realPath);
    final title = p.basenameWithoutExtension(safeName.replaceFirst(RegExp(r'^\d+_'), ''));

    final row = TrackRow(
      id: id,
      title: title,
      artist: 'Unknown',
      localPath: storedPath,
      signature: signature,
      coverPath: null,
      durationMs: durationMs,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    await _db!.insert('tracks', row.toMap());
    return 1;
  }

  bool _isAudioPath(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.mp3' || ext == '.m4a' || ext == '.aac' || ext == '.wav' || ext == '.flac';
  }

  String _portableStoredPath(String value, {required Directory folder}) {
    final raw = value.trim();
    if (raw.isEmpty) return raw;

    if (!p.isAbsolute(raw)) return p.normalize(raw);

    final normalizedRoot = p.normalize(_rootDir.path);
    final normalizedRaw = p.normalize(raw);
    if (p.isWithin(normalizedRoot, normalizedRaw)) {
      return p.normalize(p.relative(normalizedRaw, from: normalizedRoot));
    }

    final byName = File(p.join(folder.path, p.basename(raw)));
    if (byName.existsSync()) {
      return p.normalize(p.relative(byName.path, from: _rootDir.path));
    }

    return raw;
  }

  String _absoluteAppPath(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return raw;
    if (p.isAbsolute(raw)) return raw;
    return p.normalize(p.join(_rootDir.path, raw));
  }

  /// ===============================
  /// Import audio (mp3/m4a) + dedupe + copy into Documents
  /// ===============================
  Future<void> importAudioFiles() async {
    // iOS may not need storage permission; Android does. Keep safe:
    if (!kIsWeb && (Platform.isAndroid)) {
      final st = await Permission.audio.request();
      if (!st.isGranted) return;
    }

    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'm4a', 'aac', 'wav', 'flac'],
      withData: false,
    );

    if (res == null || res.files.isEmpty) return;

    var imported = 0;
    for (final f in res.files) {
      final srcPath = f.path;
      if (srcPath == null) continue;
      imported += await _addAudioFileToDb(File(srcPath), copyIntoAudioDir: true);
    }

    if (imported > 0) {
      await _loadAllFromDb();
      if (_current == null && library.isNotEmpty) {
        await setCurrent(library.first.id, autoPlay: false);
      }
    }
  }

  /// ===============================
  /// NEW: Import from VIDEO -> convert to M4A (AAC) -> add into tracks DB
  /// - KHÔNG đụng tới importAudioFiles() cũ
  /// - Output lưu vào audioDir của app (Documents/AppMusicVol2/Audio)
  /// - Trả về null nếu OK, trả về string nếu lỗi để UI show SnackBar
  /// ===============================
  Future<String?> importVideoToM4a() async {
    if (isConvertingVideo) return 'Đang chuyển đổi, vui lòng chờ...';

    isConvertingVideo = true;
    convertProgress = 0.0;
    convertLabel = 'Đang chọn video...';
    notifyListeners();

    try {
      // 1) PICK VIDEO FROM PHOTOS (Gallery)
      final picker = ImagePicker();
      final x = await picker.pickVideo(source: ImageSource.gallery);
      if (x == null) {
        isConvertingVideo = false;
        convertLabel = '';
        notifyListeners();
        return 'Đã huỷ chọn video';
      }

      final srcPath = x.path;
      final srcFile = File(srcPath);
      if (!await srcFile.exists()) {
        isConvertingVideo = false;
        convertLabel = '';
        notifyListeners();
        return 'Video không tồn tại';
      }

      // 2) Prepare output
      convertLabel = 'Đang chuẩn bị chuyển đổi...';
      notifyListeners();

      final id = _uuid();
      final base = p.basenameWithoutExtension(srcPath);
      final safeBase = _safeFileName(base);
      final outPath = p.join(audioDir.path, '${id}_$safeBase.m4a');

      // 3) Run FFmpeg async + statistics progress
      // - statistics.getTime() trả ms đã xử lý => map sang progress.
      // API statistics callback của ffmpeg-kit Flutter: :contentReference[oaicite:2]{index=2}
      //
      // Lưu ý: để progress "đúng nghĩa" cần duration đầu vào.
      // Nếu anh muốn 100% chính xác, nên FFprobe duration trước.
      // (Ở đây tạm dùng progress theo time processed / duration audio/video ước lượng từ player sau khi convert là không được.)
      //
      // => Cách đúng: dùng FFprobeKit để lấy duration input (nếu package anh đang dùng có FFprobeKit).
      // Nếu dự án anh chưa import FFprobeKit, anh có thể để progress dạng indeterminate (LinearProgressIndicator không value).
      //
      // Bản này: cho progress "theo time processed", nhưng nếu chưa lấy duration -> vẫn hiển thị % tương đối bằng cách clamp.
      double? inputDurationMs; // TODO: fill via FFprobeKit for exact progress

      final cmd =
          '-y -i "${_ffq(srcPath)}" -vn -c:a aac -b:a 192k "${_ffq(outPath)}"';

      final completer = Completer<String?>();
      convertLabel = 'Đang chuyển đổi...';
      notifyListeners();

      await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final rc = await session.getReturnCode();
          if (!ReturnCode.isSuccess(rc)) {
            final logs = await session.getAllLogsAsString();
            completer.complete(
              'Convert thất bại${logs == null || logs.trim().isEmpty ? '' : '\n$logs'}',
            );
            return;
          }

          // 4) Add to DB
          final durationMs = await _probeDurationMs(outPath);
          final st = await File(outPath).stat();
          final signature = '${p.basename(outPath)}::${st.size}';

          final exists = await _db!.query(
            'tracks',
            where: 'signature=?',
            whereArgs: [signature],
            limit: 1,
          );

          if (exists.isNotEmpty) {
            try {
              await File(outPath).delete();
            } catch (_) {}
            completer.complete('File đã tồn tại trong thư viện');
            return;
          }

          final row = TrackRow(
            id: id,
            title: safeBase.isEmpty ? 'Video Audio' : safeBase,
            artist: 'Unknown',
            localPath: _portableStoredPath(outPath, folder: audioDir),
            signature: signature,
            coverPath: null,
            durationMs: durationMs,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          );

          await _db!.insert('tracks', row.toMap());
          await _loadAllFromDb();

          if (_current == null && library.isNotEmpty) {
            await setCurrent(library.first.id, autoPlay: false);
          }

          convertProgress = 1.0;
          convertLabel = 'Hoàn tất';
          notifyListeners();

          completer.complete(null);
        },
        null,
        (statistics) {
          // statistics.getTime() là ms đã xử lý (theo ffmpeg-kit). :contentReference[oaicite:3]{index=3}
          final t = statistics.getTime(); // ms
          if (inputDurationMs != null && inputDurationMs! > 0) {
            convertProgress = (t / inputDurationMs!).clamp(0.0, 0.999);
          } else {
            // chưa có duration -> chỉ “nhúc nhích” để UI có cảm giác đang chạy
            convertProgress = (convertProgress + 0.01).clamp(0.0, 0.95);
          }
          notifyListeners();
        },
      );

      return await completer.future;
    } catch (e) {
      return e.toString();
    } finally {
      isConvertingVideo = false;
      // convertLabel giữ lại để UI kịp show “Hoàn tất” 1 nhịp (tuỳ anh)
      notifyListeners();
    }
  }

  /// Escape quote cho FFmpeg command
  String _ffq(String s) => s.replaceAll('"', '\\"');

  Future<int> _probeDurationMs(String path) async {
    final ap = AudioPlayer();
    try {
      await ap.setFilePath(path);
      final d = ap.duration;
      return (d?.inMilliseconds ?? 0);
    } catch (_) {
      return 0;
    } finally {
      await ap.dispose();
    }
  }

  /// ===============================
  /// Cover image: pick + copy into app sandbox (rule)
  /// ===============================
  Future<void> setTrackCover(String trackId) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
    if (res == null || res.files.isEmpty) return;

    final srcPath = res.files.first.path;
    if (srcPath == null) return;

    final ext = p.extension(srcPath).toLowerCase();
    final destPath = p.join(imageDir.path, 'cover_$trackId$ext');

    await File(srcPath).copy(destPath);

    await _db!.update(
      'tracks',
      {'coverPath': _portableStoredPath(destPath, folder: imageDir)},
      where: 'id=?',
      whereArgs: [trackId],
    );
    await _loadAllFromDb();

    // refresh current
    _current =
        library.firstWhere((t) => t.id == trackId, orElse: () => _current!);
    notifyListeners();
  }

  Future<void> renameTrack(String trackId, String newName) async {
    final name = newName.trim();
    if (name.isEmpty) return;
    await _db!.update(
      'tracks',
      {'title': name},
      where: 'id=?',
      whereArgs: [trackId],
    );
    await _loadAllFromDb();
    if (_current?.id == trackId) {
      _current = library.firstWhere((t) => t.id == trackId);
    }
    notifyListeners();
  }

  /// Remove from app (delete copied audio file + db). Never touch original.
  Future<void> removeTrackFromApp(String trackId) async {
    final row = library.firstWhere((t) => t.id == trackId);

    // stop if currently playing this
    if (_current?.id == trackId) {
      await handler.pause();
      _current = null;
      position = Duration.zero;
      await _savePlaybackNow(
        isPlaying: false,
        currentTrackId: null,
        positionMs: 0,
      );
    }

    // delete files in app sandbox only
    try {
      final f = File(row.localPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    if (row.coverPath != null) {
      try {
        final c = File(row.coverPath!);
        if (await c.exists()) await c.delete();
      } catch (_) {}
    }

    await _db!.delete('favorites', where: 'trackId=?', whereArgs: [trackId]);
    await _db!
        .delete('playlist_items', where: 'trackId=?', whereArgs: [trackId]);
    await _db!.delete('tracks', where: 'id=?', whereArgs: [trackId]);

    await _loadAllFromDb();
  }

  Future<void> toggleFavorite(String trackId) async {
    if (favorites.contains(trackId)) {
      favorites.remove(trackId);
      await _db!.delete('favorites', where: 'trackId=?', whereArgs: [trackId]);
    } else {
      favorites.add(trackId);
      await _db!.insert('favorites', {'trackId': trackId});
    }
    notifyListeners();
  }

  /// ===============================
  /// Playlists
  /// ===============================
  Future<void> createPlaylist(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    final id = _uuid();
    final row = PlaylistRow(
      id: id,
      name: n,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db!.insert('playlists', row.toMap());
    await _loadAllFromDb();
  }

  Future<void> deletePlaylist(String playlistId) async {
    // Prevent deleting special playlists
    final pl = playlists.firstWhere((p) => p.id == playlistId);
    if (pl.isSpecial) return;

    await _db!.delete('playlist_items',
        where: 'playlistId=?', whereArgs: [playlistId]);
    await _db!.delete('playlists', where: 'id=?', whereArgs: [playlistId]);
    await _loadAllFromDb();
  }

  /// ===============================
  /// Favorite Segments
  /// ===============================
  Future<void> addFavoriteSegment({
    required String trackId,
    required String name,
    required int startMs,
    required int endMs,
  }) async {
    final id = _uuid();
    final segment = FavoriteSegment(
      id: id,
      trackId: trackId,
      name: name,
      startMs: startMs,
      endMs: endMs,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    await _db!.insert('favorite_segments', segment.toMap());
    await _loadAllFromDb();
  }

  Future<void> deleteFavoriteSegment(String segmentId) async {
    await _db!
        .delete('favorite_segments', where: 'id=?', whereArgs: [segmentId]);
    await _loadAllFromDb();
  }

  List<FavoriteSegment> getSegmentsForTrack(String trackId) {
    return favoriteSegments.where((s) => s.trackId == trackId).toList();
  }

  Future<void> playSegment(FavoriteSegment segment,
      {bool autoPlay = true}) async {
    final idx = library.indexWhere((t) => t.id == segment.trackId);
    if (idx < 0) return;
    final track = library[idx];

    _current = track;
    final startPos = Duration(milliseconds: segment.startMs);

    final items = library.map(_toMediaItem).toList();
    await handler.setQueueFromTracks(items,
        startIndex: idx, startPos: startPos);
    await handler.setLoopOne(false);

    if (autoPlay) {
      await handler.play();
    }

    await _savePlaybackNow(
      isPlaying: autoPlay,
      currentTrackId: track.id,
      positionMs: segment.startMs,
    );

    notifyListeners();
  }

  Future<void> addToPlaylist(String playlistId, String trackId) async {
    final ids = playlistItems[playlistId] ?? [];
    if (ids.contains(trackId)) return;

    final pos = ids.length;
    await _db!.insert('playlist_items',
        {'playlistId': playlistId, 'trackId': trackId, 'pos': pos});
    await _loadAllFromDb();
  }

  Future<void> removeFromPlaylist(String playlistId, String trackId) async {
    await _db!.delete('playlist_items',
        where: 'playlistId=? AND trackId=?', whereArgs: [playlistId, trackId]);
    await _loadAllFromDb();
  }

  /// ===============================
  /// NEW: Import directly into a playlist - ALLOWS MULTIPLE FILE SELECTION
  /// ===============================
  Future<void> importIntoPlaylist(String playlistId) async {
    // iOS may not need storage permission; Android does. Keep safe:
    if (!kIsWeb && (Platform.isAndroid)) {
      final st = await Permission.audio.request();
      if (!st.isGranted) return;
    }

    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'm4a', 'aac', 'wav', 'flac'],
      withData: false,
    );

    if (res == null || res.files.isEmpty) return;

    for (final f in res.files) {
      final srcPath = f.path;
      if (srcPath == null) continue;

      final before = await _db!.query('tracks');
      await _addAudioFileToDb(File(srcPath), copyIntoAudioDir: true);

      final stat = await File(srcPath).stat();
      final signature = '${p.basename(srcPath)}::${stat.size}';
      final found = await _db!.query(
        'tracks',
        where: 'signature=?',
        whereArgs: [signature],
        limit: 1,
      );

      if (found.isNotEmpty) {
        await addToPlaylist(playlistId, found.first['id'] as String);
      } else if (before.isNotEmpty) {
        // Không làm gì: file có thể không hợp lệ hoặc đã bị bỏ qua.
      }
    }

    await _loadAllFromDb();
  }

  /// ===============================
  /// NEW: Find playlists containing a track
  /// ===============================
  List<PlaylistRow> playlistsContaining(String trackId) {
    return playlists.where((pl) {
      final ids = playlistItems[pl.id] ?? const <String>[];
      return ids.contains(trackId);
    }).toList();
  }

  /// ===============================
  /// NEW: Play a playlist (ordered by pos)
  /// ===============================
  Future<void> playPlaylist(
    String playlistId, {
    bool autoPlay = true,
    String? startTrackId,
  }) async {
    final ids = playlistItems[playlistId] ?? const <String>[];
    if (ids.isEmpty) return;

    final tracks = <TrackRow>[];
    for (final id in ids) {
      final t = library.where((x) => x.id == id).toList();
      if (t.isNotEmpty) tracks.add(t.first);
    }
    if (tracks.isEmpty) return;

    int startIndex = 0;
    if (startTrackId != null) {
      final i = tracks.indexWhere((t) => t.id == startTrackId);
      if (i >= 0) startIndex = i;
    }

    final items = tracks.map(_toMediaItem).toList();

    _current = tracks[startIndex];
    position = Duration.zero;

    await handler.setQueueFromTracks(items, startIndex: startIndex);
    await handler.setLoopOne(loopOne);

    if (autoPlay) {
      await handler.play();
    } else {
      await handler.pause();
    }

    await _savePlaybackNow(
      isPlaying: autoPlay,
      currentTrackId: _current?.id,
      positionMs: 0,
    );

    notifyListeners();
  }

  /// ===============================
  /// Playback control
  /// ===============================
  Future<void> setCurrent(
    String trackId, {
    bool autoPlay = true,
    Duration? startPos,
  }) async {
    final idx = library.indexWhere((t) => t.id == trackId);
    if (idx < 0) return;

    _current = library[idx];

    if (!_handlerReady) {
      notifyListeners();
      return;
    }

    final items = library.map(_toMediaItem).toList();
    await handler.setQueueFromTracks(
      items,
      startIndex: idx,
      startPos: startPos,
    );
    await handler.setLoopOne(loopOne);

    if (autoPlay) {
      await handler.play();
    } else {
      await handler.pause();
    }

    // save state
    await _savePlaybackNow(
      isPlaying: autoPlay,
      currentTrackId: trackId,
      positionMs: (startPos ?? Duration.zero).inMilliseconds,
    );

    notifyListeners();
  }

  Future<void> playPause() async {
    if (_current == null) {
      if (library.isNotEmpty) {
        await setCurrent(library.first.id, autoPlay: true);
      }
      return;
    }
    final playing = handler.playbackState.value.playing;
    if (playing) {
      await handler.pause();
    } else {
      await handler.play();
    }
    _scheduleSavePlayback();
    notifyListeners();
  }

  Future<void> next() async {
    await handler.skipToNext();
    _scheduleSavePlayback();
    notifyListeners(); // _current sẽ được update bởi mediaItem listener
  }

  Future<void> previous() async {
    await handler.skipToPrevious();
    _scheduleSavePlayback();
    notifyListeners(); // _current sẽ được update bởi mediaItem listener
  }

  Future<void> seek(Duration to) async {
    await handler.seek(to);
    position = to;
    _scheduleSavePlayback();
    notifyListeners();
  }

  Future<void> toggleLoopOne() async {
    loopOne = !loopOne;
    await handler.setLoopOne(loopOne);
    _scheduleSavePlayback();
    notifyListeners();
  }

  Future<void> toggleContinuous() async {
    continuousPlay = !continuousPlay;
    _scheduleSavePlayback();
    notifyListeners();
  }

  /// ===============================
  /// Restore state without auto-playing
  /// ===============================
  Future<void> _restorePlaybackStateWithoutAutoPlay() async {
    final rows = await _db!.query('playback_state', where: 'k=1', limit: 1);
    if (rows.isEmpty) return;

    final s = PlaybackStateRow.fromMap(rows.first);
    loopOne = s.loopOne;
    continuousPlay = s.continuous;

    // Load the track reference but DON'T start playing
    if (s.currentTrackId != null &&
        library.any((t) => t.id == s.currentTrackId)) {
      _current = library.firstWhere((t) => t.id == s.currentTrackId);

      // Set up the queue but don't play
      final items = library.map(_toMediaItem).toList();
      final idx = library.indexWhere((t) => t.id == s.currentTrackId);

      if (idx >= 0) {
        await handler.setQueueFromTracks(items, startIndex: idx);
        await handler.setLoopOne(loopOne);
        // Explicitly ensure we're paused
        await handler.pause();
      }
    } else if (library.isNotEmpty) {
      _current = library.first;
    }

    notifyListeners();
  }

  void _scheduleSavePlayback() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () async {
      final idx = handler.playbackState.value.queueIndex;
      final currentId = (idx != null && idx >= 0 && idx < library.length)
          ? library[idx].id
          : _current?.id;

      await _savePlaybackNow(
        isPlaying: handler.playbackState.value.playing,
        currentTrackId: currentId,
        positionMs: position.inMilliseconds,
      );
    });
  }

  Future<void> _savePlaybackNow({
    required bool isPlaying,
    required String? currentTrackId,
    required int positionMs,
  }) async {
    await _db!.update(
      'playback_state',
      PlaybackStateRow(
        currentTrackId: currentTrackId,
        positionMs: positionMs,
        isPlaying: isPlaying,
        loopOne: loopOne,
        continuous: continuousPlay,
      ).toMap(),
      where: 'k=1',
    );
  }

  MediaItem _toMediaItem(TrackRow t) {
    return MediaItem(
      id: t.id,
      title: t.title,
      artist: t.artist,
      duration: Duration(milliseconds: t.durationMs),
      artUri: (t.coverPath == null) ? null : Uri.file(_absoluteAppPath(t.coverPath!)),
      extras: {'path': _absoluteAppPath(t.localPath)},
    );
  }

  /// Utils
  String _uuid() => DateTime.now().microsecondsSinceEpoch.toString();

  String _safeFileName(String name) {
    // keep extension, remove weird chars
    final base = name.replaceAll(RegExp(r'[^\w\-. ]+'), '_');
    return base.isEmpty ? 'file' : base;
  }

  /// ===============================
  /// BACKUP → EXPORT ZIP
  /// ===============================
  Future<String?> exportLibraryToZip() async {
    try {
      final archive = Archive();

      final root = Directory(_rootDir.path);
      if (!await root.exists()) return 'Không tìm thấy dữ liệu';

      final files = root.listSync(recursive: true, followLinks: false);

      for (final f in files) {
        if (f is File) {
          final rel = p.relative(f.path, from: _rootDir.path);
          final bytes = await f.readAsBytes();
          archive.addFile(ArchiveFile(rel, bytes.length, bytes));
        }
      }

      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) return 'Không thể tạo file zip';

      final exportPath = p.join(
          _rootDir.path, 'backup_${DateTime.now().millisecondsSinceEpoch}.zip');

      await File(exportPath).writeAsBytes(zipData);
      return exportPath;
    } catch (e) {
      return e.toString();
    }
  }

  /// ===============================
  /// RESTORE → IMPORT ZIP
  /// ===============================
  Future<String?> importLibraryFromZip() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        allowMultiple: false,
      );

      if (res == null || res.files.isEmpty) return 'Đã huỷ';

      final zipPath = res.files.first.path;
      if (zipPath == null) return 'File không hợp lệ';

      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // xoá dữ liệu cũ
      if (await _rootDir.exists()) {
        await _rootDir.delete(recursive: true);
      }

      await _initFolders();

      for (final file in archive) {
        final outPath = p.join(_rootDir.path, file.name);
        if (file.isFile) {
          final outFile = File(outPath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        }
      }

      await _initDb();
      await _loadAllFromDb();

      notifyListeners();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _mediaItemSub?.cancel();
    handler.stop();
    _db?.close();
    super.dispose();
  }
}

// app.dart
// app.dart - CẬP NHẬT: THEME CONFIG A→Z (đổi mọi màu/font), GIỮ NGUYÊN UI/LAYOUT,
// VISUALIZER TO HƠN + STICKY HEROCARD



class AppRoot extends StatefulWidget {
  final AppLogic logic;
  const AppRoot({super.key, required this.logic});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    widget.logic.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.logic.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  ThemeData _buildTheme({required bool dark, required ThemeConfig cfg}) {
    final base = dark ? ThemeData.dark() : ThemeData.light();

    // Fallbacks theo dark/light
    final fallback = ThemeConfig.defaults(darkDefault: dark);

    Color c(String k, Color fb) => cfg.getColor(k, fb);
    Color cf(String k) => cfg.getColor(k, fallback.getColor(k, Colors.pink));

    final primary = cf('primary');
    final secondary = cf('secondary');
    final background = cf('background');
    final surface = cf('surface');
    final card = cf('card');
    final divider = cf('divider');
    final shadow = cf('shadow');

    final textPrimary = cf('textPrimary');
    final textSecondary = cf('textSecondary');
    final textTertiary = cf('textTertiary');
    final textOnPrimary = cf('textOnPrimary');

    final appBarBg = cf('appBarBg');
    final appBarFg = cf('appBarFg');

    final bottomBg = cf('bottomNavBg');
    final bottomSelected = cf('bottomNavSelected');
    final bottomUnselected = cf('bottomNavUnselected');

    final buttonBg = cf('buttonBg');
    final buttonFg = cf('buttonFg');
    final buttonTonalBg = cf('buttonTonalBg');
    final buttonTonalFg = cf('buttonTonalFg');

    final inputFill = cf('inputFill');
    final inputBorder = cf('inputBorder');
    final inputHint = cf('inputHint');

    final iconPrimary = cf('iconPrimary');
    final iconSecondary = cf('iconSecondary');

    final sliderActive = cf('sliderActive');
    final sliderInactive = cf('sliderInactive');
    final sliderThumb = cf('sliderThumb');
    final sliderOverlay = cf('sliderOverlay');

    final dialogBg = cf('dialogBg');
    final sheetBg = cf('sheetBg');

    final snackBg = cf('snackBg');
    final snackFg = cf('snackFg');

    // Typography scaling (không đổi layout, chỉ scale font size token)
    final headerScale = (cfg.headerScale ?? 1.0).clamp(0.8, 1.6);
    final bodyScale = (cfg.bodyScale ?? 1.0).clamp(0.8, 1.6);

    TextTheme _scaleTextTheme(TextTheme t) {
      TextStyle? scale(TextStyle? s, double k) {
        if (s == null) return null;
        final fs = s.fontSize;
        return s.copyWith(
          fontSize: fs == null ? null : (fs * k),
        );
      }

      // Header = title/display, Body = body/label
      return t.copyWith(
        displayLarge: scale(t.displayLarge, headerScale),
        displayMedium: scale(t.displayMedium, headerScale),
        displaySmall: scale(t.displaySmall, headerScale),
        headlineLarge: scale(t.headlineLarge, headerScale),
        headlineMedium: scale(t.headlineMedium, headerScale),
        headlineSmall: scale(t.headlineSmall, headerScale),
        titleLarge: scale(t.titleLarge, headerScale),
        titleMedium: scale(t.titleMedium, headerScale),
        titleSmall: scale(t.titleSmall, headerScale),
        bodyLarge: scale(t.bodyLarge, bodyScale),
        bodyMedium: scale(t.bodyMedium, bodyScale),
        bodySmall: scale(t.bodySmall, bodyScale),
        labelLarge: scale(t.labelLarge, bodyScale),
        labelMedium: scale(t.labelMedium, bodyScale),
        labelSmall: scale(t.labelSmall, bodyScale),
      );
    }

    final baseText = base.textTheme.apply(
      bodyColor: textPrimary,
      displayColor: textPrimary,
    );

    final textTheme = _scaleTextTheme(baseText).copyWith(
      bodySmall:
          _scaleTextTheme(baseText).bodySmall?.copyWith(color: textSecondary),
      bodyMedium:
          _scaleTextTheme(baseText).bodyMedium?.copyWith(color: textPrimary),
      bodyLarge:
          _scaleTextTheme(baseText).bodyLarge?.copyWith(color: textPrimary),
    );

    return base.copyWith(
      useMaterial3: true,

      scaffoldBackgroundColor: background,

      colorScheme: base.colorScheme.copyWith(
        primary: primary,
        secondary: secondary,
        surface: surface,
      ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: appBarBg,
        foregroundColor: appBarFg,
        elevation: 0,
        iconTheme: IconThemeData(color: appBarFg),
        titleTextStyle: (textTheme.titleLarge ?? const TextStyle()).copyWith(
          color: appBarFg,
          fontWeight: FontWeight.w700,
        ),
      ),

      // Bottom nav
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: bottomBg,
        selectedItemColor: bottomSelected,
        unselectedItemColor: bottomUnselected,
        type: BottomNavigationBarType.fixed,
      ),

      // Cards
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shadowColor: shadow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      // Divider
      dividerTheme: DividerThemeData(
        color: divider,
        thickness: 1,
        space: 1,
      ),

      // Icon
      iconTheme: IconThemeData(color: iconPrimary),
      primaryIconTheme: IconThemeData(color: iconPrimary),

      // Slider
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: sliderActive,
        thumbColor: sliderThumb,
        overlayColor: sliderOverlay,
        inactiveTrackColor: sliderInactive,
      ),

      // Inputs (TextField, Search)
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        hintStyle: TextStyle(color: inputHint),
        prefixIconColor: iconSecondary,
        suffixIconColor: iconSecondary,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: inputBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primary, width: 1.2),
        ),
      ),

      // Dialogs
      dialogTheme: DialogThemeData(
        backgroundColor: dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titleTextStyle: (textTheme.titleMedium ?? const TextStyle()).copyWith(
          color: textPrimary,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: (textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: textSecondary,
        ),
      ),

      // Sheets (chủ yếu set backgroundColor tại showModalBottomSheet)
      // -> vẫn giữ token để app dùng
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: sheetBg,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),

      // Buttons
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: buttonBg,
          foregroundColor: buttonFg,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
        ),
      ),

      // SnackBar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: snackBg,
        contentTextStyle: TextStyle(color: snackFg),
        actionTextColor: primary,
      ),

      // Text theme
      textTheme: textTheme.copyWith(
        titleLarge: textTheme.titleLarge?.copyWith(color: textPrimary),
        titleMedium: textTheme.titleMedium?.copyWith(color: textPrimary),
        titleSmall: textTheme.titleSmall?.copyWith(color: textPrimary),
        bodySmall: textTheme.bodySmall?.copyWith(color: textSecondary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logic = widget.logic;

    // ThemeConfig dùng chung, build 2 theme (light/dark) nhưng vẫn theo token của user.
    // Nếu user đang dùng ThemeMode.dark => lấy defaults(dark) làm fallback.
    final cfg = logic.settings.themeConfig;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(dark: false, cfg: cfg),
      darkTheme: _buildTheme(dark: true, cfg: cfg),
      themeMode: logic.settings.themeMode,
      home: _Shell(
        logic: logic,
        tab: _tab,
        onTab: (i) => setState(() => _tab = i),
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  final AppLogic logic;
  final int tab;
  final ValueChanged<int> onTab;

  const _Shell({required this.logic, required this.tab, required this.onTab});

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _HomePage(logic: logic),
      _FavoritesPage(logic: logic),
      _PlaylistsPage(logic: logic),
      _SettingsPage(logic: logic),
    ];

    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        title: Text(logic.settings.appTitle),
        actions: [
          IconButton(
            tooltip: 'Now Playing',
            onPressed: () => _openNowPlaying(context),
            icon: const Icon(Icons.queue_music_rounded),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: logic,
        builder: (context, _) => pages[tab],
      ),
      bottomNavigationBar: _GlassBottomNav(
        currentIndex: tab,
        onTap: onTab,
        items: const [
          _GlassNavItem(icon: Icons.home_rounded, label: 'Home'),
          _GlassNavItem(icon: Icons.favorite_rounded, label: 'Yêu thích'),
          _GlassNavItem(icon: Icons.library_music_rounded, label: 'List'),
          _GlassNavItem(icon: Icons.settings_rounded, label: 'Setting'),
        ],
      ),
      floatingActionButton: (tab == 0)
          ? FloatingActionButton(
              backgroundColor: Theme.of(context).colorScheme.primary,
              onPressed: () => _openImportMenu(context),
              child: const Icon(Icons.add_rounded),
            )
          : null,
    );
  }

  void _openImportMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: Theme.of(context).bottomSheetTheme.shape,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.library_music_rounded),
              title: const Text('Thêm file'),
              subtitle: const Text('Chọn mp3/m4a'),
              onTap: () {
                Navigator.pop(context);
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  await logic.importAudioFiles();
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_file_rounded),
              title: const Text('Chuyển video thành file'),
              subtitle: const Text('Chọn video → xuất .m4a vào thư viện'),
              onTap: () {
                Navigator.pop(context);
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  // mở dialog progress
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => AnimatedBuilder(
                      animation: logic,
                      builder: (_, __) {
                        return AlertDialog(
                          title: const Text('Đang chuyển đổi video'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(logic.convertLabel),
                              const SizedBox(height: 12),
                              LinearProgressIndicator(
                                  value: logic.convertProgress),
                              const SizedBox(height: 8),
                              Text(
                                  '${(logic.convertProgress * 100).toStringAsFixed(0)}%'),
                            ],
                          ),
                        );
                      },
                    ),
                  );

                  final err = await logic.importVideoToM4a();

                  if (context.mounted) Navigator.pop(context); // đóng dialog

                  if (err != null && context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(err)));
                  }
                });
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  void _openNowPlaying(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: Theme.of(context).bottomSheetTheme.shape,
      builder: (_) => _NowPlayingSheet(logic: logic),
    );
  }
}


class _GlassNavItem {
  final IconData icon;
  final String label;

  const _GlassNavItem({required this.icon, required this.label});
}

class _GlassBottomNav extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<_GlassNavItem> items;

  const _GlassBottomNav({
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  State<_GlassBottomNav> createState() => _GlassBottomNavState();
}

class _GlassBottomNavState extends State<_GlassBottomNav>
    with SingleTickerProviderStateMixin {
  double? _dragX;
  double _dragVisualIndex = 0;
  late final AnimationController _spring;
  late Animation<double> _springAnim;

  double get _targetIndex => widget.currentIndex.toDouble();

  @override
  void initState() {
    super.initState();
    _dragVisualIndex = _targetIndex;
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 470),
    )..addListener(() {
        setState(() => _dragVisualIndex = _springAnim.value);
      });
    _springAnim = AlwaysStoppedAnimation(_dragVisualIndex);
  }

  @override
  void didUpdateWidget(covariant _GlassBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex && _dragX == null) {
      _animateTo(_targetIndex);
    }
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _animateTo(double value) {
    _spring.stop();
    _springAnim = Tween<double>(begin: _dragVisualIndex, end: value).animate(
      CurvedAnimation(parent: _spring, curve: Curves.easeOutBack),
    );
    _spring.forward(from: 0);
  }

  double _indexFromDx(double dx, double width) {
    final count = widget.items.length;
    if (count <= 1 || width <= 0) return 0;
    final itemW = width / count;
    return ((dx - itemW / 2) / itemW).clamp(0.0, (count - 1).toDouble());
  }

  void _updateDrag(Offset localPosition, double width) {
    if (widget.items.isEmpty || width <= 0) return;
    _spring.stop();
    setState(() {
      _dragX = localPosition.dx.clamp(0.0, width);
      _dragVisualIndex = _indexFromDx(_dragX!, width);
    });
  }

  void _commitDrag(double width) {
    if (widget.items.isEmpty || width <= 0 || _dragX == null) {
      setState(() => _dragX = null);
      _animateTo(_targetIndex);
      return;
    }
    final index = _dragVisualIndex.round().clamp(0, widget.items.length - 1).toInt();
    setState(() => _dragX = null);
    if (index != widget.currentIndex) {
      widget.onTap(index);
    } else {
      _animateTo(index.toDouble());
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final primary = Theme.of(context).colorScheme.primary;
    final count = widget.items.length;

    return SafeArea(
      top: false,
      minimum: EdgeInsets.fromLTRB(
        18,
        0,
        18,
        bottom == 0 ? 10 : 4,
      ),
      child: _GlassSurface(
        radius: 28,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: LayoutBuilder(
          builder: (context, c) {
            final width = c.maxWidth;
            final itemW = count == 0 ? width : width / count;
            final visualIndex = (_dragX == null ? _dragVisualIndex : _dragVisualIndex)
                .round()
                .clamp(0, count - 1)
                .toInt();
            final left = _dragVisualIndex.clamp(0.0, (count - 1).toDouble()) * itemW;

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (d) => _updateDrag(d.localPosition, width),
              onHorizontalDragUpdate: (d) => _updateDrag(d.localPosition, width),
              onHorizontalDragEnd: (_) => _commitDrag(width),
              onHorizontalDragCancel: () {
                setState(() => _dragX = null);
                _animateTo(_targetIndex);
              },
              child: SizedBox(
                height: 54,
                child: Stack(
                  children: [
                    Positioned(
                      left: left,
                      top: 3,
                      width: itemW,
                      height: 48,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            color: Colors.white.withOpacity(0.075),
                            boxShadow: [
                              BoxShadow(
                                color: primary.withOpacity(0.13),
                                blurRadius: 16,
                                spreadRadius: -8,
                                offset: const Offset(0, 7),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: List.generate(count, (index) {
                        final item = widget.items[index];
                        final selected = index == visualIndex;

                        return Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (index != widget.currentIndex) widget.onTap(index);
                              _animateTo(index.toDouble());
                            },
                            child: AnimatedScale(
                              scale: selected ? 1.025 : 1.0,
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOut,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      item.icon,
                                      size: 24,
                                      color: selected
                                          ? primary
                                          : Theme.of(context)
                                              .iconTheme
                                              .color
                                              ?.withOpacity(0.76),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      item.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        height: 1,
                                        fontWeight: selected
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                        color: selected
                                            ? primary
                                            : Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.color
                                                ?.withOpacity(0.72),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GlassSurface extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final String? coverPath;

  const _GlassSurface({
    required this.child,
    this.radius = 28,
    this.padding = const EdgeInsets.all(0),
    this.coverPath,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final hasCover = coverPath != null && File(coverPath!).existsSync();
    final baseColor = isDark ? Colors.black : Colors.white;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        // Nền giữa chỉ blur mạnh để nhìn xuyên phần chữ/ảnh phía sau mờ rõ hơn.
        filter: ImageFilter.blur(sigmaX: 72, sigmaY: 72),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            color: baseColor.withOpacity(isDark ? 0.055 : 0.12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.24 : 0.10),
                blurRadius: 28,
                spreadRadius: -12,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Stack(
            children: [
              if (hasCover)
                Positioned.fill(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Transform.scale(
                      scale: 1.08,
                      child: Opacity(
                        opacity: isDark ? 0.15 : 0.10,
                        child: Image.file(
                          File(coverPath!),
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.low,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(isDark ? 0.045 : 0.11),
                        primary.withOpacity(isDark ? 0.010 : 0.008),
                        Colors.black.withOpacity(isDark ? 0.012 : 0.004),
                      ],
                      stops: const [0.0, 0.48, 1.0],
                    ),
                  ),
                ),
              ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiquidGlassEdgeRefraction extends StatelessWidget {
  final double radius;
  final Color tint;
  final bool isDark;

  const _LiquidGlassEdgeRefraction({
    required this.radius,
    required this.tint,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: LayoutBuilder(
          builder: (_, c) {
            final w = c.maxWidth.isFinite ? c.maxWidth : 360.0;
            final h = c.maxHeight.isFinite ? c.maxHeight : 88.0;
            // Viền Telegram-style: thật mỏng, sáng, khúc xạ nhẹ, không tạo mảng nâu dày.
            final rim = math.max(3.0, math.min(5.2, math.min(w, h) * 0.058));

            return Stack(
              children: [
                _EdgeLensStrip(
                  alignment: Alignment.topCenter,
                  width: w,
                  height: rim,
                  radius: radius,
                  tint: tint,
                  isDark: isDark,
                  flipX: false,
                  flipY: true,
                ),
                _EdgeLensStrip(
                  alignment: Alignment.bottomCenter,
                  width: w,
                  height: rim,
                  radius: radius,
                  tint: tint,
                  isDark: isDark,
                  flipX: false,
                  flipY: true,
                ),
                _EdgeLensStrip(
                  alignment: Alignment.centerLeft,
                  width: rim,
                  height: h,
                  radius: radius,
                  tint: tint,
                  isDark: isDark,
                  flipX: true,
                  flipY: false,
                ),
                _EdgeLensStrip(
                  alignment: Alignment.centerRight,
                  width: rim,
                  height: h,
                  radius: radius,
                  tint: tint,
                  isDark: isDark,
                  flipX: true,
                  flipY: false,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _EdgeLensStrip extends StatelessWidget {
  final Alignment alignment;
  final double width;
  final double height;
  final double radius;
  final Color tint;
  final bool isDark;
  final bool flipX;
  final bool flipY;

  const _EdgeLensStrip({
    required this.alignment,
    required this.width,
    required this.height,
    required this.radius,
    required this.tint,
    required this.isDark,
    required this.flipX,
    required this.flipY,
  });

  @override
  Widget build(BuildContext context) {
    // Viền mỏng lấy nền phía sau, phóng to và đảo chiều để tạo cảm giác khúc xạ kiểu Telegram.
    final matrix = Matrix4.identity()
      ..translate(flipX ? width : width * -0.035, flipY ? height : height * -0.035)
      ..scale(flipX ? -1.18 : 1.12, flipY ? -1.18 : 1.12, 1.0);

    return Align(
      alignment: alignment,
      child: SizedBox(
        width: width,
        height: height,
        child: BackdropFilter(
          filter: ImageFilter.matrix(
            matrix.storage,
            filterQuality: FilterQuality.high,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: flipX ? Alignment.centerLeft : Alignment.topCenter,
                end: flipX ? Alignment.centerRight : Alignment.bottomCenter,
                colors: [
                  Colors.white.withOpacity(isDark ? 0.38 : 0.62),
                  tint.withOpacity(isDark ? 0.022 : 0.018),
                  Colors.white.withOpacity(isDark ? 0.08 : 0.14),
                ],
                stops: const [0.0, 0.48, 1.0],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiquidGlassRimPainter extends CustomPainter {
  final Color primary;
  final bool isDark;
  final double radius;

  const _LiquidGlassRimPainter({
    required this.primary,
    required this.isDark,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    final outer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.white.withOpacity(isDark ? 0.30 : 0.56);
    canvas.drawRRect(rrect.deflate(0.55), outer);

    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.65
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.65)
      ..color = Colors.white.withOpacity(isDark ? 0.16 : 0.30);
    canvas.drawRRect(rrect.deflate(2.4), inner);

    final glint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.5)
      ..color = Colors.white.withOpacity(isDark ? 0.26 : 0.50);

    final topPath = Path()
      ..moveTo(size.width * 0.10, size.height * 0.12)
      ..cubicTo(
        size.width * 0.30,
        size.height * 0.02,
        size.width * 0.50,
        size.height * 0.18,
        size.width * 0.74,
        size.height * 0.08,
      );
    canvas.drawPath(topPath, glint);
  }

  @override
  bool shouldRepaint(covariant _LiquidGlassRimPainter oldDelegate) {
    return oldDelegate.primary != primary ||
        oldDelegate.isDark != isDark ||
        oldDelegate.radius != radius;
  }
}

String _trackPlaylistLabel(AppLogic logic, TrackRow track) {
  final names = logic
      .playlistsContaining(track.id)
      .where((pl) => !pl.isSpecial)
      .map((pl) => pl.name.trim())
      .where((name) => name.isNotEmpty)
      .toList();

  if (names.isEmpty) return 'null';
  return names.join(' - ');
}

/// ===============================
/// HOME (library) - STICKY HEROCARD + SEARCH BAR
/// ===============================
class _HomePage extends StatefulWidget {
  final AppLogic logic;
  const _HomePage({required this.logic});

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final items = widget.logic.library;
    final currentId = widget.logic.currentTrack?.id;

    final query = _searchQuery.trim().toLowerCase();
    final filteredItems = query.isEmpty
        ? items
        : items
            .where((t) =>
                t.title.toLowerCase().contains(query) ||
                _trackPlaylistLabel(widget.logic, t).toLowerCase().contains(query))
            .toList();

    return CustomScrollView(
      slivers: [
        // SEARCH BAR
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Tìm kiếm bài hát, nghệ sĩ...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
            ),
          ),
        ),

        // MINI PLAYER: chỉ nằm trong Home, né search lúc ở đầu trang,
        // khi kéo xuống sẽ tự pin lên sát header.
        if (widget.logic.currentTrack != null)
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedMusicBarDelegate(
              logic: widget.logic,
              height: 82,
            ),
          ),

        // HEADER
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Expanded(
                    child: Text('Thư viện',
                        style: Theme.of(context).textTheme.titleLarge)),
                if (_searchQuery.isNotEmpty)
                  Text('${filteredItems.length} kết quả',
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),

        // EMPTY STATES
        if (items.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 24, left: 16, right: 16),
              child: Text('Chưa có file. Bấm nút + để thêm mp3/m4a vào app.'),
            ),
          ),

        if (items.isNotEmpty && filteredItems.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Center(
                child: Column(
                  children: [
                    const Icon(Icons.search_off_rounded, size: 48),
                    const SizedBox(height: 8),
                    Text('Không tìm thấy "$_searchQuery"',
                        style: Theme.of(context).textTheme.bodyLarge),
                  ],
                ),
              ),
            ),
          ),

        // TRACK LIST
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final t = filteredItems[index];
                final isCurrent = (currentId == t.id);
                final fav = widget.logic.favorites.contains(t.id);

                return Slidable(
                  key: ValueKey(t.id),
                  endActionPane: ActionPane(
                    motion: const DrawerMotion(),
                    children: [
                      SlidableAction(
                        onPressed: (_) async =>
                            await widget.logic.removeTrackFromApp(t.id),
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        icon: Icons.delete_rounded,
                        label: 'Xoá',
                      ),
                    ],
                  ),
                  child: Card(
                    child: ListTile(
                      onTap: () async {
                        await widget.logic.setCurrent(t.id, autoPlay: true);
                        _openNowPlaying(context, widget.logic);
                      },
                      leading: _CoverThumb(path: t.coverPath, title: t.title),
                      title: Text(t.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_trackPlaylistLabel(widget.logic, t),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // ✨ VISUALIZER giống HeroCard khi đang phát
                          if (isCurrent)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: _AudioVisualizer(
                                isPlaying: widget
                                    .logic.handler.playbackState.value.playing,
                                barColor: Color(widget.logic.settings
                                        .themeConfig.colors['visualizerBar'] ??
                                    Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withOpacity(0.7)
                                        .value),
                              ),
                            ),
                          IconButton(
                            tooltip: fav ? 'Bỏ thích' : 'Thích',
                            onPressed: () => widget.logic.toggleFavorite(t.id),
                            icon: Icon(fav
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded),
                          ),
                          _TrackMenu(logic: widget.logic, track: t),
                        ],
                      ),
                    ),
                  ),
                );
              },
              childCount: filteredItems.length,
            ),
          ),
        ),
      ],
    );
  }

  void _openNowPlaying(BuildContext context, AppLogic logic) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: Theme.of(context).bottomSheetTheme.shape,
      builder: (_) => _NowPlayingSheet(logic: logic),
    );
  }
}

/// ===============================
/// ✅ STICKY HEADER DELEGATE - ĐÃ FIX OVERFLOW
/// ===============================
class _StickyHeroDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;

  _StickyHeroDelegate({required this.child});

  @override
  double get minExtent => 132;

  @override
  double get maxExtent => 132;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(_StickyHeroDelegate oldDelegate) => true;
}

class _TrackMenu extends StatelessWidget {
  final AppLogic logic;
  final TrackRow track;

  const _TrackMenu({required this.logic, required this.track});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Menu',
      onSelected: (v) async {
        if (v == 'cover') {
          await logic.setTrackCover(track.id);
        } else if (v == 'rename') {
          final name =
              await _promptText(context, 'Sửa tên', initial: track.title);
          if (name != null) await logic.renameTrack(track.id, name);
        } else if (v == 'delete') {
          await logic.removeTrackFromApp(track.id);
        } else if (v.startsWith('addpl:')) {
          final pid = v.substring('addpl:'.length);
          await logic.addToPlaylist(pid, track.id);
        }
      },
      itemBuilder: (_) {
        final pls = logic.playlists;
        return [
          const PopupMenuItem(value: 'cover', child: Text('Thêm ảnh')),
          const PopupMenuItem(value: 'rename', child: Text('Sửa tên')),
          const PopupMenuDivider(),
          ...pls.map((pl) => PopupMenuItem(
              value: 'addpl:${pl.id}', child: Text('Thêm vào: ${pl.name}'))),
          if (pls.isNotEmpty) const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'delete',
            child: Text('Xoá khỏi app (không xoá file gốc)'),
          ),
        ];
      },
      icon: const Icon(Icons.more_vert_rounded),
    );
  }

  Future<String?> _promptText(
    BuildContext context,
    String title, {
    String initial = '',
  }) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Huỷ')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('Lưu')),
        ],
      ),
    );
  }
}

class _PinnedMusicBarDelegate extends SliverPersistentHeaderDelegate {
  final AppLogic logic;
  final double height;

  const _PinnedMusicBarDelegate({required this.logic, required this.height});

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final bg = Theme.of(context).scaffoldBackgroundColor;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: ColoredBox(
          color: bg.withOpacity(overlapsContent ? 0.18 : 0.02),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: SizedBox(
              height: 70,
              child: _FloatingHero(child: _HeroCard(logic: logic)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedMusicBarDelegate oldDelegate) {
    return oldDelegate.logic != logic || oldDelegate.height != height;
  }
}

/// ===============================
/// HERO CARD - ✅ FIX PADDING ĐỂ TRÁNH OVERFLOW
/// ===============================
class _HeroCard extends StatelessWidget {
  final AppLogic logic;
  const _HeroCard({required this.logic});

  @override
  Widget build(BuildContext context) {
    final t = logic.currentTrack;
    final title = t?.title ?? 'Chưa chọn bài';
    final artist = t == null ? '' : _trackPlaylistLabel(logic, t);
    final textSecondary = Color(
      logic.settings.themeConfig.colors['textSecondary'] ??
          Theme.of(context).textTheme.bodySmall?.color?.value ??
          Colors.white70.value,
    );

    return _GlassSurface(
      radius: 26,
      coverPath: t?.coverPath,
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: () async => await logic.playPause(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                _CoverThumb(path: t?.coverPath, title: title, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        artist.isEmpty ? 'Chạm để phát nhạc' : artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                StreamBuilder<PlaybackState>(
                  stream: logic.handler.playbackState,
                  initialData: logic.handler.playbackState.value,
                  builder: (context, snapshot) {
                    final playing = snapshot.data?.playing ?? false;

                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _AudioVisualizer(
                          isPlaying: playing,
                          barColor: Color(
                            logic.settings.themeConfig.colors['visualizerBar'] ??
                                Colors.grey.value,
                          ),
                        ),
                        SizedBox(width: playing ? 16 : 0),
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity(0.18),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.22),
                            ),
                          ),
                          child: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ===============================
/// ✨ AUDIO VISUALIZER - TO HƠN, CHỈ HIỆN KHI PHÁT NHẠC
/// ===============================
class _AudioVisualizer extends StatefulWidget {
  final bool isPlaying;
  final Color barColor;
  const _AudioVisualizer({required this.isPlaying, required this.barColor});

  @override
  State<_AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<_AudioVisualizer>
    with TickerProviderStateMixin {
  late List<AnimationController> _controllers;
  late List<Animation<double>> _animations;

  @override
  void initState() {
    super.initState();

    _controllers = List.generate(
      3,
      (index) => AnimationController(
        duration: const Duration(milliseconds: 1200),
        vsync: this,
      ),
    );

    _animations = _controllers.map((controller) {
      return Tween<double>(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: controller, curve: Curves.easeInOut),
      );
    }).toList();

    if (widget.isPlaying) {
      _startAnimations();
    }
  }

  void _startAnimations() {
    for (int i = 0; i < _controllers.length; i++) {
      Future.delayed(Duration(milliseconds: i * 300), () {
        if (mounted && widget.isPlaying) {
          _controllers[i].repeat(reverse: true);
        }
      });
    }
  }

  void _stopAnimations() {
    for (var controller in _controllers) {
      controller.stop();
      controller.value = 0.4;
    }
  }

  @override
  void didUpdateWidget(_AudioVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _startAnimations();
      } else {
        _stopAnimations();
      }
    }
  }

  @override
  void dispose() {
    for (var controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isPlaying) {
      return const SizedBox.shrink();
    }

    final barHeights = [18.0, 12.0, 20.0];

    return SizedBox(
      height: 24,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(3, (index) {
          return Padding(
            padding: EdgeInsets.only(right: index < 2 ? 4 : 0),
            child: AnimatedBuilder(
              animation: _animations[index],
              builder: (context, child) {
                return Container(
                  width: 4,
                  height: barHeights[index] * _animations[index].value,
                  decoration: BoxDecoration(
                    color: widget.barColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              },
            ),
          );
        }),
      ),
    );
  }
}

/// ===============================
/// ✨ NÚT TUA 5 GIÂY - REUSABLE WIDGET
/// ===============================
class _SeekStepButton extends StatelessWidget {
  final int seconds; // -5 = lùi, +5 = tiến
  final VoidCallback? onPressed;

  const _SeekStepButton({
    required this.seconds,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final isRewind = seconds < 0;
    final s = seconds.abs();

    IconData icon;
    if (isRewind) {
      icon = (s == 5) ? Icons.replay_5_rounded : Icons.replay_rounded;
    } else {
      icon = (s == 5) ? Icons.forward_5_rounded : Icons.forward_rounded;
    }

    return IconButton(
      tooltip: isRewind ? 'Tua lùi ${s}s' : 'Tua tới ${s}s',
      onPressed: onPressed,
      iconSize: 30,
      splashRadius: 22,
      icon: Icon(icon),
    );
  }
}

class _FavoritesPage extends StatelessWidget {
  final AppLogic logic;
  const _FavoritesPage({required this.logic});

  @override
  Widget build(BuildContext context) {
    final favTracks =
        logic.library.where((t) => logic.favorites.contains(t.id)).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text('Yêu thích', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (favTracks.isEmpty)
          const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Text('Chưa có bài yêu thích.')),
        ...favTracks.map((t) => Slidable(
              key: ValueKey('fav_${t.id}'),
              endActionPane: ActionPane(
                motion: const DrawerMotion(),
                children: [
                  SlidableAction(
                    onPressed: (_) async =>
                        await logic.removeTrackFromApp(t.id),
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    icon: Icons.delete_rounded,
                    label: 'Xoá',
                  ),
                ],
              ),
              child: Card(
                child: ListTile(
                  leading: _CoverThumb(path: t.coverPath, title: t.title),
                  title: Text(t.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_trackPlaylistLabel(logic, t),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () async {
                    await logic.setCurrent(t.id, autoPlay: true);
                    _openNowPlaying(context, logic);
                  },
                ),
              ),
            )),
      ],
    );
  }

  void _openNowPlaying(BuildContext context, AppLogic logic) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: Theme.of(context).bottomSheetTheme.shape,
      builder: (_) => _NowPlayingSheet(logic: logic),
    );
  }
}

class _PlaylistsPage extends StatefulWidget {
  final AppLogic logic;
  const _PlaylistsPage({required this.logic});

  @override
  State<_PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<_PlaylistsPage> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final logic = widget.logic;
    final query = _searchQuery.trim().toLowerCase();
    final allPlaylists = logic.playlists;
    final pls = query.isEmpty
        ? allPlaylists
        : allPlaylists.where((pl) {
            final ids = logic.playlistItems[pl.id] ?? const <String>[];
            final trackNames = ids
                .map((id) => logic.library
                    .where((t) => t.id == id)
                    .map((t) => t.title)
                    .join(' '))
                .join(' ')
                .toLowerCase();
            return pl.name.toLowerCase().contains(query) ||
                trackNames.contains(query);
          }).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
                child: Text('Danh sách phát',
                    style: Theme.of(context).textTheme.titleLarge)),
            FilledButton.tonalIcon(
              onPressed: () async {
                final name = await _promptText(context, 'Tạo playlist');
                if (name != null) await logic.createPlaylist(name);
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('Tạo'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          decoration: InputDecoration(
            hintText: 'Tìm kiếm list hoặc tên file...',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () => setState(() => _searchQuery = ''),
                  )
                : null,
          ),
          onChanged: (value) => setState(() => _searchQuery = value),
        ),
        const SizedBox(height: 8),
        if (allPlaylists.isEmpty)
          const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Text('Chưa có playlist.')),
        if (allPlaylists.isNotEmpty && pls.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Center(child: Text('Không tìm thấy "$_searchQuery"')),
          ),
        ...pls.map((pl) {
          final ids = logic.playlistItems[pl.id] ?? const <String>[];
          final segmentCount =
              pl.isSpecial ? logic.favoriteSegments.length : ids.length;

          return Slidable(
            key: ValueKey(pl.id),
            endActionPane: pl.isSpecial
                ? null
                : ActionPane(
                    motion: const DrawerMotion(),
                    children: [
                      SlidableAction(
                        onPressed: (_) async =>
                            await logic.deletePlaylist(pl.id),
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        icon: Icons.delete_rounded,
                        label: 'Xoá',
                      ),
                    ],
                  ),
            child: Card(
              child: ListTile(
                leading: Icon(pl.isSpecial
                    ? Icons.star_rounded
                    : Icons.playlist_play_rounded),
                title: Text(pl.name),
                subtitle: Text(pl.isSpecial
                    ? '$segmentCount phân đoạn'
                    : '$segmentCount bài'),
                onTap: () =>
                    _openPlaylist(context, pl.id, pl.name, pl.isSpecial),
              ),
            ),
          );
        }),
      ],
    );
  }

  Future<String?> _promptText(BuildContext context, String title) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Huỷ')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('Tạo')),
        ],
      ),
    );
  }

  void _openPlaylist(
      BuildContext context, String playlistId, String name, bool isSpecial) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: Theme.of(context).bottomSheetTheme.shape,
      builder: (_) => isSpecial
          ? _FavoriteSegmentsSheet(logic: widget.logic)
          : _PlaylistSheet(logic: widget.logic, playlistId: playlistId, name: name),
    );
  }
}

class _PlaylistSheet extends StatelessWidget {
  final AppLogic logic;
  final String playlistId;
  final String name;

  const _PlaylistSheet(
      {required this.logic, required this.playlistId, required this.name});

  @override
  Widget build(BuildContext context) {
    final ids = logic.playlistItems[playlistId] ?? const <String>[];
    final tracks =
        ids.map((id) => logic.library.firstWhere((t) => t.id == id)).toList();

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  _handleBar(context),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                          child: Text(name,
                              style: Theme.of(context).textTheme.titleLarge)),
                      IconButton(
                        tooltip: 'Phát danh sách',
                        icon: const Icon(Icons.play_arrow_rounded),
                        onPressed: tracks.isEmpty
                            ? null
                            : () async {
                                await logic.playPlaylist(playlistId);
                                Navigator.pop(context);
                              },
                      ),
                      IconButton(
                        tooltip: 'Thêm file vào playlist',
                        icon: const Icon(Icons.add_rounded),
                        onPressed: () async =>
                            await logic.importIntoPlaylist(playlistId),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                itemCount: tracks.length,
                itemBuilder: (_, i) {
                  final t = tracks[i];
                  return Slidable(
                    key: ValueKey('pli_${t.id}'),
                    endActionPane: ActionPane(
                      motion: const DrawerMotion(),
                      children: [
                        SlidableAction(
                          onPressed: (_) async =>
                              await logic.removeFromPlaylist(
                            playlistId,
                            t.id,
                          ),
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                          icon: Icons.remove_circle_outline_rounded,
                          label: 'Bỏ',
                        ),
                      ],
                    ),
                    child: Card(
                      child: ListTile(
                        leading: _CoverThumb(path: t.coverPath, title: t.title),
                        title: Text(t.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(_trackPlaylistLabel(logic, t),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () async {
                          await logic.playPlaylist(
                            playlistId,
                            startTrackId: t.id,
                            autoPlay: true,
                          );
                          Navigator.pop(context);
                          _openNowPlaying(context);
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _handleBar(BuildContext context) {
    final c = Color(
        logic.settings.themeConfig.colors['divider'] ?? Colors.white24.value);
    return Container(
      width: 40,
      height: 4,
      decoration:
          BoxDecoration(color: c, borderRadius: BorderRadius.circular(999)),
    );
  }

  void _openNowPlaying(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: Theme.of(context).bottomSheetTheme.shape,
      builder: (_) => _NowPlayingSheet(logic: logic),
    );
  }
}


class _FavoriteSegmentsSheet extends StatelessWidget {
  final AppLogic logic;

  const _FavoriteSegmentsSheet({required this.logic});

  @override
  Widget build(BuildContext context) {
    final segments = logic.favoriteSegments;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.star_rounded),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('Phân đoạn yêu thích',
                        style: Theme.of(context).textTheme.titleLarge)),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (segments.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text(
                    'Chưa có phân đoạn yêu thích.\nMở file nhạc và tạo phân đoạn từ nút "Now Playing".'),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: segments.length,
                itemBuilder: (_, i) {
                  final seg = segments[i];
                  final track = logic.library.firstWhere(
                    (t) => t.id == seg.trackId,
                    orElse: () => TrackRow(
                      id: '',
                      title: 'Unknown',
                      artist: '',
                      localPath: '',
                      signature: '',
                      coverPath: null,
                      durationMs: 0,
                      createdAt: 0,
                    ),
                  );

                  return Slidable(
                    key: ValueKey('seg_${seg.id}'),
                    endActionPane: ActionPane(
                      motion: const DrawerMotion(),
                      children: [
                        SlidableAction(
                          onPressed: (_) async =>
                              await logic.deleteFavoriteSegment(seg.id),
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          icon: Icons.delete_rounded,
                          label: 'Xoá',
                        ),
                      ],
                    ),
                    child: Card(
                      child: ListTile(
                        leading: _CoverThumb(
                            path: track.coverPath, title: track.title),
                        title: Text(seg.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${track.title} • ${_fmtMs(seg.startMs)} - ${_fmtMs(seg.endMs)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () async {
                          await logic.playSegment(seg, autoPlay: true);
                          Navigator.pop(context);
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

/// ===============================
/// SETTINGS - THÊM “THEME A→Z” (đổi mọi token màu + font)
/// GIỮ NGUYÊN layout phần Setting hiện có (theme mode + title),
/// chỉ THÊM 1 Card mới phía dưới.
/// ===============================
class _SettingsPage extends StatefulWidget {
  final AppLogic logic;
  const _SettingsPage({required this.logic});

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late final TextEditingController _titleCtrl;

  // NEW: font family + sliders
  late final TextEditingController _fontCtrl;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.logic.settings.appTitle);
    _fontCtrl = TextEditingController(
        text: widget.logic.settings.themeConfig.fontFamily ?? '');
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _fontCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logic = widget.logic;
    final cfg = logic.settings.themeConfig;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text('Setting', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),

        // Theme mode card (giữ nguyên)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.dark_mode_rounded),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text('Chế độ giao diện',
                            style: Theme.of(context).textTheme.titleMedium)),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _chip(context,
                        label: 'Tối',
                        selected: logic.settings.themeMode == ThemeMode.dark,
                        onTap: () => logic.setThemeMode(ThemeMode.dark)),
                    _chip(context,
                        label: 'Sáng',
                        selected: logic.settings.themeMode == ThemeMode.light,
                        onTap: () => logic.setThemeMode(ThemeMode.light)),
                    _chip(context,
                        label: 'System',
                        selected: logic.settings.themeMode == ThemeMode.system,
                        onTap: () => logic.setThemeMode(ThemeMode.system)),
                  ],
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        // App title card (giữ nguyên)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.title_rounded),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text('Đổi title app',
                            style: Theme.of(context).textTheme.titleMedium)),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _titleCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Nhập title...',
                  ),
                  onSubmitted: (v) => logic.setAppTitle(v),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                      onPressed: () => logic.setAppTitle(_titleCtrl.text),
                      child: const Text('Lưu')),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.backup_rounded),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Backup & Restore',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  icon: const Icon(Icons.archive_rounded),
                  label: const Text('Xuất backup (.zip)'),
                  onPressed: () async {
                    final path = await widget.logic.exportLibraryToZip();
                    if (!context.mounted) return;

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(path ?? 'Lỗi')),
                    );
                  },
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Import backup'),
                  onPressed: () async {
                    final err = await widget.logic.importLibraryFromZip();
                    if (!context.mounted) return;

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(err ?? 'Khôi phục thành công'),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        // NEW: Theme A→Z card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.palette_rounded),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Màu sắc & Font (A → Z)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final useDark =
                            (logic.settings.themeMode == ThemeMode.dark) ||
                                (logic.settings.themeMode == ThemeMode.system);
                        await logic.resetThemeToDefaults(darkDefault: useDark);
                        // update local font controller
                        _fontCtrl.text =
                            logic.settings.themeConfig.fontFamily ?? '';
                        setState(() {});
                      },
                      child: const Text('Reset'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Font family input
                Row(
                  children: [
                    const Icon(Icons.font_download_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _fontCtrl,
                        decoration: const InputDecoration(
                          hintText: 'Font family (để trống = mặc định)',
                        ),
                        onSubmitted: (v) async {
                          await logic.setFontFamily(v);
                          setState(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () async {
                        await logic.setFontFamily(_fontCtrl.text);
                        setState(() {});
                      },
                      child: const Text('Áp'),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Header scale
                _scaleRow(
                  context,
                  icon: Icons.text_fields_rounded,
                  title: 'Header scale',
                  value: (cfg.headerScale ?? 1.0).clamp(0.8, 1.6),
                  onChanged: (v) async {
                    await logic.setHeaderScale(v);
                    setState(() {});
                  },
                ),
                const SizedBox(height: 8),

                // Body scale
                _scaleRow(
                  context,
                  icon: Icons.subject_rounded,
                  title: 'Body scale',
                  value: (cfg.bodyScale ?? 1.0).clamp(0.8, 1.6),
                  onChanged: (v) async {
                    await logic.setBodyScale(v);
                    setState(() {});
                  },
                ),

                const SizedBox(height: 14),
                Divider(color: Theme.of(context).dividerTheme.color),

                const SizedBox(height: 10),
                Text(
                  'Đổi màu từng phần tử (nhấn vào ô màu):',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),

                // Grid color tokens
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: ThemeConfig.keys.map((k) {
                    final col =
                        Color(cfg.colors[k] ?? Colors.transparent.value);
                    return _ColorToken(
                      label: k,
                      color: col,
                      onTap: () async {
                        final picked = await _pickColor(context, col);
                        if (picked != null) {
                          await logic.setThemeColor(k, picked);
                          setState(() {});
                        }
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _scaleRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(title)),
        SizedBox(
          width: 160,
          child: Slider(
            min: 0.8,
            max: 1.6,
            value: value,
            onChanged: (v) => onChanged(v),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 42,
          child: Text(
            value.toStringAsFixed(2),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Future<Color?> _pickColor(BuildContext context, Color initial) async {
    // UI tối giản: RGB sliders + preview (không thêm package, giữ project gọn)
    double r = initial.red.toDouble();
    double g = initial.green.toDouble();
    double b = initial.blue.toDouble();
    double a = initial.alpha.toDouble();

    return showDialog<Color>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSt) {
          final col =
              Color.fromARGB(a.round(), r.round(), g.round(), b.round());
          return AlertDialog(
            title: const Text('Chọn màu'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: col,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                ),
                const SizedBox(height: 10),
                _rgbSlider(ctx, 'A', a, (v) => setSt(() => a = v)),
                _rgbSlider(ctx, 'R', r, (v) => setSt(() => r = v)),
                _rgbSlider(ctx, 'G', g, (v) => setSt(() => g = v)),
                _rgbSlider(ctx, 'B', b, (v) => setSt(() => b = v)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Huỷ'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, col),
                child: const Text('Chọn'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _rgbSlider(BuildContext context, String label, double v,
      ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 16, child: Text(label)),
        Expanded(
          child: Slider(
            min: 0,
            max: 255,
            value: v.clamp(0, 255),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            v.round().toString(),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent),
          color: selected
              ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
              : Theme.of(context).cardColor,
        ),
        child: Text(label),
      ),
    );
  }
}

/// Token tile
class _ColorToken extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ColorToken({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).dividerColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 152,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: border),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const Icon(Icons.edit_rounded, size: 16),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingSheet extends StatefulWidget {
  final AppLogic logic;
  const _NowPlayingSheet({required this.logic});

  @override
  State<_NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends State<_NowPlayingSheet> {
  double? _dragValue;
  bool _isDragging = false;

  int? _trimStartMs;
  int? _trimEndMs;

  void _openTrimPopup(BuildContext context, TrackRow track, AppLogic logic) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: Theme.of(context).bottomSheetTheme.shape,
      builder: (_) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).dividerColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.cut_rounded),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Cắt phân đoạn yêu thích',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildTrimControls(context, track, logic),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logic = widget.logic;
    final track = logic.currentTrack;

    final title = track?.title ?? 'Chưa chọn bài';
    final artist = track == null ? '' : _trackPlaylistLabel(logic, track);
    final duration = logic.currentDuration;
    final playing = logic.handler.playbackState.value.playing;

    final fav = track != null && logic.favorites.contains(track.id);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  _handleBar(context),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Đang phát',
                            style: Theme.of(context).textTheme.titleLarge),
                      ),
                      if (track != null)
                        IconButton(
                          tooltip: 'Cắt phân đoạn',
                          onPressed: () =>
                              _openTrimPopup(context, track, logic),
                          icon: const Icon(Icons.cut_rounded),
                        ),
                      if (track != null) _TrackMenu(logic: logic, track: track),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  children: [
                    _GlassSurface(
                      radius: 34,
                      coverPath: track?.coverPath,
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                      child: Column(
                        children: [
                    GestureDetector(
                      onHorizontalDragEnd: (d) async {
                        final v = d.primaryVelocity ?? 0;
                        if (v < -200) {
                          await logic.next();
                        } else if (v > 200) {
                          await logic.previous();
                        }
                      },
                      child: _BigCover(path: track?.coverPath, title: title),
                    ),
                    const SizedBox(height: 12),
                    Text(title,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(artist,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Color(logic.settings.themeConfig
                                    .colors['textSecondary'] ??
                                Colors.white70.value)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 12),
                    _buildSeekBar(duration),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'Previous',
                          onPressed: () async => await logic.previous(),
                          iconSize: 32,
                          icon: const Icon(Icons.skip_previous_rounded),
                        ),
                        const SizedBox(width: 4),
                        _SeekStepButton(
                          seconds: -5,
                          onPressed: track == null
                              ? null
                              : () => widget.logic
                                  .seekRelative(const Duration(seconds: -5)),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.all(16),
                            shape: const CircleBorder(),
                          ),
                          onPressed: () async => await logic.playPause(),
                          child: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 32),
                        ),
                        const SizedBox(width: 8),
                        _SeekStepButton(
                          seconds: 5,
                          onPressed: track == null
                              ? null
                              : () => widget.logic
                                  .seekRelative(const Duration(seconds: 5)),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Next',
                          onPressed: () async => await logic.next(),
                          iconSize: 32,
                          icon: const Icon(Icons.skip_next_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: fav ? 'Bỏ thích' : 'Thích',
                          onPressed: track == null
                              ? null
                              : () => logic.toggleFavorite(track.id),
                          icon: Icon(fav
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded),
                          color: fav
                              ? Theme.of(context).colorScheme.primary
                              : Color(logic.settings.themeConfig
                                      .colors['iconSecondary'] ??
                                  Colors.white70.value),
                        ),
                        IconButton(
                          tooltip: 'Loop one',
                          onPressed: () async => await logic.toggleLoopOne(),
                          icon: Icon(Icons.repeat_one_rounded,
                              color: logic.loopOne
                                  ? Theme.of(context).colorScheme.primary
                                  : Color(logic.settings.themeConfig
                                          .colors['iconSecondary'] ??
                                      Colors.white70.value)),
                        ),
                      ],
                    ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrimControls(
      BuildContext context, TrackRow track, AppLogic logic) {
    final hasStart = _trimStartMs != null;
    final hasEnd = _trimEndMs != null;

    return Card(
      color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cut_rounded, size: 18),
                const SizedBox(width: 6),
                Text('Tạo phân đoạn yêu thích',
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () {
                      setState(() {
                        _trimStartMs = logic.position.inMilliseconds;
                      });
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.start_rounded, size: 18),
                        const SizedBox(height: 4),
                        Text(
                          hasStart ? _fmtMs(_trimStartMs!) : 'Đánh dấu đầu',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () {
                      setState(() {
                        _trimEndMs = logic.position.inMilliseconds;
                      });
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.stop_rounded, size: 18),
                        const SizedBox(height: 4),
                        Text(
                          hasEnd ? _fmtMs(_trimEndMs!) : 'Đánh dấu cuối',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (hasStart || hasEnd) const SizedBox(height: 8),
            if (hasStart || hasEnd)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _trimStartMs = null;
                        _trimEndMs = null;
                      });
                    },
                    icon: const Icon(Icons.clear_rounded, size: 16),
                    label: const Text('Xoá'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: (hasStart && hasEnd)
                        ? () => _saveSegment(context, track, logic)
                        : null,
                    icon: const Icon(Icons.save_rounded, size: 16),
                    label: const Text('Lưu'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _saveSegment(
      BuildContext context, TrackRow track, AppLogic logic) async {
    if (_trimStartMs == null || _trimEndMs == null) return;

    final start = _trimStartMs!;
    final end = _trimEndMs!;

    if (start >= end) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Điểm đầu phải nhỏ hơn điểm cuối')),
      );
      return;
    }

    final nameCtrl =
        TextEditingController(text: 'Đoạn ${_fmtMs(start)} - ${_fmtMs(end)}');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Tên phân đoạn'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'VD: Solo hay nhất',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final name = nameCtrl.text.trim();
      if (name.isEmpty) return;

      await logic.addFavoriteSegment(
        trackId: track.id,
        name: name,
        startMs: start,
        endMs: end,
      );

      setState(() {
        _trimStartMs = null;
        _trimEndMs = null;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã lưu phân đoạn yêu thích')),
        );
      }
    }
  }

  Widget _buildSeekBar(Duration duration) {
    final durMs = math.max(duration.inMilliseconds, 1).toDouble();

    return StreamBuilder<Duration>(
      stream: widget.logic.handler.player.positionStream,
      builder: (_, snap) {
        final dragging = _isDragging && _dragValue != null;

        final pos = dragging
            ? Duration(milliseconds: _dragValue!.round())
            : (snap.data ?? Duration.zero);

        final sliderValue =
            dragging ? _dragValue! : pos.inMilliseconds.toDouble();

        final clamped = sliderValue.clamp(0.0, durMs);

        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3.0,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14.0),
              ),
              child: Slider(
                min: 0,
                max: durMs,
                value: clamped,
                onChangeStart: (v) {
                  setState(() {
                    _isDragging = true;
                    _dragValue = v;
                  });
                },
                onChanged: (v) {
                  setState(() {
                    _dragValue = v;
                  });
                },
                onChangeEnd: (v) async {
                  await widget.logic.seek(Duration(milliseconds: v.round()));
                  setState(() {
                    _isDragging = false;
                    _dragValue = null;
                  });
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _fmt(Duration(milliseconds: clamped.round())),
                    style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    _fmt(duration),
                    style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _handleBar(BuildContext context) {
    final c = Theme.of(context).dividerColor;
    return Container(
      width: 40,
      height: 4,
      decoration:
          BoxDecoration(color: c, borderRadius: BorderRadius.circular(999)),
    );
  }

  String _fmt(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    return _fmt(d);
  }
}

class _CoverThumb extends StatelessWidget {
  final String? path;
  final String title;
  final double size;

  const _CoverThumb({required this.path, required this.title, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final has = path != null && File(path!).existsSync();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: size,
        height: size,
        color: primary.withOpacity(0.14),
        child: has
            ? Image.file(File(path!), fit: BoxFit.cover)
            : Center(
                child: Text(
                  title.isEmpty ? '?' : title.characters.first.toUpperCase(),
                  style: TextStyle(
                      fontSize: size * 0.38,
                      fontWeight: FontWeight.w700,
                      color: primary),
                ),
              ),
      ),
    );
  }
}

class _FloatingHero extends StatelessWidget {
  final Widget child;
  const _FloatingHero({required this.child});

  @override
  Widget build(BuildContext context) {
    // shadow color có token nhưng không ép vì UI này là "floating",
    // vẫn lấy từ themeConfig đã map vào CardTheme.shadowColor.
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            blurRadius: 22,
            spreadRadius: 2,
            offset: const Offset(0, 10),
            color: Theme.of(context).cardTheme.shadowColor ??
                Colors.black.withOpacity(0.45),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _BigCover extends StatelessWidget {
  final String? path;
  final String title;

  const _BigCover({required this.path, required this.title});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final has = path != null && File(path!).existsSync();

    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: has
            ? Image.file(File(path!), fit: BoxFit.cover)
            : Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      primary.withOpacity(0.34),
                      primary.withOpacity(0.08)
                    ],
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  title.isEmpty ? '♪' : title.characters.first.toUpperCase(),
                  style: TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.w800,
                      color: primary),
                ),
              ),
      ),
    );
  }
}

// main.dart



Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // FIX: sqflite on desktop (Windows/macOS/Linux) needs FFI factory
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final logic = AppLogic();
  await logic.init();

  runApp(AppRoot(logic: logic));
}
