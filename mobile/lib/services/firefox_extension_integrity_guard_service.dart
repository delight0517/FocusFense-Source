import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'firefox_xpi_packager.dart';
import 'windows_extension_guard_service.dart';

/// Guards against the Firefox extension silently regressing from
/// **AMO-signed** back to **unsigned** (which Firefox Release refuses to
/// load at all — see `docs/WINDOWS_FIREFOX_PLUGIN_BLUEPRINT.md`).
///
/// **Why this exists.** Getting AMO signing working (2026-07-03) required:
/// a distinctive `gecko.id` (a collision on the generic `@local` suffix
/// silently 403'd every submission), a `data_collection_permissions`
/// manifest field, and an actual Mozilla review pass. None of that is
/// re-derivable automatically — if the bundled signed XPI
/// (`assets/browser_extensions/firefox/sixvpn_blocker_signed.xpi`) is ever
/// missing, renamed, or stale relative to the source files, the packager
/// falls back to packing an **unsigned** XPI with zero error (see
/// [FirefoxXpiPackager.ensureProgramDataXpi]) — Firefox then simply never
/// loads the extension, with no crash and no obvious symptom. This is
/// exactly the "AI 작업 중 손상" pattern the user flagged: an edit to
/// `assets/browser_extensions/firefox/*` (by a human or an AI session)
/// that isn't followed by a re-sign silently ships a dead extension.
///
/// This guard makes that failure LOUD instead of silent:
///  1. Confirms the bundled signed XPI asset still exists.
///  2. Confirms it's actually signed (Mozilla's `META-INF/mozilla.rsa` /
///     `cose.sig` markers present in the zip's local file headers).
///  3. Confirms `manifest.json`'s gecko id still matches
///     [kFirefoxExtensionId] — a rename in one place without the other is
///     exactly how the id collision happened the first time.
///  4. Compares current source file hashes against the pinned snapshot
///     from the moment of the last successful AMO signing
///     (`signed_source_snapshot.json`) — if they differ, the bundled
///     "signed" XPI is running **stale code**, silently. This is not
///     auto-fixable (only a real AMO resubmission can fix it) but it must
///     be surfaced clearly rather than discovered by accident.
///  5. Confirms the ProgramData copy matches the selected approved signed
///     release (a pinned AMO download or the bundled fallback). Recovery uses
///     that same selection so an approved update is not reverted next tick.
final class FirefoxExtensionIntegrityGuardService {
  FirefoxExtensionIntegrityGuardService._();
  static final FirefoxExtensionIntegrityGuardService instance =
      FirefoxExtensionIntegrityGuardService._();

  static const String kSnapshotAsset =
      'assets/browser_extensions/firefox/signed_source_snapshot.json';
  static const String kSourceDir = 'assets/browser_extensions/firefox';

  bool get isSupported => Platform.isWindows;

  FirefoxIntegrityReport? _lastReport;
  FirefoxIntegrityReport? get lastReport => _lastReport;

