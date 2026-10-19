import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';

/// Errors deliberately exclude credentials, authorization and remote bodies.
class MozillaSigningException implements Exception {
  const MozillaSigningException(this.code, {this.httpStatus});
  final String code;
  final int? httpStatus;
  @override
  String toString() =>
      'MozillaSigningException($code${httpStatus == null ? '' : ', HTTP $httpStatus'})';
}

class MozillaSigningResponse {
  const MozillaSigningResponse(this.statusCode, this.body, {this.location});
  final int statusCode;
  final List<int> body;
  final String? location;
}

/// One request only: implementations must not automatically follow redirects.
abstract interface class MozillaSigningTransport {
  Future<MozillaSigningResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    List<int>? body,
  });
}

class MozillaHttpSigningTransport implements MozillaSigningTransport {
  MozillaHttpSigningTransport({HttpClient? client})
    : _client = client ?? HttpClient();
  final HttpClient _client;
  @override
  Future<MozillaSigningResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    List<int>? body,
  }) async {
    try {
      final request = await _client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (body != null) request.add(body);
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        bytes.add(chunk);
        if (bytes.length > MozillaSigningClient.maxPackageBytes) {
          throw const MozillaSigningException('response_too_large');
        }
      }
      return MozillaSigningResponse(
        response.statusCode,
        bytes.takeBytes(),
        location: response.headers.value(HttpHeaders.locationHeader),
      );
    } on MozillaSigningException {
      rethrow;
    } catch (_) {
      throw const MozillaSigningException('network_unavailable');
    }
  }

  void close() => _client.close(force: true);
}

class MozillaSigningReceipt {
  const MozillaSigningReceipt({required this.versionId, required this.version});
  final int versionId;
  final String version;
  int get amoVersionId => versionId;
}

class MozillaSigningStatus {
  const MozillaSigningStatus({
    required this.versionId,
    required this.version,
    required this.fileStatus,
    required this.mozillaInternalCertificate,
    this.downloadUrl,
  });
  final int versionId;
  final String version;
  final String fileStatus;
  final bool mozillaInternalCertificate;
  // Never display a raw URL: it may contain an unlisted download token.
  final Uri? downloadUrl;
  bool get readyForSignedDownload => fileStatus == 'public';
  bool get approved => readyForSignedDownload;
  int get amoVersionId => versionId;
}

class MozillaSignedDownload {
  const MozillaSignedDownload({
    required this.path,
    required this.sha256,
    required this.versionId,
    required this.version,
  });
  final String path;
  final String sha256;
  final int versionId;
  final String version;
  // Signature markers are checked here; Firefox performs cryptographic validation.
}

class MozillaSigningClient {
  MozillaSigningClient({
    MozillaSigningTransport? transport,
    Future<void> Function(Duration)? wait,
    DateTime Function()? now,
    this.processingAttempts = 40,
  }) : _transport = transport ?? MozillaHttpSigningTransport(),
       _wait = wait ?? Future<void>.delayed,
       _now = now ?? DateTime.now;

  static const addonId = 'sixvpn-blocker@sixvpnblocker.app';
  static const account = String.fromEnvironment('FOCUSFENSE_MOZILLA_ACCOUNT', defaultValue: 'developer@example.invalid');
  static const maxPackageBytes = 32 * 1024 * 1024;
  static const _downloadHosts = {
    'addons.mozilla.org',
    'addons.mozilla.net',
    'addons.cdn.mozilla.net',
  };
  static final _versions = Uri.parse(
    'https://addons.mozilla.org/api/v5/addons/addon/${Uri.encodeComponent(addonId)}/versions/',
  );
  static final _upload = Uri.parse(
    'https://addons.mozilla.org/api/v5/addons/upload/',
  );
  final MozillaSigningTransport _transport;
  final Future<void> Function(Duration) _wait;
  final DateTime Function() _now;
  final int processingAttempts;

  void close() {
    final transport = _transport;
    if (transport is MozillaHttpSigningTransport) transport.close();
  }

