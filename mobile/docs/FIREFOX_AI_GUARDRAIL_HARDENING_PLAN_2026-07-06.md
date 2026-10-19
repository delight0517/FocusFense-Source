# Firefox / AI 작업 안전망 강화 계획 (2026-07-06)

## 배경

사용자가 "Firefox 플러그인이 또 터졌다"고 보고. 라이브 점검 결과 **점검 시점에는
실제로 정상**이었다 (레지스트리 강제설치 정책 `HKLM\...\Policies\Mozilla\Firefox\
ExtensionSettings` 존재+올바른 값, `sixvpn_blocker_signed.xpi` 서명 확인,
ProgramData 배포본 일치, `Verify-Firefox-Integrity` 로그 하루 종일 healthy).

하지만 이번 점검 중 **실제로 방어되지 않는 구멍**을 하나 발견했다: 기존 훅
(`Guard-ProtectedPaths.ps1`, `Guard-BashWrites.ps1`)은 전부 **파일 경로**만
검사한다. `mobile/CLAUDE.md`에는 "레지스트리 Run 키·예약작업을 절대 건드리지
말 것"이라는 ABSOLUTE RULE이 문서로 있지만, 이건 Firefox 소스 파일 규칙과 달리
**훅 코드로 강제되지 않고 있다** — AI 세션이 `reg delete`, `Remove-ItemProperty`,
`Unregister-ScheduledTask` 같은 명령을 실행해도 지금은 그냥 통과된다.

이 문서는 그 구멍을 메우는 구체적인 설계다. **코드 변경은 아직 적용 안 함** —
사용자가 계획만 먼저 보고 싶다고 해서 설계만 정리.

## 현재 있는 방어선 (변경 없음, 그대로 유지)

| 계층 | 무엇을 막나 | 위치 |
|---|---|---|
| 1. 파일 편집 훅 | Edit/Write/MultiEdit로 `assets/browser_extensions/firefox/*`, 서명 아티팩트, `.claude/*`, agent-destruct 파일 등 직접 수정 | `Guard-ProtectedPaths.ps1` |
| 2. 셸 명령 훅 | Bash/PowerShell로 위와 같은 경로에 대한 write/delete-shaped 명령 (`Copy-Item`, `rm`, 리다이렉트 등) | `Guard-BashWrites.ps1` |
| 3. 서명 무결성 자가치유 | 부팅+30분: 서명 XPI 존재·서명마커·manifest id 일치·소스 드리프트·ProgramData 사본 일치 | `FirefoxExtensionIntegrityGuardService` |
| 4. 정책 레지스트리 자가치유 | Chrome/Edge/Firefox 레지스트리 정책 값 자체를 앱 실행 중 40곳+ 지점에서 주기적 재검증·재적용 | `WindowsExtensionGuardService.verifyAllPolicies()` |
| 5. 소유자 파괴 게이트 | Tier C 파일(가드 자기 자신 포함)은 앱 내 "AI 파괴 명령 잠금" 토큰 없이는 절대 편집 불가 | `agent_destruct_gate_service.dart` + `Verify-AgentDestruct-Override.ps1` |

**결론: 소스/서명/레지스트리 "값"에 대한 자가치유는 이미 충분히 두텁다 (오히려
서비스가 233개로 늘어난 원인 중 하나가 이 영역 중복 — 별도 정리 필요, 아래
"부수 관찰" 참고). 진짜 구멍은 "AI가 직접 실행하는 셸 명령"이 이 값들을
**지우는** 경로에 대한 실시간 차단이 없다는 것.**

## 제안하는 추가 계층 — 레지스트리/예약작업 셸 가드

### 1. `.claude/protected_paths.json`에 새 섹션 2개 추가

```jsonc
"registryRules": [
  {
    "id": "browser_policy_registry_write",
    "tier": "B",
    "keyPrefixes": [
      "hklm\\software\\policies\\mozilla\\firefox",
      "hkcu\\software\\policies\\mozilla\\firefox",
      "hklm\\software\\policies\\google\\chrome",
      "hkcu\\software\\policies\\google\\chrome",
      "hklm\\software\\policies\\microsoft\\edge",
      "hkcu\\software\\policies\\microsoft\\edge"
    ],
    "reason": "이 레지스트리 키들이 Firefox/Chrome/Edge 확장 강제설치·잠금 정책의 실제 실행 지점. 값을 직접 덮어쓰면 앱의 자가치유 로직과 어긋난 상태가 생길 수 있음.",
    "instructions": "정책 값 수정이 정말 필요하면 mobile/tools/FIREFOX_EDIT_UNLOCKED 센티널(기존 것 재사용)로 2시간 우회 후, 반드시 WindowsExtensionGuardService.verifyAllPolicies(force:true)로 재검증."
  }
],
"registryDeleteRules": [
  {
    "id": "browser_policy_registry_delete",
    "tier": "C",
    "keyPrefixes": [ /* 위와 동일한 6개 경로 */ ],
    "reason": "정책 키/값 삭제는 Firefox 강제설치를 즉시 무력화시키고, Firefox가 이미 설치된 확장을 스스로 비활성화하게 만들 수 있음 — 파일 삭제와 동일하게 취급, 우회 센티널 없음.",
    "instructions": "Verify-AgentDestruct-Override.ps1 소유자 토큰 필요."
  },
  {
    "id": "autostart_run_key_delete",
    "tier": "C",
    "keyPrefixes": ["hkcu\\software\\microsoft\\windows\\currentversion\\run"],
    "valueNames": ["sixvpnblocker"],
    "reason": "mobile/CLAUDE.md 기존 ABSOLUTE RULE(2026-07-05)을 훅으로 강제 — 지금까지는 문서로만 존재."
  }
],
"scheduledTaskRules": [
  {
    "id": "resilience_scheduled_tasks",
    "tier": "C",
    "taskNames": [
      "sixvpnblockerwatchdog", "sixvpnblockerwatchdog2", "sixvpnblockerautostart",
      "sixvpnblockerbootguard", "sixvpnblockerofflineguard",
      "sixvpnblockerelevatedmaintain", "sixvpnbrowserguard", "sixvpntier3watchdog"
    ],
    "deleteVerbs": ["unregister-scheduledtask", "schtasks /delete", "schtasks.exe /delete"],
    "reason": "mobile/CLAUDE.md 기존 ABSOLUTE RULE(2026-07-05) 훅화. Disable-ScheduledTask(임시 일시정지)는 계속 허용 — 문서에 이미 '같은 턴에 재활성화' 조건부 허용이 명시돼 있어 하드 블록하지 않고 감사 로그만 남김."
  }
]
```

