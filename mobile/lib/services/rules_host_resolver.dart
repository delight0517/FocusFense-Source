import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import '../platform/rules_platform.dart';

/// Where `rules_v1.json` and `pending_share_hosts.json` live.
///
/// **유료 Apple Developer / App Group 없음:** 기본값은 로컬 시뮬 폴더(앱 샌드박스 문서 디렉터리).
/// 실제 Safari 확장은 나중에 **진짜 App Group**에 쓸 때만 네이티브 채널을 사용합니다.
final class RulesHostResolver {
  RulesHostResolver._();

  static final RulesHostResolver instance = RulesHostResolver._();

  static const String _prefKey = 'rules_use_local_simulation';

  /// Subdirectory under app documents (simulates shared container).
  static const String simulatedContainerDirName = 'SimulatedAppGroup';

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  /// iOS가 아니면 항상 로컬 시뮬(네이티브 App Group 채널 없음).
  bool get _platformForcesSimulation => !Platform.isIOS;

  /// 기본 `true`: 유료 계정 없이도 앱 전체 플로우를 연습할 수 있게.
  Future<bool> useLocalSimulation() async {
    if (_platformForcesSimulation) {
      return true;
    }
    final prefs = await _prefs();
    return prefs.getBool(_prefKey) ?? true;
  }

  Future<void> setUseLocalSimulation(bool value) async {
    final prefs = await _prefs();
    await prefs.setBool(_prefKey, value);
  }

  Future<String> simulationDirectory() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(doc.path, simulatedContainerDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// 디렉터리 경로(표시·파일 I/O용). 시뮬 ON이면 시뮬 폴더, OFF이면 네이티브 App Group(실패 시 예외).
  Future<String> resolvedDirectory(RulesPlatform platform) async {
    if (_platformForcesSimulation || await useLocalSimulation()) {
      return simulationDirectory();
    }
    final native = await platform.appGroupPath();
    if (native == null || native.isEmpty) {
      throw StateError(
        'App Group 컨테이너를 열 수 없습니다. 설정에서 「로컬 시뮬레이션」을 켜거나, '
        'Apple Developer 등록 후 Xcode에서 App Groups를 구성하세요.',
      );
    }
    return native;
  }

  /// 규칙 JSON 저장: 시뮬이면 Dart 파일 쓰기, 아니면 iOS 네이티브 쓰기.
  Future<String?> writeRulesJson(RulesPlatform platform, String json) async {
    if (_platformForcesSimulation || await useLocalSimulation()) {
      final dir = await simulationDirectory();
      final file = File(p.join(dir, kRulesFileName));
      await file.writeAsString(json);
      return file.path;
    }
    return platform.writeRulesJson(json);
  }

  /// App Group 경로 조회(설정 화면용). 시뮬 모드면 시뮬 경로 문자열, 아니면 네이티브.
  Future<String?> pathForDisplay(RulesPlatform platform) async {
    try {
      return await resolvedDirectory(platform);
    } catch (_) {
      return null;
    }
  }
}