  Future<String> packageVersion(String path) async {
    final file = File(path);
    if (await file.length() > maxPackageBytes) {
      throw const MozillaSigningException('package_too_large');
    }
    return validatedPackageVersion(await file.readAsBytes());
  }

  static String validatedPackageVersion(
    List<int> bytes, {
    bool requireSignature = false,
  }) => _readPackage(bytes, requireSignature: requireSignature).version;

  String _token(String issuer, String secret) {
    if (issuer.trim().isEmpty || secret.trim().isEmpty) {
      throw const MozillaSigningException('credentials_missing');
    }
    String encode(List<int> value) =>
        base64Url.encode(value).replaceAll('=', '');
    final stamp = _now().millisecondsSinceEpoch ~/ 1000;
    final random = Random.secure();
    final jti = encode(List<int>.generate(24, (_) => random.nextInt(256)));
    final head = encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
    final payload = encode(
      utf8.encode(
        jsonEncode({
          'iss': issuer,
          'jti': jti,
          'iat': stamp,
          'exp': stamp + 60,
        }),
      ),
    );
    final message = '$head.$payload';
    return '$message.${encode(Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(message)).bytes)}';
  }

  void _official(Uri uri, {bool api = false}) {
    final allowed = api
        ? uri.host == 'addons.mozilla.org'
        : _downloadHosts.contains(uri.host);
    if (uri.scheme != 'https' ||
        !allowed ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        (api && !uri.path.startsWith('/api/v5/addons/'))) {
      throw const MozillaSigningException('unsafe_mozilla_url');
    }
  }

  Future<Map<String, dynamic>> _json(
    String method,
    Uri uri,
    String issuer,
    String secret, {
    List<int>? body,
    String? contentType,
  }) async {
    _official(uri, api: true);
    final result = await _transport.send(
      method,
      uri,
      headers: {
        'Authorization': 'JWT ${_token(issuer, secret)}',
        'Content-Type': ?contentType,
      },
      body: body,
    );
    _checkStatus(result.statusCode);
    try {
      final data = jsonDecode(utf8.decode(result.body));
      if (data is Map<String, dynamic>) return data;
    } catch (_) {
      /* Remote bodies must never be surfaced. */
    }
    throw const MozillaSigningException('invalid_mozilla_response');
  }

  void _checkStatus(int code) {
    if (code >= 200 && code < 300) return;
    throw MozillaSigningException(switch (code) {
      401 => 'invalid_credentials',
      403 => 'account_access_denied',
      429 => 'rate_limited',
      404 => 'not_found',
      _ => 'mozilla_request_failed',
    }, httpStatus: code);
  }

  /// Read-only authorization check. It cannot establish ownership of an email.
  Future<void> validateCredentials({
    required String issuer,
    required String secret,
  }) async {
    await _json(
      'GET',
      _versions.replace(queryParameters: {'page_size': '1'}),
      issuer,
      secret,
    );
  }