### 2. `Guard-BashWrites.ps1` 로직 확장

- `$regWriteVerbs = @('set-itemproperty', 'new-itemproperty')` + `reg add`/`reg import` 패턴(단어 경계 필요 — `reg.exe`가 포함된 정상적인 조회 명령까지 막지 않도록 `reg\s+add`, `reg\s+import`만 검사)
- `$regDeleteVerbs = @('remove-itemproperty')` + `reg delete` 패턴
- 매칭 대상은 명령 문자열에 `registryRules`/`registryDeleteRules`의 `keyPrefixes`가 등장하는지 (백슬래시/콜론 표기 차이 정규화 — `HKLM:\...`, `HKLM\...`, `hklm:\...` 모두 같은 걸로 취급)
- 예약작업: `unregister-scheduledtask`, `schtasks` + `/delete` 조합을 별도 검사 함수로 추가, `taskNames` 중 하나라도 명령에 등장하면 Tier C
- 기존 파일 검사 로직과 같은 흐름(허용된 스크립트 화이트리스트 → write/delete 판별 → 티어 판정 → 센티널/오버라이드 확인 → 감사 로그) 그대로 재사용, 새 규칙 배열만 추가로 순회

### 3. 왜 이 정도 선에서 멈추나 (과설계 방지)

- **값을 쓰는 것(B)**과 **키/값을 지우는 것(C)**만 구분하면 충분 — 지금 파일 규칙과
  정확히 같은 철학이라 새로 학습할 개념이 없음.
- 레지스트리 "읽기"(`reg query`, `Get-ItemProperty`)는 지금처럼 완전 자유 —
  진단·확인 작업까지 막으면 이번처럼 상태 점검 자체가 막혀버림 (이번 세션에서
  `ls`/`cat`이 오탐으로 막혔던 경험 참고 — 새 정규식도 반드시 "실제 쓰기/삭제
  동사 + 실제 경로 등장" 두 조건 다 만족해야 걸리게, 파일 훅과 동일 원칙 유지).
- Chrome/Edge까지 넣은 이유: 사용자는 Firefox만 언급했지만 매커니즘이
  100% 동일하고 코드 한 배열 추가 비용밖에 안 들어서 — 굳이 Firefox만 반쪽으로
  막을 이유가 없음.

## 부수 관찰 (별도 처리 권장, 이번 계획에는 포함 안 함)

- `WindowsExtensionGuardService.verifyAllPolicies()`를 호출하는 지점이 40곳
  이상 — `docs/BLOCK_ENGINE_DISORDER_AUDIT_2026-07-05.md`가 지적한 "질서 밖"
  패턴의 연장선. 지금 당장 정상 동작하니 손대지 않는 게 맞지만, 5계층 리팩터
  재개 시(`project_enforcement_architecture` 메모리 참고) 이 중복도 같이
  정리 대상.
- 프로세스명이 `six_clean_room.exe` → `6VPNBlocker.exe`로 바뀐 걸로 보이는데
  `mobile/CLAUDE.md`의 "ABSOLUTE RULE" 문구들은 여전히 `six_clean_room.exe`
  기준으로 적혀 있음. watchdog은 두 이름 다 인식해서 지금은 문제없지만, 문서가
  실제 바이너리명과 어긋나 있으면 다음 세션이 `Get-Process six_clean_room`으로
  "앱이 꺼졌다"고 오판할 위험 있음 (이번 세션에서 실제로 그럴 뻔함).

## 적용 절차 (사용자가 준비되면)

1. 사용자가 앱 **설정 → 진단 → "AI 파괴 명령 잠금"**에서 소유자 오버라이드
   토큰 발급 후 전달.
2. `mobile/tools/AGENT_DESTRUCT_CANDIDATE`에 토큰 기록 → `.claude/
   protected_paths.json` 편집 1회 허용됨.
3. 위 3개 섹션(`registryRules`, `registryDeleteRules`, `scheduledTaskRules`)
   추가.
4. `Guard-BashWrites.ps1`에 레지스트리/예약작업 검사 로직 추가.
5. 회귀 테스트: 기존 세션에서 했던 것과 같은 방식으로 "차단돼야 하는 명령"과
   "정상 통과해야 하는 명령"(`reg query`, `Get-ScheduledTaskInfo` 등 읽기
   전용) 양쪽 다 실제로 hookInput JSON을 스크립트에 파이프해서 검증.
6. `mobile/CLAUDE.md`에 새 ABSOLUTE RULE 섹션 추가 (레지스트리/예약작업도
   이제 훅으로 강제된다는 사실 기록) + 프로세스명 `6VPNBlocker.exe` 표기로
   업데이트.
7. pubspec 빌드 번호는 Dart 코드 변경이 없으므로 불필요 (훅/설정 파일만
   변경 — `mobile/CLAUDE.md`의 "docs/*, .claude/* 등은 리빌드 불필요" 예외
   적용).
