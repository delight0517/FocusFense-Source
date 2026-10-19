import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_schedule_intent.dart';
import '../services/build_identity_service.dart';
import '../services/chat_schedule_apply_service.dart';
import '../services/chat_schedule_audit_log_service.dart';
import '../services/chat_schedule_intent_parser.dart';
import '../services/chatgpt_plan_service.dart';
import '../services/daily_awareness_service.dart';
import '../theme/app_colors.dart';
import 'account_actions.dart';

const String _kWelcomeLine = '말로 스케줄을 만들 수 있어요. 미리보기 카드에서 한 번만 선택하면 바로 저장돼요.';

/// Tag on a persisted [_ChatLine] identifying which inline action buttons to
/// reattach after loading from disk (closures can't be serialized).
const String _kKindTimeLockNudge = 'timeLockNudge';

/// Small entry point shown on the Schedules screen. Tapping it (or an
/// example chip) opens the real chat experience as a full-screen page —
/// the inline card was too small to read as a chat thread.
class ChatScheduleEntryCard extends StatelessWidget {
  const ChatScheduleEntryCard({super.key, required this.onApplied});

  final VoidCallback onApplied;

  static const List<(String, String)> _examples = <(String, String)>[
    ('SNS 업무시간', '평일 9시부터 18시까지 SNS 막아줘'),
    ('게임 야간', '매일 밤 10시부터 새벽 2시까지 게임 막아줘'),
    ('인터넷 야간', '앞으로 인터넷 브라우저 인터넷을 밤 11시부터 다음날 7시까지 막아줘'),
    ('유튜브 15분', '주말 오전 10시부터 유튜브 15분만'),
    ('성인 항상', '성인 사이트는 항상 막아줘'),
  ];

  void _open(BuildContext context, {String? prefill}) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ChatScheduleFullScreen(
          onApplied: onApplied,
          initialMessage: prefill,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.muted.withValues(alpha: 0.28)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.chat_bubble_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '채팅으로 스케줄 만들기',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '말로 스케줄을 만들 수 있어요. 눌러서 채팅창을 열어보세요.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _examples
                    .map(
                      (record) => ActionChip(
                        avatar: const Icon(Icons.bolt_outlined, size: 16),
                        label: Text(record.$1),
                        onPressed: () => _open(context, prefill: record.$2),
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact button meant for `ScheduleEditScreen` — opens the chat scoped to
/// one specific schedule (via [ChatScheduleFullScreen.scopedScheduleId]), so
/// every message edits *that* schedule directly instead of the usual
/// create-or-match-by-name flow.
class ScheduleChatEditButton extends StatelessWidget {
  const ScheduleChatEditButton({
    super.key,
    required this.scheduleId,
    required this.scheduleName,
    required this.onApplied,
  });

  final String scheduleId;
  final String scheduleName;
  final VoidCallback onApplied;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () {
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => ChatScheduleFullScreen(
              onApplied: onApplied,
              scopedScheduleId: scheduleId,
              scopedScheduleName: scheduleName,
            ),
          ),
        );
      },
      icon: const Icon(Icons.chat_bubble_outline, size: 16),
      label: const Text('채팅으로 이 스케줄 편집'),
    );
  }
}

/// Full-screen chat page — real conversation thread, large bubbles, input
/// pinned to the bottom. Hosts the exact same schedule-creation logic that
/// used to live in the small inline card.
///
/// When [scopedScheduleId] is set (opened from `ScheduleEditScreen`), every
/// message edits that exact schedule — no "create new vs modify existing"
/// question, no name-matching to a different schedule. Its conversation
/// thread is also kept separate from the general chat tab's thread.
class ChatScheduleFullScreen extends StatefulWidget {
  const ChatScheduleFullScreen({
    super.key,
    required this.onApplied,
    this.initialMessage,
    this.scopedScheduleId,
    this.scopedScheduleName,
  });

  final VoidCallback onApplied;
  final String? initialMessage;
  final String? scopedScheduleId;
  final String? scopedScheduleName;