  /// Full check — cheap (a few asset reads + hashing, no process spawn).
  /// Safe to call at boot and on a multi-minute timer.
  Future<FirefoxIntegrityReport> verify() async {
    final List<String> problems = <String>[];
    bool signedAssetPresent = false;
    bool signedAssetIsSigned = false;
    bool manifestIdMatches = false;
    bool sourceMatchesSnapshot = false;
    bool deployedMatchesBundled = false;

    Uint8List? bundledXpiBytes;
    try {
      bundledXpiBytes = await FirefoxXpiPackager.instance.trustedSignedBytes();
      signedAssetPresent = true;
    } catch (e) {
      problems.add(
        '번들된 서명 XPI가 없음(${FirefoxXpiPackager.kBundledSignedAsset}) — '
        '다음 빌드부터 Firefox 확장이 서명 안 된 상태로 되돌아갑니다. '
        'Firefox Release는 서명 안 된 확장을 절대 로드하지 않습니다.',
      );
    }

    if (bundledXpiBytes != null) {
      signedAssetIsSigned = _xpiBytesLookSigned(bundledXpiBytes);
      if (!signedAssetIsSigned) {
        problems.add(
          '번들된 XPI에 Mozilla 서명 마커(META-INF)가 없음 — 서명 안 된 파일이 '
          '실수로 서명본 자리에 들어간 것으로 보입니다.',
        );
      }
    }

    try {
      final String manifestRaw = await rootBundle.loadString(
        '$kSourceDir/manifest.json',
      );
      final Map<String, dynamic> manifest =
          jsonDecode(manifestRaw) as Map<String, dynamic>;
      final String? id =
          (manifest['browser_specific_settings']
                  as Map<String, dynamic>?)?['gecko']?['id']
              as String?;
      manifestIdMatches = id == kFirefoxExtensionId;
      if (!manifestIdMatches) {
        problems.add(
          'manifest.json의 gecko id("$id")가 코드 상수 kFirefoxExtensionId'
          '("$kFirefoxExtensionId")와 다릅니다 — 어느 한쪽만 바뀐 것으로 보입니다. '
          '이 불일치가 처음 AMO 403 오류(다른 계정이 소유한 ID와 충돌)의 원인이었습니다.',
        );
      }
    } catch (e) {
      problems.add('manifest.json을 읽을 수 없음: $e');
    }

    try {
      final String snapshotRaw = await rootBundle.loadString(kSnapshotAsset);
      final Map<String, dynamic> snapshot =
          jsonDecode(snapshotRaw) as Map<String, dynamic>;
      final Map<String, dynamic> pinnedHashes =
          (snapshot['sourceHashes'] as Map<String, dynamic>?) ??
          <String, dynamic>{};
      final List<String> drifted = <String>[];
      for (final MapEntry<String, dynamic> entry in pinnedHashes.entries) {
        try {
          final ByteData data = await rootBundle.load(
            '$kSourceDir/${entry.key}',
          );
          final Uint8List bytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          final String actual = sha256Hex(bytes);
          if (actual != entry.value) drifted.add(entry.key);
        } catch (_) {
          drifted.add('${entry.key} (읽기 실패)');
        }
      }
      sourceMatchesSnapshot = drifted.isEmpty;
      if (!sourceMatchesSnapshot) {
        problems.add(
          'Firefox 확장 소스가 마지막 서명(v${snapshot['signedVersion']}) 이후 '
          '변경됨: ${drifted.join(", ")} — 지금 배포되는 서명 XPI는 이 변경사항을 '
          '반영하지 못합니다. 반드시 AMO에 새 버전으로 재제출·재서명해야 최신 '
          '코드가 Firefox에서 실제로 동작합니다. (docs/WINDOWS_FIREFOX_PLUGIN_BLUEPRINT.md 참고)',
        );
      }
    } catch (e) {
      problems.add('서명 스냅샷(signed_source_snapshot.json)을 읽을 수 없음: $e');
    }

    if (bundledXpiBytes != null) {
      try {
        final File deployed = File(FirefoxXpiPackager.programDataXpiPath);
        if (await deployed.exists()) {
          final List<int> deployedBytes = await deployed.readAsBytes();
          deployedMatchesBundled = _bytesEqual(deployedBytes, bundledXpiBytes);
          if (!deployedMatchesBundled) {
            problems.add(
              'ProgramData에 배포된 XPI가 선택된 승인 서명본과 다름 — 서명 안 된 버전으로 '
              '되돌아갔을 수 있습니다. 자동 복구를 시도합니다.',
            );
          }
        }
      } catch (_) {}
    }

    final FirefoxIntegrityReport report = FirefoxIntegrityReport(
      signedAssetPresent: signedAssetPresent,
      signedAssetIsSigned: signedAssetIsSigned,
      manifestIdMatches: manifestIdMatches,
      sourceMatchesSnapshot: sourceMatchesSnapshot,
      deployedMatchesBundled: deployedMatchesBundled,
      problems: problems,
      checkedAt: DateTime.now(),
    );
    _lastReport = report;

    if (problems.isNotEmpty) {
      AppLogger.instance.warn(
        'firefox_integrity_guard: ${problems.length}개 문제 발견 — '
        '${problems.join(" | ")}',
      );
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.protection,
        message:
            'Firefox 확장 무결성 경고: ${problems.first}'
            '${problems.length > 1 ? " 외 ${problems.length - 1}건" : ""}',
        level: 'warn',
        debounceKey: 'firefox_integrity_guard',
      );
    }

