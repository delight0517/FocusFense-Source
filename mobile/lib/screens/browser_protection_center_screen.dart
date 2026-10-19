import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/mozilla_credential_store.dart';
import '../services/mozilla_signing_client.dart';
import '../services/windows_firefox_extension_install_service.dart';
import '../services/firefox_xpi_packager.dart';
import '../services/browser_management_control.dart';
import '../services/locale_controller.dart';
import '../localization/app_i18n.dart';

/// On-demand maintenance only: no background polling, browser restart or tests.
class BrowserProtectionCenterScreen extends StatefulWidget {
  const BrowserProtectionCenterScreen({
    super.key,
    this.credentialStore,
    this.signingClient,
    this.onSignedDownloadReady,
    this.inspectFirefox,
    this.openFirefoxUpdate,
    this.locale,
    this.credentialPromptRequestId,
  });
  final MozillaCredentialStore? credentialStore;
  final MozillaSigningClient? signingClient;
  final Future<void> Function(MozillaSignedDownload)? onSignedDownloadReady;
  final Future<FirefoxManagedRepairReport> Function()? inspectFirefox;
  final Future<Map<String, Object?>> Function()? openFirefoxUpdate;
  final Locale? locale;
  final int? credentialPromptRequestId;
  @override
  State<BrowserProtectionCenterScreen> createState() =>
      _BrowserProtectionCenterScreenState();
}