  @override
  State<ChatScheduleFullScreen> createState() => _ChatScheduleFullScreenState();
}

class _ChatScheduleFullScreenState extends State<ChatScheduleFullScreen> {
  static const String _kThreadPrefsKey = 'chat_schedule_thread_v1';

  bool get _scoped => widget.scopedScheduleId != null;

  String get _threadPrefsKey => _scoped
      ? 'chat_schedule_thread_scoped_${widget.scopedScheduleId}'
      : _kThreadPrefsKey;

  _ChatLine _welcomeLine() => _scoped
      ? _ChatLine(
          fromUser: false,
          text:
              '"${widget.scopedScheduleName}" 스케줄을 채팅으로 편집합니다. 여기서 하는 말은 '
              '항상 이 스케줄에만 적용돼요. 예: "유튜브 추가해줘", "밤 11시부터 아침 7시까지로 바꿔줘".',
        )
      : const _ChatLine(fromUser: false, text: _kWelcomeLine);

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatLine> _lines = <_ChatLine>[
    const _ChatLine(fromUser: false, text: _kWelcomeLine),
  ];
  ChatSchedulePreview? _preview;
  List<ChatSchedulePendingEdit> _pending = const <ChatSchedulePendingEdit>[];
  Timer? _pendingTimer;
  bool _busy = false;
  String? _error;

  /// The message currently being previewed. Apply must use this exact text so
  /// changing the input field after preview cannot apply a different request.
  String? _lastMessage;
  String? _resolution;
  String? _parserMessage;
  bool _openAiApiConnected = false;

  /// Groups every turn in this panel's lifetime under one id so the audit
  /// log can answer "which conversation was this schedule formed at the end
  /// of" — see chat_schedule_audit_log_service.dart.
  final String _conversationId =
      'conv_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
  int _turnIndex = 0;