    return report;
  }

  /// If ProgramData diverged from the selected approved signed release,
  /// re-copy that selected release. Cannot fix a missing bundled
  /// asset or stale source (those need a real re-sign) — only surfaces
  /// them loudly via [verify].
  Future<bool> healIfNeeded() async {
    final FirefoxIntegrityReport report = _lastReport ?? await verify();
    if (!report.signedAssetPresent || !report.signedAssetIsSigned) {
      return false; // nothing to heal from — the source of truth itself is broken.
    }
    if (report.deployedMatchesBundled) return true; // already healthy.

    try {
      final bytes = await FirefoxXpiPackager.instance.trustedSignedBytes();
      final Directory dir = Directory(FirefoxXpiPackager.programDataFirefoxDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final File dest = File(FirefoxXpiPackager.programDataXpiPath);
      await dest.writeAsBytes(bytes, flush: true);
      AppLogger.instance.info(
        'firefox_integrity_guard: healed — re-copied signed XPI to ${dest.path}',
      );
      return true;
    } catch (e) {
      AppLogger.instance.error(
        'firefox_integrity_guard: heal failed',
        error: e,
      );
      return false;
    }
  }

  /// True if the zip's local file headers contain Mozilla's signing
  /// markers. Local (uncompressed) file *names* in a zip are always stored
  /// as plain bytes in each entry's header, so a raw substring search is a
  /// reliable, dependency-free way to confirm signing without a zip parser.
  bool _xpiBytesLookSigned(Uint8List bytes) {
    const List<String> markers = <String>[
      'META-INF/mozilla.rsa',
      'META-INF/mozilla.sf',
      'META-INF/cose.sig',
    ];
    final String asLatin1 = String.fromCharCodes(bytes);
    return markers.any(asLatin1.contains);
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Minimal dependency-free SHA-256 hex digest (matches Python's
/// `hashlib.sha256(...).hexdigest()` used to build the pinned snapshot).
String sha256Hex(List<int> bytes) {
  return _Sha256().convert(bytes);
}

/// Tiny self-contained SHA-256 — avoids adding `crypto` as a new dependency
/// just for this one integrity check.
final class _Sha256 {
  static const List<int> _k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  String convert(List<int> data) {
    final List<int> msg = List<int>.from(data);
    final int bitLen = msg.length * 8;
    msg.add(0x80);
    while (msg.length % 64 != 56) {
      msg.add(0);
    }
    for (int i = 7; i >= 0; i--) {
      msg.add((bitLen >> (i * 8)) & 0xff);
    }

    final List<int> h = <int>[
      0x6a09e667,
      0xbb67ae85,
      0x3c6ef372,
      0xa54ff53a,
      0x510e527f,
      0x9b05688c,
      0x1f83d9ab,
      0x5be0cd19,
    ];

    int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

    for (int chunkStart = 0; chunkStart < msg.length; chunkStart += 64) {
      final List<int> w = List<int>.filled(64, 0);
      for (int i = 0; i < 16; i++) {
        final int o = chunkStart + i * 4;
        w[i] =
            (msg[o] << 24) |
            (msg[o + 1] << 16) |
            (msg[o + 2] << 8) |
            msg[o + 3];
      }
      for (int i = 16; i < 64; i++) {
        final int s0 =
            rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final int s1 =
            rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }

      int a = h[0], b = h[1], c = h[2], d = h[3];
      int e = h[4], f = h[5], g = h[6], hh = h[7];

      for (int i = 0; i < 64; i++) {
        final int s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        final int ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final int temp1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
        final int s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        final int maj = (a & b) ^ (a & c) ^ (b & c);
        final int temp2 = (s0 + maj) & 0xffffffff;

        hh = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }

      h[0] = (h[0] + a) & 0xffffffff;
      h[1] = (h[1] + b) & 0xffffffff;
      h[2] = (h[2] + c) & 0xffffffff;
      h[3] = (h[3] + d) & 0xffffffff;
      h[4] = (h[4] + e) & 0xffffffff;
      h[5] = (h[5] + f) & 0xffffffff;
      h[6] = (h[6] + g) & 0xffffffff;
      h[7] = (h[7] + hh) & 0xffffffff;
    }

    final StringBuffer sb = StringBuffer();
    for (final int v in h) {
      sb.write(v.toRadixString(16).padLeft(8, '0'));
    }
    return sb.toString();
  }
}

class FirefoxIntegrityReport {
  const FirefoxIntegrityReport({
    required this.signedAssetPresent,
    required this.signedAssetIsSigned,
    required this.manifestIdMatches,
    required this.sourceMatchesSnapshot,
    required this.deployedMatchesBundled,
    required this.problems,
    required this.checkedAt,
  });

  final bool signedAssetPresent;
  final bool signedAssetIsSigned;
  final bool manifestIdMatches;
  final bool sourceMatchesSnapshot;
  final bool deployedMatchesBundled;
  final List<String> problems;
  final DateTime checkedAt;

  bool get healthy => problems.isEmpty;
}