  Future<MozillaSigningReceipt> submitPackage({
    required String path,
    required String issuer,
    required String secret,
  }) async {
    final file = File(path);
    if (await file.length() > maxPackageBytes) {
      throw const MozillaSigningException('package_too_large');
    }
    final bytes = await file.readAsBytes();
    final package = _readPackage(bytes);
    final boundary =
        'focusfense${_now().microsecondsSinceEpoch}${Random.secure().nextInt(1 << 30)}';
    final multipart = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="channel"\r\n\r\nunlisted\r\n',
        ),
      )
      ..add(
        utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="upload"; filename="focusfense-${package.version}.xpi"\r\nContent-Type: application/x-xpinstall\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final uploaded = await _json(
      'POST',
      _upload,
      issuer,
      secret,
      body: multipart.takeBytes(),
      contentType: 'multipart/form-data; boundary=$boundary',
    );
    final id = uploaded['uuid'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(id)) {
      throw const MozillaSigningException('invalid_upload_receipt');
    }
    bool processed = false;
    for (var attempt = 0; attempt < processingAttempts; attempt++) {
      final processing = await _json(
        'GET',
        _upload.resolve('$id/'),
        issuer,
        secret,
      );
      if (processing['processed'] == true) {
        if (processing['valid'] != true) {
          throw const MozillaSigningException('package_validation_failed');
        }
        processed = true;
        break;
      }
      if (attempt + 1 < processingAttempts) {
        await _wait(const Duration(seconds: 3));
      }
    }
    if (!processed) throw const MozillaSigningException('processing_pending');
    final created = await _json(
      'POST',
      _versions,
      issuer,
      secret,
      body: utf8.encode(jsonEncode({'upload': id})),
      contentType: 'application/json',
    );
    final versionId = created['id'];
    if (versionId is! int ||
        versionId <= 0 ||
        created['version'] != package.version) {
      throw const MozillaSigningException('version_receipt_mismatch');
    }
    return MozillaSigningReceipt(
      versionId: versionId,
      version: package.version,
    );
  }

  Future<MozillaSigningStatus> status({
    required int versionId,
    required String issuer,
    required String secret,
  }) async {
    if (versionId <= 0) {
      throw const MozillaSigningException('invalid_version_id');
    }
    final data = await _json(
      'GET',
      _versions.resolve('$versionId/'),
      issuer,
      secret,
    );
    final version = data['version'];
    if (data['id'] != versionId ||
        version is! String ||
        !_numericVersion(version)) {
      throw const MozillaSigningException('version_receipt_mismatch');
    }
    final file = data['file'];
    if (file is! Map) {
      throw const MozillaSigningException('invalid_mozilla_response');
    }
    final state = file['status'];
    if (state is! String || !RegExp(r'^[a-z_-]{1,32}$').hasMatch(state)) {
      throw const MozillaSigningException('invalid_mozilla_response');
    }
    Uri? url;
    if (file['url'] is String) {
      try {
        url = Uri.parse(file['url'] as String);
      } catch (_) {
        throw const MozillaSigningException('unsafe_mozilla_url');
      }
      _official(url);
    }
    return MozillaSigningStatus(
      versionId: versionId,
      version: version,
      fileStatus: state,
      mozillaInternalCertificate: file['is_mozilla_signed_extension'] == true,
      downloadUrl: url,
    );
  }

  Future<MozillaSignedDownload> downloadApproved({
    required int versionId,
    required String expectedVersion,
    required String issuer,
    required String secret,
    required String stagingDir,
  }) async {
    final current = await status(
      versionId: versionId,
      issuer: issuer,
      secret: secret,
    );
    if (current.version != expectedVersion) {
      throw const MozillaSigningException('version_receipt_mismatch');
    }
    if (!current.approved || current.downloadUrl == null) {
      throw const MozillaSigningException('signing_pending');
    }
    final directory = Directory(stagingDir);
    if (!directory.isAbsolute || !await directory.exists()) {
      throw const MozillaSigningException('invalid_staging_directory');
    }
    final resolved = (await directory.resolveSymbolicLinks())
        .replaceAll('\\', '/')
        .toLowerCase();
    if (resolved.contains('/mobile/assets') ||
        resolved
            .split('/')
            .any(
              (part) => {
                'programdata',
                'programs',
                'program files',
                'program files (x86)',
                'extensions',
              }.contains(part),
            )) {
      throw const MozillaSigningException('protected_deployment_destination');
    }
    var uri = current.downloadUrl!;
    List<int>? content;
    for (var redirect = 0; redirect <= 5; redirect++) {
      _official(uri);
      final result = await _transport.send(
        'GET',
        uri,
        headers: {
          if (redirect == 0 && uri.host == 'addons.mozilla.org')
            'Authorization': 'JWT ${_token(issuer, secret)}',
        },
      );
      if ({301, 302, 303, 307, 308}.contains(result.statusCode)) {
        if (result.location == null || redirect == 5) {
          throw const MozillaSigningException('invalid_download_redirect');
        }
        try {
          uri = uri.resolve(result.location!);
        } catch (_) {
          throw const MozillaSigningException('invalid_download_redirect');
        }
        _official(uri);
        continue;
      }
      _checkStatus(result.statusCode);
      if (result.body.length > maxPackageBytes) {
        throw const MozillaSigningException('package_too_large');
      }
      content = result.body;
      break;
    }
    if (content == null) {
      throw const MozillaSigningException('invalid_download_redirect');
    }
    final package = _readPackage(content, requireSignature: true);
    if (package.version != expectedVersion) {
      throw const MozillaSigningException('package_identity_mismatch');
    }
    final target = File(
      '${directory.path}${Platform.pathSeparator}focusfense-$expectedVersion-${_now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}-signed.xpi',
    );
    try {
      await target.create(exclusive: true);
      await target.writeAsBytes(content, flush: true);
    } catch (_) {
      // A failure never overwrites a source XPI or existing installation.
      throw const MozillaSigningException('staging_write_failed');
    }
    return MozillaSignedDownload(
      path: target.path,
      sha256: sha256.convert(content).toString(),
      versionId: versionId,
      version: expectedVersion,
    );
  }

  static bool _numericVersion(String text) =>
      RegExp(r'^[0-9]+(?:\.[0-9]+){0,3}$').hasMatch(text);

  /// Read package metadata only; never extract files or trust signature markers
  /// as cryptographic signature validation.
  static _PackageIdentity _readPackage(
    List<int> input, {
    bool requireSignature = false,
  }) {
    try {
      if (input.length > maxPackageBytes || input.length < 22) {
        throw const FormatException();
      }
      final index = ZipDirectory()..read(InputMemoryStream(input));
      if (index.fileHeaders.isEmpty || index.fileHeaders.length > 4096) {
        throw const FormatException();
      }
      var declaredTotal = 0;
      final declaredNames = <String>{};
      for (final header in index.fileHeaders) {
        declaredTotal += header.uncompressedSize;
        if (!declaredNames.add(header.filename.toLowerCase()) ||
            header.generalPurposeBitFlag & 1 != 0 ||
            declaredTotal > 64 * 1024 * 1024 ||
            (header.externalFileAttributes >> 16) & 0xf000 == 0xa000 ||
            (header.filename == 'manifest.json' &&
                header.uncompressedSize > 1024 * 1024)) {
          throw const FormatException();
        }
      }
      final archive = ZipDecoder().decodeBytes(input);
      if (archive.length > 4096) throw const FormatException();
      final names = <String>{};
      ArchiveFile? manifest;
      var expandedTotal = 0;
      for (final entry in archive) {
        if (!names.add(entry.name.toLowerCase())) throw const FormatException();
        expandedTotal += entry.size;
        if (expandedTotal > 64 * 1024 * 1024) throw const FormatException();
        if (entry.name == 'manifest.json') {
          if (!entry.isFile || entry.size > 1024 * 1024) {
            throw const FormatException();
          }
          manifest = entry;
        }
      }
      if (manifest == null ||
          (requireSignature &&
              !names.containsAll({
                'meta-inf/mozilla.rsa',
                'meta-inf/mozilla.sf',
                'meta-inf/manifest.mf',
              }))) {
        throw const FormatException();
      }
      final bytes = manifest.content;
      if (bytes.length != manifest.size || bytes.length > 1024 * 1024) {
        throw const FormatException();
      }
      final data = jsonDecode(utf8.decode(bytes)) as Map;
      final settings =
          data['browser_specific_settings'] ?? data['applications'];
      final version = data['version'];
      if (settings is! Map ||
          settings['gecko'] is! Map ||
          settings['gecko']['id'] != addonId ||
          version is! String ||
          !_numericVersion(version)) {
        throw const MozillaSigningException('package_identity_mismatch');
      }
      return _PackageIdentity(version);
    } on MozillaSigningException {
      rethrow;
    } catch (_) {
      throw const MozillaSigningException('invalid_xpi_package');
    }
  }
}

class _PackageIdentity {
  const _PackageIdentity(this.version);
  final String version;
}