  @override
  void initState() {
    super.initState();
    _refreshPending(processDue: true);
    _pendingTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshPending(processDue: true),
    );
    _initThread();
    unawaited(_loadOpenAiApiState());
  }

  @override
  void dispose() {
    _pendingTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Loads the persisted conversation (if any) before anything else runs —
  /// the thread survives closing/reopening this page until the user taps
  /// "새 대화 시작". Only after that finishes do we run an example-chip
  /// prefill, so it can't race the load and get clobbered.
  Future<void> _initThread() async {
    final List<_ChatLine> loaded = await _loadPersistedLines();
    if (loaded.isNotEmpty && mounted) {
      setState(() {
        _lines
          ..clear()
          ..addAll(loaded);
      });
      _scrollToBottom();
    } else if (_scoped && mounted) {
      setState(() {
        _lines
          ..clear()
          ..add(_welcomeLine());
      });
    }
    if (widget.initialMessage != null && widget.initialMessage!.isNotEmpty) {
      _controller.text = widget.initialMessage!;
      if (mounted) await _previewMessage();
    }
  }

  Future<void> _loadOpenAiApiState() async {
    final bool connected = await ChatGptPlanService.instance.hasConnection;
    if (mounted) setState(() => _openAiApiConnected = connected);
  }

  Future<void> _configureOpenAiApi() async {
    await showAiConnectionDialog(context);
    await _loadOpenAiApiState();
  }

  List<_ChatAction> _actionsForKind(String? kind) {
    if (kind == _kKindTimeLockNudge) {
      return <_ChatAction>[
        _ChatAction(label: '타임락 15분 켜기', onTap: _enableTimeLockNudge),
        _ChatAction(label: '왜 권장하나요?', onTap: _explainTimeLock),
      ];
    }
    return const <_ChatAction>[];
  }

  Future<List<_ChatLine>> _loadPersistedLines() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_threadPrefsKey);
      if (raw == null || raw.isEmpty) return const <_ChatLine>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <_ChatLine>[];
      return decoded.whereType<Map>().map((Object? m) {
        final Map<Object?, Object?> map = m as Map<Object?, Object?>;
        final String? kind = map['kind'] as String?;
        return _ChatLine(
          fromUser: map['fromUser'] == true,
          text: '${map['text']}',
          kind: kind,
          actions: _actionsForKind(kind),
        );
      }).toList();
    } catch (_) {
      return const <_ChatLine>[];
    }
  }

  Future<void> _persistLines() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<Map<String, Object?>> encoded = _lines
          .map(
            (_ChatLine l) => <String, Object?>{
              'fromUser': l.fromUser,
              'text': l.text,
              'kind': l.kind,
            },
          )
          .toList();
      await prefs.setString(_threadPrefsKey, jsonEncode(encoded));
    } catch (_) {
      /* thread just won't survive restart this time */
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _refreshPending({bool processDue = false}) async {
    if (processDue) {
      final List<ChatScheduleApplyResult> applied =
          await ChatScheduleApplyService.instance.processDuePendingEdits();
      if (applied.isNotEmpty && mounted) {
        widget.onApplied();
        setState(() {
          for (final ChatScheduleApplyResult r in applied) {
            _lines.add(_ChatLine(fromUser: false, text: r.message));
          }
        });
        unawaited(_persistLines());
        _scrollToBottom();
      }
    }
    final List<ChatSchedulePendingEdit> pending = await ChatScheduleApplyService
        .instance
        .pendingEdits();
    if (!mounted) return;
    setState(() => _pending = pending);
  }

  Future<void> _cancelPending(String id) async {
    await ChatScheduleApplyService.instance.cancelPendingEdit(id);
    await _refreshPending();
  }

  Future<void> _previewMessage() async {
    if (_busy) return;
    final String message = _controller.text.trim();
    if (message.isEmpty) return;
    setState(() {
      _resolution = null;
      _lastMessage = message;
      _parserMessage = null;
      _lines.add(_ChatLine(fromUser: true, text: message));
    });
    unawaited(_persistLines());
    _scrollToBottom();
    await _runPreview(message);
  }

  /// User answered the "modify existing vs create new" question. That choice
  /// is the confirmation, so commit immediately instead of showing another
  /// preview/confirm loop.
  Future<void> _chooseResolution(String value, String choiceLabel) async {
    final String? message = _lastMessage;
    if (message == null || _busy) return;
    setState(() {
      _resolution = value;
      _lines.add(_ChatLine(fromUser: true, text: choiceLabel));
    });
    unawaited(_persistLines());
    _scrollToBottom();
    await _commitMessage(message, resolution: value);
  }

  Future<void> _runPreview(String message) async {
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      String? parserMessage;
      if (!ChatScheduleIntentParser.isYoutubeBudgetExemptionRequest(message) &&
          await ChatGptPlanService.instance.hasConnection) {
        final List<_ChatLine> contextLines = _lines
            .where((_ChatLine line) => !line.fromUser || line.text != message)
            .toList();
        final String recent = contextLines
            .skip(max(0, contextLines.length - 8))
            .map(
              (_ChatLine line) =>
                  '${line.fromUser ? '사용자' : 'Focus Fense'}: ${line.text}',
            )
            .join('\n');
        parserMessage = await ChatGptPlanService.instance
            .normalizeScheduleRequest(
              message: message,
              recentConversation: recent,
              currentSchedule: widget.scopedScheduleName ?? '',
            );
      }
      final ChatSchedulePreview p = await ChatScheduleApplyService.instance
          .preview(
            message,
            resolution: _resolution,
            forceScheduleId: widget.scopedScheduleId,
            parserMessage: parserMessage,
          );
      if (!mounted) return;
      setState(() {
        _parserMessage = parserMessage;
        _preview = p;
        _lines.add(
          _ChatLine(
            fromUser: false,
            text:
                '${parserMessage == null ? '' : 'ChatGPT 해석: $parserMessage\n\n'}${p.summary}',
          ),
        );
      });
      unawaited(_persistLines());
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e'.replaceFirst('FormatException: ', '');
        _lines.add(_ChatLine(fromUser: false, text: _error!));
      });
      unawaited(_persistLines());
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyPreview() async {
    final ChatSchedulePreview? p = _preview;
    if (p == null || _busy) return;
    if (p.needsResolutionChoice) return;
    final String message = (_lastMessage ?? _controller.text).trim();
    if (message.isEmpty) return;
    await _commitMessage(message, resolution: _resolution);
  }

  Future<void> _commitMessage(String message, {String? resolution}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ChatScheduleApplyResult result = await ChatScheduleApplyService
          .instance
          .apply(
            message,
            resolution: resolution,
            forceScheduleId: widget.scopedScheduleId,
            parserMessage: _parserMessage,
          );
      if (!mounted) return;
      setState(() {
        _lines.add(_ChatLine(fromUser: false, text: result.message));
        _preview = null;
        _controller.clear();
        _resolution = null;
        _lastMessage = null;
        _parserMessage = null;
      });
      unawaited(_persistLines());
      _scrollToBottom();
      unawaited(
        ChatScheduleAuditLogService.instance.record(
          conversationId: _conversationId,
          turnIndex: _turnIndex++,
          message: message,
          result: result,
          conversation: _lines
              .map(
                (_ChatLine l) => <String, String>{
                  'from': l.fromUser ? 'user' : 'assistant',
                  'text': l.text,
                },
              )
              .toList(),
        ),
      );
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      await _refreshPending();
      if (result.pendingEdit == null) widget.onApplied();
      if (result.ok &&
          result.pendingEdit == null &&
          !result.preview.intent.youtubeBudgetExemption) {
        await _addFollowUpLines(result.preview.intent);
      }
      messenger.showSnackBar(SnackBar(content: Text(result.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Adds context-aware follow-up chat lines after a successful apply:
  /// a Time Lock nudge for adult-content blocks, an addiction-awareness
  /// one-liner, and a follow-up hint for categories that usually need more
  /// than one command (finance/SNS/shopping/gaming).
  Future<void> _addFollowUpLines(ChatScheduleIntent intent) async {
    final ChatScheduleCategory? category = intent.category;
    if (category == null) return;
    if (!mounted) return;

    if (category == ChatScheduleCategory.adult && !intent.requestsTimeLock) {
      final int current = await ChatScheduleApplyService.instance
          .currentTimeLockMinutes();
      if (!mounted) return;
      if (current <= 0) {
        setState(() {
          _lines.add(
            _ChatLine(
              fromUser: false,
              text: '이 차단과 함께 타임락을 켜면 순간적인 충동으로 설정을 바로 풀지 못해 절제에 도움이 됩니다.',
              kind: _kKindTimeLockNudge,
              actions: _actionsForKind(_kKindTimeLockNudge),
            ),
          );
        });
        unawaited(_persistLines());
        _scrollToBottom();
      }
    }

    if (category == ChatScheduleCategory.adult ||
        category == ChatScheduleCategory.gaming) {
      setState(() {
        _lines.add(
          _ChatLine(
            fromUser: false,
            text: '오늘의 이야기 · ${DailyAwarenessService.instance.todayMessage()}',
          ),
        );
      });
      unawaited(_persistLines());
      _scrollToBottom();
    }

    if (category == ChatScheduleCategory.finance ||
        category == ChatScheduleCategory.sns ||
        category == ChatScheduleCategory.shopping) {
      setState(() {
        _lines.add(
          _ChatLine(
            fromUser: false,
            text:
                '더 막을 앱 이름이나 URL이 있으면 이어서 말씀해주세요 — 같은 스케줄에 추가할게요. '
                '이 기기에 설치된 비슷한 앱들도 함께 막으면 더 완전하게 차단할 수 있어요.',
          ),
        );
      });
      unawaited(_persistLines());
      _scrollToBottom();
    }
  }

  Future<void> _enableTimeLockNudge() async {
    await ChatScheduleApplyService.instance.enableTimeLock(minutes: 15);
    if (!mounted) return;
    setState(() {
      _lines.add(const _ChatLine(fromUser: false, text: '타임락 15분을 켰습니다.'));
    });
    unawaited(_persistLines());
    _scrollToBottom();
  }

  void _explainTimeLock() {
    setState(() {
      _lines.add(
        const _ChatLine(
          fromUser: false,
          text:
              '타임락은 차단 우회 시도가 감지되면 일정 시간(예: 15분) 동안 설정 변경·해제를 막는 기능이에요. '
              '순간적인 충동이 지나갈 때까지 시간 여유를 강제로 만들어줘서, "지금만 잠깐"이라는 생각으로 '
              '바로 풀어버리는 것을 막아줍니다.',
        ),
      );
    });
    unawaited(_persistLines());
    _scrollToBottom();
  }

  /// "새 대화 시작" — clears the persisted thread back to the welcome line.
  /// Nothing is cleared until the user explicitly confirms this.
  Future<void> _startNewConversation() async {
    if (_busy) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('새 대화 시작'),
        content: const Text('지금까지의 채팅 기록이 모두 지워집니다. 새로 시작할까요?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('지우고 새로 시작'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _lines
        ..clear()
        ..add(_welcomeLine());
      _preview = null;
      _error = null;
      _lastMessage = null;
      _resolution = null;
      _controller.clear();
    });
    await _persistLines();
  }

  /// Copies the entire visible conversation (not just the audit JSON) as
  /// plain text, stamped with app version + export time, so it can be
  /// pasted straight into a Claude/Codex session for a future upgrade pass.
  Future<void> _copyFullConversation() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final BuildIdentity identity = await BuildIdentityService.instance
          .current();
      final DateTime now = DateTime.now();
      final StringBuffer buffer = StringBuffer()
        ..writeln('=== Focus Fense · 채팅으로 스케줄 만들기 전체 대화 ===')
        ..writeln(
          '앱 버전: ${identity.version}+${identity.buildNumber} (${identity.operatingSystem})',
        )
        ..writeln('내보낸 시각: ${now.toIso8601String()}')
        ..writeln('메시지 수: ${_lines.length}')
        ..writeln();
      for (final _ChatLine line in _lines) {
        buffer.writeln('[${line.fromUser ? '사용자' : 'AI'}] ${line.text}');
      }
      await Clipboard.setData(ClipboardData(text: buffer.toString()));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '전체 채팅 복사됨 · v${identity.version}+${identity.buildNumber} · '
            '${_lines.length}개 메시지 (클립보드)',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('전체 채팅 복사 실패: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: AppColors.ink,
        title: Text(
          _scoped ? '채팅으로 "${widget.scopedScheduleName}" 편집' : '채팅으로 스케줄 만들기',
        ),
        actions: <Widget>[
          IconButton(
            onPressed: _busy ? null : _copyDebugBackup,
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: '개발자용: 채팅 스케줄 감사 로그(최근 7일, 버전+날짜 포함) 백업을 클립보드로 복사',
          ),
          IconButton(
            onPressed: _busy ? null : _copyFullConversation,
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: '개발자용: 전체 채팅 대화를 텍스트로 클립보드에 복사',
          ),
          IconButton(
            onPressed: _busy ? null : _startNewConversation,
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '새 대화 시작 (지금까지의 채팅 기록 지우기)',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _configureOpenAiApi,
                  icon: Icon(
                    !_openAiApiConnected
                        ? Icons.login
                        : Icons.verified_user_outlined,
                  ),
                  label: Text(
                    !_openAiApiConnected ? 'GPT · AI 로그인' : 'GPT · AI · 연결됨',
                  ),
                ),
              ),
            ),
            // Once the conversation has actually started, the example chips
            // just eat vertical space above the thread without adding value
            // — collapse them back to a fresh-start affordance only.
            if (_lines.length <= 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    _ExampleButton(
                      label: 'SNS 업무시간',
                      value: '평일 9시부터 18시까지 SNS 막아줘',
                      onPick: _useExample,
                    ),
                    _ExampleButton(
                      label: '게임 야간',
                      value: '매일 밤 10시부터 새벽 2시까지 게임 막아줘',
                      onPick: _useExample,
                    ),
                    _ExampleButton(
                      label: '인터넷 야간',
                      value: '앞으로 인터넷 브라우저 인터넷을 밤 11시부터 다음날 7시까지 막아줘',
                      onPick: _useExample,
                    ),
                    _ExampleButton(
                      label: '유튜브 15분',
                      value: '주말 오전 10시부터 유튜브 15분만',
                      onPick: _useExample,
                    ),
                    _ExampleButton(
                      label: '성인 항상',
                      value: '성인 사이트는 항상 막아줘',
                      onPick: _useExample,
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.separated(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                itemCount: _lines.length,
                separatorBuilder: (BuildContext context, int index) =>
                    const SizedBox(height: 10),
                itemBuilder: (BuildContext context, int index) {
                  final _ChatLine line = _lines[index];
                  return Align(
                    alignment: line.fromUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.78,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: line.fromUser
                              ? AppColors.accent.withValues(alpha: 0.12)
                              : AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: AppColors.muted.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                line.text,
                                style: Theme.of(
                                  context,
                                ).textTheme.bodyMedium?.copyWith(height: 1.4),
                              ),
                              if (line.actions.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: line.actions
                                      .map(
                                        (_ChatAction a) => ActionChip(
                                          label: Text(a.label),
                                          onPressed: a.onTap,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      )
                                      .toList(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _error!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.danger),
                ),
              ),
            if (_preview != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _PreviewCard(
                  preview: _preview!,
                  onApply: _applyPreview,
                  onChooseResolution: _chooseResolution,
                ),
              ),
            if (_pending.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _PendingEditsCard(
                  pending: _pending,
                  onCancel: _cancelPending,
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(
                  top: BorderSide(
                    color: AppColors.muted.withValues(alpha: 0.2),
                  ),
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: AppColors.ink.withValues(alpha: 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _previewMessage(),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          hintText: '매일 밤 10시부터 새벽 2시까지 게임 막아줘',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _busy ? null : _previewMessage,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_outlined),
                      tooltip: '미리보기',
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

  Future<void> _copyDebugBackup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final int entryCount =
          (await ChatScheduleAuditLogService.instance.recentEntries()).length;
      final String json = await ChatScheduleAuditLogService.instance
          .exportForBackup();
      final BuildIdentity identity = await BuildIdentityService.instance
          .current();
      await Clipboard.setData(ClipboardData(text: json));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '디버그 백업 복사됨 · v${identity.version}+${identity.buildNumber} · '
            '${DateTime.now().toIso8601String().substring(0, 10)} · 최근 7일 $entryCount건 (클립보드)',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('백업 복사 실패: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _useExample(String value) {
    _controller.text = value;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: value.length),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.preview,
    required this.onApply,
    required this.onChooseResolution,
  });

  final ChatSchedulePreview preview;
  final VoidCallback onApply;
  final void Function(String value, String choiceLabel) onChooseResolution;

  @override
  Widget build(BuildContext context) {
    if (preview.needsResolutionChoice) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.28)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                preview.summary,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: () => onChooseResolution(
                      kChatScheduleResolutionExisting,
                      '기존 "${preview.resolutionExistingName}"에 적용',
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('기존 스케줄에 적용'),
                  ),
                  FilledButton.icon(
                    onPressed: () => onChooseResolution(
                      kChatScheduleResolutionNew,
                      '새 "${preview.resolutionNewName}"로 적용',
                    ),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('새 스케줄로 적용'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final bool blocked =
        !preview.intent.listYoutubeBudgetExemptions &&
        preview.domainTargets.isEmpty &&
        preview.keywordTargets.isEmpty &&
        preview.appTargets.isEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              preview.summary,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                if (preview.intent.youtubeBudgetExemption)
                  const _ChipText('시간 집계 예외')
                else ...[
                  _ChipText('${preview.willCreateSchedule ? '새' : '기존'} 스케줄'),
                  _ChipText(_timeLabel(preview.intent)),
                  _ChipText(preview.intent.modeLabel),
                  if (preview.intent.mode == ChatScheduleMode.limit &&
                      preview.intent.usageBudgetPolicy != null)
                    _ChipText(
                      '${preview.intent.usageBudgetPolicy!.burstCapMinutes}분씩 · 하루 ${preview.intent.usageBudgetPolicy!.dailyCapMinutes}분',
                    ),
                  _ChipText('도메인 ${preview.domainTargets.length}'),
                  _ChipText('키워드 ${preview.keywordTargets.length}'),
                  _ChipText('앱 ${preview.appTargets.length}'),
                  _ChipText('중복 ${preview.duplicateRuleCount}'),
                  if (preview.requiresTimeLock)
                    _ChipText('타임락 ${preview.timeLockMinutes}분'),
                ],
              ],
            ),
            if (preview.warnings.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              ...preview.warnings.map(
                (String warning) => Text(
                  warning,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.warning,
                    height: 1.25,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: blocked ? null : onApply,
                icon: const Icon(Icons.check),
                label: const Text('이대로 적용'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _timeLabel(ChatScheduleIntent intent) {
    if (intent.blockAlways) return '하루 종일';
    String hhmm(int minute) {
      final int m = minute.clamp(0, 1440);
      final int h = m ~/ 60;
      final int mm = m % 60;
      return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
    }

    return '${hhmm(intent.startMinutes)}-${hhmm(intent.endMinutes)}';
  }
}

class _PendingEditsCard extends StatelessWidget {
  const _PendingEditsCard({required this.pending, required this.onCancel});

  final List<ChatSchedulePendingEdit> pending;
  final ValueChanged<String> onCancel;

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.timer_outlined, size: 18),
                const SizedBox(width: 8),
                Text(
                  '예약된 스케줄 수정',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final ChatSchedulePendingEdit edit in pending) ...<Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(height: 1.3),
                        children: <InlineSpan>[
                          TextSpan(text: '${edit.scheduleName} · '),
                          TextSpan(
                            text: _remainingLabel(edit.remaining(now)),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: edit.remaining(now).inMinutes < 5
                                  ? AppColors.danger
                                  : AppColors.warning,
                            ),
                          ),
                          TextSpan(text: '\n${edit.summary}'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => onCancel(edit.id),
                    icon: const Icon(Icons.cancel_outlined, size: 16),
                    label: const Text('취소'),
                  ),
                ],
              ),
              if (edit != pending.last) const Divider(height: 14),
            ],
          ],
        ),
      ),
    );
  }

  static String _remainingLabel(Duration d) {
    if (d.inSeconds <= 0) return '곧 적용';
    final int hours = d.inHours;
    final int minutes = d.inMinutes.remainder(60);
    if (hours > 0) return '$hours시간 $minutes분 남음';
    return '${minutes < 1 ? 1 : minutes}분 남음';
  }
}

class _ExampleButton extends StatelessWidget {
  const _ExampleButton({
    required this.label,
    required this.value,
    required this.onPick,
  });

  final String label;
  final String value;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: const Icon(Icons.bolt_outlined, size: 16),
      label: Text(label),
      onPressed: () => onPick(value),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ChipText extends StatelessWidget {
  const _ChipText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.muted.withValues(alpha: 0.24)),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

final class _ChatLine {
  const _ChatLine({
    required this.fromUser,
    required this.text,
    this.actions = const <_ChatAction>[],
    this.kind,
  });
  final bool fromUser;
  final String text;

  /// Inline "easy response" buttons rendered under this line (e.g. the
  /// Time Lock nudge's "왜 권장하나요?" — tapping answers immediately with no
  /// extra typing needed).
  final List<_ChatAction> actions;

  /// Tag identifying which [actions] to reattach after loading a persisted
  /// line from disk — closures can't be serialized, so on reload we look
  /// this up via `_actionsForKind` instead. Null for plain lines.
  final String? kind;
}

final class _ChatAction {
  const _ChatAction({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
}
