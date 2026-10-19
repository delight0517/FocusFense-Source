import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _ffiInited = false;

/// Android / iOS(아이폰)는 sqflite 네이티브 구현을 쓴다.
/// **Windows · Linux · macOS(Flutter 데스크톱)** 는 `openDatabase` 전에 FFI로
/// `databaseFactory`를 지정해야 한다. (그렇지 않으면 `databaseFactory not initialized`)
///
/// [sqfliteFfiInit]은 프로세스당 한 번이면 충분하다.
/// `databaseFactory`는 **이미 `databaseFactoryFfi`이면 다시 넣지 않는다.**
/// 매번 할당하면 sqflite가 “factory 교체” 경고를 반복 출력한다.
void ensureSqfliteDesktopInitialized() {
  if (kIsWeb) return;
  if (Platform.isAndroid || Platform.isIOS) return;
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
  if (!_ffiInited) {
    sqfliteFfiInit();
    _ffiInited = true;
  }
  try {
    if (identical(databaseFactory, databaseFactoryFfi)) {
      return;
    }
  } on StateError {
    // `databaseFactory not initialized` — 아래에서 FFI로 설정
  }
  databaseFactory = databaseFactoryFfi;
}