class _BrowserProtectionCenterScreenState
    extends State<BrowserProtectionCenterScreen> {
  late final MozillaCredentialStore _store;
  late final MozillaSigningClient _signer;
  MozillaCredentialStatus? _credentials;
  FirefoxManagedRepairReport? _firefox;
  bool _busy = false;
  String _message = '저장된 연결 상태를 확인합니다.';
  String? _backupFolder;
  int _versionId = 0;
  String _version = '';
  MozillaSigningStatus? _signing;
  String? _lastBackupPath;
  String? _lastBackupHash;
  Map<String, Object?>? _firefoxUpdate;
  int? _handledCredentialPromptRequestId;
  int? _pendingCredentialPromptRequestId;
  bool _credentialDialogOpen = false;

  static const _updateWords = <String, Map<String, String>>{
    'ko': {
      'prepared': '업데이트 파일 준비됨',
      'notPrepared': '업데이트 파일 준비 전',
      'confirm': 'Firefox에서 업데이트 승인이 필요할 수 있습니다.',
      'launched': 'Firefox에 열기 요청을 전달했습니다. 확인창 표시와 승인은 아직 검증되지 않았습니다.',
      'notLaunched': '업데이트 열기를 누르면 준비한 서명본을 Firefox로 전달합니다.',
      'runtimeUnknown': '현재 실행 중인 Firefox 확장 활성화: 아직 확인되지 않음',
      'profileMatch': '프로필 파일·설치 기록 일치',
      'profileUnknown': '프로필 파일·설치 기록: 아직 일치하지 않음',
      'open': 'Firefox 업데이트 열기',
      'recheck': '설치 상태 다시 확인',
      'launchFailed': '업데이트 열기 요청을 전달하지 못했습니다.',
      'refreshed': '설치 정책과 프로필 기록을 확인했습니다. 실행 중인 확장과 실제 차단은 별도 확인이 필요합니다.',
    },
    'en': {
      'prepared': 'Update package prepared',
      'notPrepared': 'Update package not prepared yet',
      'confirm': 'Firefox may require you to approve the update.',
      'launched':
          'Open request sent to Firefox. The confirmation dialog and approval have not been verified.',
      'notLaunched':
          'Open the update to send the prepared signed package to Firefox.',
      'runtimeUnknown': 'Activation in the running Firefox: not verified',
      'profileMatch': 'Profile package and installation records match',
      'profileUnknown':
          'Profile package and installation records do not yet match',
      'open': 'Open Firefox update',
      'recheck': 'Recheck installation',
      'launchFailed': 'Could not send the update open request.',
      'refreshed':
          'Installation policies and profile records checked. Running extension activation and actual blocking require separate verification.',
    },
    'ja': {
      'prepared': '更新パッケージ準備済み',
      'notPrepared': '更新パッケージ未準備',
      'confirm': 'Firefoxで更新の承認が必要な場合があります。',
      'launched': 'Firefoxに開く要求を送信しました。確認画面の表示と承認は未確認です。',
      'notLaunched': '更新を開くと、準備した署名済みパッケージをFirefoxに渡します。',
      'runtimeUnknown': '実行中のFirefoxでの有効化：未確認',
      'profileMatch': 'プロファイルのファイルとインストール記録が一致',
      'profileUnknown': 'プロファイルのファイルと記録はまだ一致していません',
      'open': 'Firefoxの更新を開く',
      'recheck': 'インストールを再確認',
      'launchFailed': '更新を開く要求を送信できませんでした。',
      'refreshed': 'ポリシーとプロファイル記録を確認しました。実行中の拡張機能と実際の遮断は別途確認が必要です。',
    },
    'zh': {
      'prepared': '更新包已准备好',
      'notPrepared': '更新包尚未准备',
      'confirm': 'Firefox可能需要您批准更新。',
      'launched': '已向Firefox发送打开请求。确认窗口是否显示以及是否批准尚未验证。',
      'notLaunched': '点击打开更新，将准备好的已签名更新包发送到Firefox。',
      'runtimeUnknown': '运行中Firefox的扩展激活状态：尚未验证',
      'profileMatch': '配置文件中的扩展包与安装记录一致',
      'profileUnknown': '配置文件中的扩展包与安装记录尚未一致',
      'open': '打开Firefox更新',
      'recheck': '重新检查安装',
      'launchFailed': '无法发送打开更新的请求。',
      'refreshed': '已检查安装策略和配置记录。运行中的扩展及实际拦截仍需单独验证。',
    },
    'he': {
      'prepared': 'חבילת העדכון מוכנה',
      'notPrepared': 'חבילת העדכון עדיין לא מוכנה',
      'confirm': 'ייתכן ש-Firefox יבקש לאשר את העדכון.',
      'launched':
          'בקשת פתיחה נשלחה ל-Firefox. הצגת חלון האישור והאישור עצמו לא אומתו.',
      'notLaunched': 'פתיחת העדכון תשלח ל-Firefox את החבילה החתומה שהוכנה.',
      'runtimeUnknown': 'הפעלה ב-Firefox הפועל: טרם אומתה',
      'profileMatch': 'החבילה ורישומי ההתקנה בפרופיל תואמים',
      'profileUnknown': 'החבילה ורישומי ההתקנה עדיין אינם תואמים',
      'open': 'פתיחת עדכון Firefox',
      'recheck': 'בדיקת ההתקנה מחדש',
      'launchFailed': 'לא ניתן לשלוח בקשה לפתיחת העדכון.',
      'refreshed':
          'נבדקו המדיניות ורישומי הפרופיל. הפעלת התוסף והחסימה בפועל מחייבות בדיקה נפרדת.',
    },
    'ar': {
      'prepared': 'حزمة التحديث جاهزة',
      'notPrepared': 'حزمة التحديث غير جاهزة بعد',
      'confirm': 'قد يطلب Firefox موافقتك على التحديث.',
      'launched':
          'أُرسل طلب الفتح إلى Firefox. لم يُتحقق من ظهور نافذة التأكيد أو الموافقة.',
      'notLaunched': 'افتح التحديث لإرسال الحزمة الموقعة الجاهزة إلى Firefox.',
      'runtimeUnknown': 'تفعيل الإضافة في Firefox الجاري: لم يُتحقق منه',
      'profileMatch': 'حزمة الملف الشخصي وسجلات التثبيت متطابقة',
      'profileUnknown': 'حزمة الملف الشخصي وسجلات التثبيت غير متطابقة بعد',
      'open': 'فتح تحديث Firefox',
      'recheck': 'إعادة فحص التثبيت',
      'launchFailed': 'تعذر إرسال طلب فتح التحديث.',
      'refreshed':
          'فُحصت سياسات التثبيت وسجلات الملف الشخصي. يلزم التحقق بشكل منفصل من الإضافة الجارية والحظر الفعلي.',
    },
  };
  String _updateT(String key) {
    final locale = widget.locale ?? LocaleController.instance.locale;
    final code =
        AppI18n.supportedLocales.any(
          (l) => l.languageCode == locale.languageCode,
        )
        ? locale.languageCode
        : 'en';
    return _updateWords[code]?[key] ?? _updateWords['en']![key]!;
  }

  Future<void> _openUpdate() async {
    final result =
        await (widget.openFirefoxUpdate?.call() ??
            BrowserManagementControl.run(
              'browser.firefox.openUpdate',
              const {},
            ));
    _firefoxUpdate = result;
    _message = result['launchRequested'] == true
        ? _updateT('launched')
        : _updateT('launchFailed');
  }

  @override
  void initState() {
    super.initState();
    _store = widget.credentialStore ?? MozillaCredentialStore();
    _signer = widget.signingClient ?? MozillaSigningClient();
    _run(_refresh);
    _scheduleCredentialPrompt(widget.credentialPromptRequestId);
  }

  @override
  void didUpdateWidget(covariant BrowserProtectionCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.credentialPromptRequestId !=
        oldWidget.credentialPromptRequestId) {
      _scheduleCredentialPrompt(widget.credentialPromptRequestId);
    }
  }

  void _scheduleCredentialPrompt(int? requestId) {
    if (requestId == null || requestId == _handledCredentialPromptRequestId) {
      return;
    }
    _handledCredentialPromptRequestId = requestId;
    _pendingCredentialPromptRequestId = requestId;
    _showPendingCredentialPrompt();
  }

  void _showPendingCredentialPrompt() {
    final requestId = _pendingCredentialPromptRequestId;
    if (_busy || _credentialDialogOpen || requestId == null) return;
    _pendingCredentialPromptRequestId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_busy && requestId == _handledCredentialPromptRequestId) {
        _credentialDialog();
      }
    });
  }

  @override
  void dispose() {
    if (widget.signingClient == null) _signer.close();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on MozillaSigningException catch (error) {
      _message = switch (error.code) {
        'invalid_credentials' =>
          'Mozilla 인증이 거부됐습니다. 발급 페이지에서 현재 자격증명 쌍을 확인해 주세요.',
        'account_access_denied' =>
          '이 확장에 접근할 수 없는 Mozilla 계정입니다. 등록된 계정을 확인해 주세요.',
        'signing_pending' ||
        'processing_pending' => 'Mozilla에서 아직 처리 중입니다. 잠시 후 심사 상태를 다시 확인해 주세요.',
        'rate_limited' => 'Mozilla 요청 한도에 도달했습니다. 잠시 후 다시 시도해 주세요.',
        _ => 'Mozilla 작업을 완료하지 못했습니다. 연결과 선택한 확장 파일을 확인해 주세요.',
      };
    } catch (_) {
      _message = '작업을 완료하지 못했습니다. 파일 접근 권한과 연결 상태를 확인해 주세요.';
    } finally {
      if (mounted) setState(() => _busy = false);
      _showPendingCredentialPrompt();
    }
  }

  Future<void> _refresh() async {
    final prefs = await SharedPreferences.getInstance();
    _backupFolder = prefs.getString('mozilla_backup_folder_v1');
    _versionId = prefs.getInt('mozilla_signing_version_id_v1') ?? 0;
    _version = prefs.getString('mozilla_signing_version_v1') ?? '';
    if (_version.isEmpty) _versionId = 0;
    _lastBackupPath = prefs.getString('mozilla_last_backup_path_v1');
    _lastBackupHash = prefs.getString('mozilla_last_backup_hash_v1');
    _credentials = await _store.status();
    _firefox =
        await (widget.inspectFirefox?.call() ??
            WindowsFirefoxExtensionInstallService.instance.inspectManaged());
    if (_version.isEmpty) _version = _firefox?.expectedVersion ?? '';
    _message = _updateT('refreshed');
  }

  static const _credentialWords = <String, Map<String, String>>{
    'ko': {
      'title': 'Mozilla 연결',
      'save': '인증 후 저장',
      'cancel': '취소',
      'page': 'Firefox에서 발급 페이지 열기',
      'owner': '확장 소유자의 Mozilla 개발자 계정',
      'show': '표시',
      'hide': '숨기기',
      'empty': 'JWT issuer와 secret을 모두 입력해 주세요.',
      'placeholder': '점이나 가림 문자 대신 Mozilla에서 발급한 실제 secret을 붙여 넣어 주세요.',
      'unauthorized':
          '인증 실패 (401). Mozilla API 발급 페이지에서 같은 쌍의 issuer와 secret을 다시 복사해 주세요. 이 창에서 수정 후 다시 시도할 수 있습니다.',
      'denied': '이 확장에 접근할 수 없는 계정입니다. 확장을 소유한 Mozilla 계정을 확인해 주세요.',
      'rate': 'Mozilla 요청 한도에 도달했습니다. 잠시 후 이 창에서 다시 시도해 주세요.',
      'network': 'Mozilla 인증을 확인하지 못했습니다. 연결을 확인한 뒤 다시 시도해 주세요.',
      'storage': '인증은 성공했지만 이 PC의 암호화 저장에 실패했습니다. 파일 권한을 확인한 뒤 다시 저장해 주세요.',
      'saved': 'Mozilla 인증과 이 PC의 암호화 저장을 완료했습니다.',
      'backupFailed': '자격증명은 인증 후 저장됐지만 암호화 백업에 실패했습니다. 백업 버튼으로 다시 시도해 주세요.',
    },
    'en': {
      'title': 'Connect Mozilla',
      'save': 'Authenticate and save',
      'cancel': 'Cancel',
      'page': 'Open API credentials in Firefox',
      'owner': 'Mozilla developer account that owns the extension',
      'show': 'Show',
      'hide': 'Hide',
      'empty': 'Enter both JWT issuer and secret.',
      'placeholder':
          'Paste the actual Mozilla secret, not dots or masking characters.',
      'unauthorized':
          'Authentication failed (401). Copy the matching issuer and secret again from Mozilla API credentials. Correct them here and retry.',
      'denied':
          'This account cannot access the extension. Check the Mozilla account that owns it.',
      'rate':
          'Mozilla rate limit reached. Wait briefly and retry in this dialog.',
      'network':
          'Could not verify Mozilla authentication. Check the connection and retry.',
      'storage':
          'Authentication succeeded, but encrypted storage on this PC failed. Check file permissions and retry saving.',
      'saved':
          'Mozilla authentication and encrypted storage on this PC completed.',
      'backupFailed':
          'Credentials were authenticated and saved, but encrypted backup failed. Retry with the backup button.',
    },
    'ja': {
      'title': 'Mozillaに接続',
      'save': '認証して保存',
      'cancel': 'キャンセル',
      'page': 'FirefoxでAPI認証情報を開く',
      'owner': '拡張機能を所有するMozilla開発者アカウント',
      'show': '表示',
      'hide': '非表示',
      'empty': 'JWT issuerとsecretを両方入力してください。',
      'placeholder': '伏せ字や点ではなく、Mozillaが発行した実際のsecretを貼り付けてください。',
      'unauthorized':
          '認証失敗（401）。MozillaのAPIページから同じ組のissuerとsecretをコピーし直し、この画面で再試行してください。',
      'denied': 'このアカウントは拡張機能にアクセスできません。所有アカウントを確認してください。',
      'rate': 'Mozillaのリクエスト上限です。少し待って再試行してください。',
      'network': 'Mozilla認証を確認できません。接続を確認して再試行してください。',
      'storage': '認証には成功しましたが、このPCの暗号化保存に失敗しました。権限を確認して再保存してください。',
      'saved': 'Mozilla認証とこのPCの暗号化保存を完了しました。',
      'backupFailed': '認証情報は保存しましたが暗号化バックアップに失敗しました。バックアップボタンで再試行してください。',
    },
    'zh': {
      'title': '连接Mozilla',
      'save': '验证并保存',
      'cancel': '取消',
      'page': '在Firefox中打开API凭据',
      'owner': '拥有此扩展的Mozilla开发者账户',
      'show': '显示',
      'hide': '隐藏',
      'empty': '请输入JWT issuer和secret。',
      'placeholder': '请粘贴Mozilla签发的真实secret，而不是圆点或遮挡字符。',
      'unauthorized':
          '验证失败（401）。请从Mozilla API页面重新复制配对的issuer和secret，在此窗口修改并重试。',
      'denied': '此账户无法访问扩展，请检查扩展所有者账户。',
      'rate': '已达到Mozilla请求限制，请稍后在此窗口重试。',
      'network': '无法确认Mozilla验证，请检查连接后重试。',
      'storage': '验证成功，但此电脑的加密保存失败。请检查文件权限后重新保存。',
      'saved': '已完成Mozilla验证及此电脑的加密保存。',
      'backupFailed': '凭据已验证并保存，但加密备份失败，请点击备份按钮重试。',
    },
    'he': {
      'title': 'חיבור Mozilla',
      'save': 'אימות ושמירה',
      'cancel': 'ביטול',
      'page': 'פתיחת אישורי API ב-Firefox',
      'owner': 'חשבון המפתחים של Mozilla שבבעלותו התוסף',
      'show': 'הצגה',
      'hide': 'הסתרה',
      'empty': 'יש להזין JWT issuer וגם secret.',
      'placeholder':
          'יש להדביק את הסוד האמיתי מ-Mozilla, לא נקודות או תווי הסתרה.',
      'unauthorized':
          'האימות נכשל (401). יש להעתיק שוב את צמד issuer ו-secret מדף API של Mozilla ולנסות בחלון זה.',
      'denied': 'לחשבון אין גישה לתוסף. יש לבדוק את חשבון הבעלים.',
      'rate': 'הגעת למגבלת בקשות Mozilla. יש להמתין מעט ולנסות שוב.',
      'network': 'לא ניתן לאמת מול Mozilla. יש לבדוק את החיבור ולנסות שוב.',
      'storage':
          'האימות הצליח, אך השמירה המוצפנת במחשב נכשלה. יש לבדוק הרשאות ולנסות לשמור שוב.',
      'saved': 'האימות והשמירה המוצפנת במחשב הושלמו.',
      'backupFailed':
          'האישורים אומתו ונשמרו, אך הגיבוי המוצפן נכשל. יש לנסות שוב באמצעות כפתור הגיבוי.',
    },
    'ar': {
      'title': 'ربط Mozilla',
      'save': 'التحقق والحفظ',
      'cancel': 'إلغاء',
      'page': 'فتح بيانات API في Firefox',
      'owner': 'حساب مطور Mozilla مالك الإضافة',
      'show': 'إظهار',
      'hide': 'إخفاء',
      'empty': 'أدخل JWT issuer وsecret معاً.',
      'placeholder':
          'الصق secret الحقيقي من Mozilla، وليس النقاط أو أحرف الإخفاء.',
      'unauthorized':
          'فشل التحقق (401). انسخ issuer وsecret المتطابقين مجدداً من صفحة Mozilla API ثم عدلهما هنا وأعد المحاولة.',
      'denied':
          'لا يمكن لهذا الحساب الوصول إلى الإضافة. تحقق من حساب مالك الإضافة.',
      'rate': 'بلغت حد طلبات Mozilla. انتظر قليلاً ثم أعد المحاولة هنا.',
      'network': 'تعذر تأكيد التحقق من Mozilla. تحقق من الاتصال وأعد المحاولة.',
      'storage':
          'نجح التحقق لكن فشل الحفظ المشفر على هذا الكمبيوتر. تحقق من الأذونات وأعد الحفظ.',
      'saved': 'اكتمل التحقق والحفظ المشفر على هذا الكمبيوتر.',
      'backupFailed':
          'تم التحقق وحفظ البيانات، لكن فشل النسخ المشفر. أعد المحاولة بزر النسخ الاحتياطي.',
    },
  };
  String _credentialT(String key) {
    final code =
        (widget.locale ?? LocaleController.instance.locale).languageCode;
    return _credentialWords[code]?[key] ?? _credentialWords['en']![key]!;
  }

  Future<void> _credentialDialog() async {
    if (_busy || _credentialDialogOpen) return;
    _credentialDialogOpen = true;
    final issuer = TextEditingController(), secret = TextEditingController();
    bool dialogBusy = false;
    bool showIssuer = false;
    bool showSecret = false;
    bool persistenceComplete = false;
    String? errorKey;
    bool? saved;
    try {
      final route = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, updateDialog) {
            Future<void> authenticateAndSave() async {
              if (dialogBusy) return;
              final issuerText = MozillaCredentialStore.normalizeInput(
                    issuer.text,
                  ),
                  secretText = MozillaCredentialStore.normalizeInput(
                    secret.text,
                  );
              issuer.value = TextEditingValue(
                text: issuerText,
                selection: TextSelection.collapsed(offset: issuerText.length),
              );
              secret.value = TextEditingValue(
                text: secretText,
                selection: TextSelection.collapsed(offset: secretText.length),
              );
              if (issuerText.isEmpty || secretText.isEmpty) {
                updateDialog(() => errorKey = 'empty');
                return;
              }
              if (RegExp(
                    r'^[.\u2022\u25cf\u00b7\u2026*\s]+$',
                  ).hasMatch(secretText) ||
                  RegExp(
                    r'\.{3,}|[\u2022\u25cf\u00b7]{2,}|\u2026|\*{3,}',
                  ).hasMatch(secretText)) {
                updateDialog(() => errorKey = 'placeholder');
                return;
              }
              updateDialog(() {
                dialogBusy = true;
                errorKey = null;
              });
              bool authenticated = false;
              try {
                await _signer.validateCredentials(
                  issuer: issuerText,
                  secret: secretText,
                );
                authenticated = true;
                await _store.save(issuer: issuerText, secret: secretText);
                if (!dialogContext.mounted) return;
                updateDialog(() => persistenceComplete = true);
                await WidgetsBinding.instance.endOfFrame;
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(true);
                }
              } on MozillaSigningException catch (error) {
                if (dialogContext.mounted) {
                  updateDialog(() {
                    dialogBusy = false;
                    errorKey = switch (error.code) {
                      'invalid_credentials' => 'unauthorized',
                      'account_access_denied' => 'denied',
                      'rate_limited' => 'rate',
                      _ => 'network',
                    };
                  });
                }
              } catch (_) {
                if (dialogContext.mounted) {
                  updateDialog(() {
                    dialogBusy = false;
                    errorKey = authenticated ? 'storage' : 'network';
                  });
                }
              }
            }

            return PopScope(
              canPop: !dialogBusy || persistenceComplete,
              child: AlertDialog(
                title: Text(_credentialT('title')),
                content: SizedBox(
                  width: 440,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_credentialT('owner')),
                        const SizedBox(height: 16),
                        TextField(
                          key: const Key('mozilla-issuer-input'),
                          controller: issuer,
                          enabled: !dialogBusy,
                          obscureText: !showIssuer,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration:
                              const InputDecoration(
                                labelText: 'JWT issuer',
                              ).copyWith(
                                suffixIcon: IconButton(
                                  key: const Key('mozilla-issuer-visibility'),
                                  tooltip: _credentialT(
                                    showIssuer ? 'hide' : 'show',
                                  ),
                                  onPressed: dialogBusy
                                      ? null
                                      : () => updateDialog(
                                          () => showIssuer = !showIssuer,
                                        ),
                                  icon: Icon(
                                    showIssuer
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('mozilla-secret-input'),
                          controller: secret,
                          enabled: !dialogBusy,
                          obscureText: !showSecret,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration:
                              const InputDecoration(
                                labelText: 'JWT secret',
                              ).copyWith(
                                suffixIcon: IconButton(
                                  key: const Key('mozilla-secret-visibility'),
                                  tooltip: _credentialT(
                                    showSecret ? 'hide' : 'show',
                                  ),
                                  onPressed: dialogBusy
                                      ? null
                                      : () => updateDialog(
                                          () => showSecret = !showSecret,
                                        ),
                                  icon: Icon(
                                    showSecret
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                        ),
                        if (dialogBusy)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: LinearProgressIndicator(),
                          ),
                        if (errorKey != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _credentialT(errorKey!),
                                key: const Key('mozilla-credential-error'),
                                style: TextStyle(
                                  color: Theme.of(
                                    dialogContext,
                                  ).colorScheme.error,
                                ),
                              ),
                            ),
                          ),
                        TextButton(
                          onPressed: dialogBusy
                              ? null
                              : () async {
                                  await WindowsFirefoxExtensionInstallService
                                      .instance
                                      .openMozillaCredentialPageInFirefox();
                                },
                          child: Text(_credentialT('page')),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: dialogBusy
                        ? null
                        : () => Navigator.of(dialogContext).pop(false),
                    child: Text(_credentialT('cancel')),
                  ),
                  FilledButton(
                    key: const Key('mozilla-authenticate-save'),
                    onPressed: dialogBusy ? null : authenticateAndSave,
                    child: Text(_credentialT('save')),
                  ),
                ],
              ),
            );
          },
        ),
      );
      saved = await Navigator.of(context).push<bool>(route);
      // Controllers must outlive the reverse transition, not just route.pop.
      await route.completed;
    } finally {
      issuer.clear();
      secret.clear();
      issuer.dispose();
      secret.dispose();
      _credentialDialogOpen = false;
      _showPendingCredentialPrompt();
    }
    if (saved != true || !mounted) return;
    await _run(() async {
      // Persistence already succeeded. Backup is a separate, honest outcome.
      _message = _credentialT('saved');
      try {
        _credentials = await _store.status();
        await _backup();
        _message = '${_credentialT('saved')} $_message';
      } catch (_) {
        _message = _credentialT('backupFailed');
      }
    });
  }

  Future<void> _backup() async {
    final local = await _store.backupCiphertext();
    String? directory = _backupFolder;
    const drive = r'G:\My Drive\FocusFense Credential Backups';
    if (directory == null && await Directory(r'G:\My Drive').exists()) {
      directory = drive;
    }
    final result = directory == null
        ? local
        : await _store.backupCiphertext(directory: directory);
    _message = directory == null
        ? '이 PC에 암호화 백업을 저장하고 해시를 검증했습니다.'
        : '선택한 폴더에 암호화 백업을 저장하고 해시를 검증했습니다. Drive의 클라우드 업로드 완료는 아직 확인되지 않았습니다.';
    // The digest is non-secret and is needed for verified restoration.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mozilla_last_backup_hash_v1', result.sha256);
    await prefs.setString('mozilla_last_backup_path_v1', result.path);
    _lastBackupPath = result.path;
    _lastBackupHash = result.sha256;
  }

  Future<void> _chooseBackupFolder() async {
    final path = await FilePicker.getDirectoryPath(dialogTitle: '암호화 백업 폴더 선택');
    if (path == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mozilla_backup_folder_v1', path);
    if (mounted) {
      setState(() {
        _backupFolder = path;
        _message = '백업 폴더를 저장했습니다.';
      });
    }
  }

  Future<void> _restore() async {
    final selection = await FilePicker.pickFiles(
      dialogTitle: '암호화 백업 선택',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = selection?.files.single.path;
    if (path == null || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final controller = TextEditingController(
      text: prefs.getString('mozilla_last_backup_path_v1') == path
          ? prefs.getString('mozilla_last_backup_hash_v1')
          : '',
    );
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('백업 무결성 확인'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: '백업할 때 기록한 SHA-256'),
            maxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('검증 후 복원'),
          ),
        ],
      ),
    );
    final hash = controller.text.trim();
    controller.dispose();
    if (accepted != true || !mounted) return;
    await _run(() async {
      await _store.restoreVerifiedBackup(path: path, expectedSha256: hash);
      _credentials = await _store.status();
      _message = '기존 파일을 보존하고 검증한 백업을 복원했습니다.';
    });
  }

  Future<void> _checkSigning() async {
    if (_versionId <= 0) return;
    final credentials = await _store.load();
    _signing = await _signer.status(
      versionId: _versionId,
      issuer: credentials.issuer,
      secret: credentials.secret,
    );
    _message = _signing!.approved
        ? 'Mozilla 승인이 완료됐습니다. 서명본을 받을 수 있습니다.'
        : 'Mozilla 검토 또는 서명 처리 중입니다.';
  }

  Future<void> _submit() async {
    final selection = await FilePicker.pickFiles(
      dialogTitle: '새 확장 패키지 선택',
      type: FileType.custom,
      allowedExtensions: ['zip', 'xpi'],
    );
    final path = selection?.files.single.path;
    if (path == null) return;
    await _run(() async {
      final version = await _signer.packageVersion(path);
      if (version == _version || version == _firefox?.expectedVersion) {
        _message = '이미 기록된 버전입니다. 새로 제출하지 않고 심사 상태를 확인해 주세요.';
        return;
      }
      final credentials = await _store.load();
      final receipt = await _signer.submitPackage(
        path: path,
        issuer: credentials.issuer,
        secret: credentials.secret,
      );
      _versionId = receipt.versionId;
      _version = receipt.version;
      _signing = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('mozilla_signing_version_id_v1', _versionId);
      await prefs.setString('mozilla_signing_version_v1', _version);
      _message = '새 버전을 Mozilla에 제출했습니다. 심사 상태를 확인해 주세요.';
    });
  }

  Future<void> _download() async {
    if (_versionId <= 0) return;
    final credentials = await _store.load();
    final stage = await Directory(
      p.join(
        Platform.environment['LOCALAPPDATA']!,
        'FocusFense',
        'mozilla-staging',
      ),
    ).create(recursive: true);
    final download = await _signer.downloadApproved(
      versionId: _versionId,
      expectedVersion: _version,
      issuer: credentials.issuer,
      secret: credentials.secret,
      stagingDir: stage.path,
    );
    if (widget.onSignedDownloadReady != null) {
      await widget.onSignedDownloadReady!(download);
    } else {
      await FirefoxXpiPackager.instance.adoptApprovedDownload(download);
    }
    _message = 'Mozilla 서명본을 검증해 업데이트 대상으로 준비했습니다. 관리자 설치·복구를 누르세요.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('브라우저 보호 관리')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('FocusFense에서 연결, 서명 업데이트와 Firefox 설치를 관리합니다.'),
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_message),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Firefox 보호',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _firefox?.activationVerified == true
                          ? '${_updateT('profileMatch')} · ${_firefox!.activeProfileCount}'
                          : _updateT('profileUnknown'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _updateT('runtimeUnknown'),
                      key: const Key('firefox-runtime-unverified'),
                    ),
                    Text(
                      _firefoxUpdate?['filesPrepared'] == true ||
                              _firefox?.filesPrepared == true
                          ? _updateT('prepared')
                          : _updateT('notPrepared'),
                      key: const Key('firefox-update-preparation'),
                    ),
                    Text(_updateT('confirm')),
                    if (_firefoxUpdate != null)
                      Text(
                        _firefoxUpdate!['launchRequested'] == true
                            ? _updateT('launched')
                            : _updateT('launchFailed'),
                        key: const Key('firefox-update-launch-state'),
                      ),
                    if (_firefox != null)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(
                          '프로필별 결과 · 활성 ${_firefox!.activeProfileCount}/${_firefox!.profileTotal}',
                        ),
                        children: _firefox!.profiles
                            .map(
                              (profile) => ListTile(
                                title: Text(profile.name),
                                subtitle: Text(
                                  '버전 ${profile.version} · ${profile.active ? '활성' : '비활성'} · 서명 상태 ${profile.signedState}',
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    Text(
                      '관리자 설치 정책: ${_firefox?.policiesApplied == true ? '이번 작업 적용 완료' : '이번 작업 적용 전'}',
                    ),
                    const Text(
                      '관리자 승인으로 서명 확장과 설치 정책을 적용합니다. Firefox 창은 닫지 않습니다. Mozilla 서명과 Windows 승인 자체를 우회하지 않습니다.',
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  _firefox =
                                      await WindowsFirefoxExtensionInstallService
                                          .instance
                                          .repairManaged(
                                            onProgress: (message) {
                                              if (mounted) {
                                                setState(
                                                  () => _message = message,
                                                );
                                              }
                                            },
                                          );
                                  _message = _firefox!.message;
                                }),
                          icon: const Icon(Icons.admin_panel_settings_outlined),
                          label: const Text('관리자 설치·복구'),
                        ),
                        OutlinedButton(
                          key: const Key('firefox-update-recheck'),
                          onPressed: _busy ? null : () => _run(_refresh),
                          child: Text(_updateT('recheck')),
                        ),
                        TextButton(
                          key: const Key('firefox-open-update'),
                          onPressed: _busy ? null : () => _run(_openUpdate),
                          child: Text(_updateT('open')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mozilla 연결 및 백업',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _credentials?.readable == true
                          ? '저장된 자격증명 있음 · Windows 사용자 암호화'
                          : 'Mozilla 자격증명 연결 필요',
                    ),
                    const Text('백업 복원에는 원래 Windows 사용자 프로필이 필요합니다.'),
                    if (_lastBackupPath != null)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('최근 백업 경로와 복원용 해시'),
                        children: [
                          SelectableText(
                            '$_lastBackupPath\nSHA-256: $_lastBackupHash',
                          ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: _busy ? null : _credentialDialog,
                          child: const Text('연결·자격증명 변경'),
                        ),
                        OutlinedButton(
                          onPressed: _busy || _credentials?.readable != true
                              ? null
                              : () => _run(_backup),
                          child: const Text('암호화 백업'),
                        ),
                        TextButton(
                          onPressed: _busy ? null : _chooseBackupFolder,
                          child: const Text('백업 폴더 선택'),
                        ),
                        TextButton(
                          onPressed: _busy ? null : _restore,
                          child: const Text('백업 복원'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: ExpansionTile(
                title: const Text('개발자용 확장 서명 업데이트'),
                subtitle: Text('현재 기록된 버전 $_version'),
                childrenPadding: const EdgeInsets.all(20),
                children: [
                  const Text('이미 서명된 버전은 다시 제출할 필요가 없습니다. 새 소스 패키지만 선택하세요.'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _busy || _credentials?.readable != true
                            ? null
                            : _submit,
                        child: const Text('새 패키지 선택·제출'),
                      ),
                      OutlinedButton(
                        onPressed:
                            _busy ||
                                _credentials?.readable != true ||
                                _versionId <= 0
                            ? null
                            : () => _run(_checkSigning),
                        child: const Text('심사 상태 확인'),
                      ),
                      FilledButton(
                        onPressed:
                            _busy ||
                                _signing?.approved != true ||
                                _versionId <= 0
                            ? null
                            : () => _run(_download),
                        child: const Text('승인된 서명본 받기'),
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
  );
}
