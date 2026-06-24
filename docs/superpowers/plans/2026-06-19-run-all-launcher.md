# Plan: `/ganpan:run-all` — one-command lane launcher

> 검토용 계획 문서. 구현 전 리뷰 후 진행합니다.

## Context

지금 Ganpan을 돌리려면 **터미널 4개**를 띄워 각각 long-running 레인 루프를 실행해야 합니다:

- Triager — `/loop 10m /ganpan:triage`
- Coder — `/loop /ganpan:work-issue`
- Reviewer — `/loop 5m /ganpan:review-queue`
- QA — `/ganpan:qa-check` (under `/goal`)

사용자는 `claude agents` (Agent View)로 Claude Code를 실행하며, 4개 터미널을 따로 띄우는 대신 **한 번에 4개 레인을 시작하는 ganpan 커맨드**를 원합니다.

**핵심 플랫폼 제약 (검증됨):** `claude dispatch` CLI는 **없습니다**. `claude agents`는 Agent View TUI를 열고, `claude agents --json`은 세션을 *나열*만 할 뿐 비대화형으로 새 세션을 dispatch할 수 없습니다. 따라서 커맨드가 셸에서 4개의 Agent View 세션을 띄우는 건 불가능합니다. 실행 중인 세션 안에서 레인을 띄우는 유일한 방법은 **Agent tool + `run_in_background: true`** 이며, 이렇게 띄운 백그라운드 에이전트는 Agent View에 표시됩니다.

**선택한 접근 (사용자 선택):** 새 커맨드 `/ganpan:run-all` — **fan-out 런처**. 매 실행 시 4개의 백그라운드 에이전트(레인당 1개)를 spawn하고, 각 에이전트는 자기 레인을 **한 번의 bounded sweep**으로 처리한 뒤 요약을 보고하고 종료합니다(대부분 한 줄 요약, **QA는 요약 줄 + 전체 출력 블록**; **Coder만 sweep당 최대 3 사이클**). 백그라운드 에이전트는 "작업하고 보고"하도록 설계되어 무한 루프에 맞지 않으므로, 연속 운영은 네이티브 스케줄러로 감싸서 얻습니다: **`/loop 20m /ganpan:run-all`** → 매 틱마다 4개가 동시에 떠서 처리하고 종료. bare로 실행하면 1회 sweep. 이 방식은 세션 수명에 의존하지 않고 cadence + 7일 지속성 + self-healing(죽은 에이전트는 다음 틱에 재생성)을 제공합니다.

## Design notes

- **단일 출처 유지:** run-all.md는 **레인 로직을 담지 않습니다**. 각 spawn된 에이전트가 자기 레인 커맨드 파일을 *읽고 따르도록* 지시받으므로 triage.md / work-issue.md / review-queue.md / qa-check.md가 그대로 authoritative하게 유지됩니다.
- **경로 해석 (mode-aware — 가장 중요한 정확성 포인트):**
  - *Plugin install:* 레인 파일은 `${CLAUDE_PLUGIN_ROOT}/commands/*.md`에 있고 리터럴 토큰 `${CLAUDE_PLUGIN_ROOT}`를 포함합니다(이 토큰은 메인 세션에서만 치환되고 **서브에이전트 안에서는 치환되지 않음**). 런처는 메인 세션에서 `PLUGIN_ROOT`를 해석해 각 에이전트에게 그 토큰을 리터럴 경로로 치환하라고 알리고, 모든 스크립트 호출 앞에 `ORCH_CONFIG=$REPO_ROOT/.claude/orchestration.json`와 `REPO_ROOT=...`를 붙이게 합니다.
  - *Copy-in install (`install.sh`):* sed 치환이 `${CLAUDE_PLUGIN_ROOT}/`(trailing slash 포함) → `./`로 바꾸고 레인 파일은 `$REPO_ROOT/.claude/commands/*.md`에 위치(스크립트는 `$REPO_ROOT/scripts/`). 이 경우 에이전트는 `$REPO_ROOT`에서 이미 상대경로로 된 호출을 그냥 실행 — 토큰 치환 불필요.
  - 모드 감지 원리(정확히): copy-in에서 run-all.md는 **프로젝트 슬래시 커맨드**(`.claude/commands/run-all.md`)로 실행되므로 런타임에 `${CLAUDE_PLUGIN_ROOT}`가 **정의되지 않아 빈 문자열로 확장**됨 → copy-in 감지. 감지는 sed가 아니라 **런타임 변수 유무**에 의존한다(sed의 패턴은 trailing slash가 있어 `${CLAUDE_PLUGIN_ROOT:-}` 대입 라인을 건드리지 않으며, 그대로 둬도 무방). plugin mode에서는 하니스가 `${CLAUDE_PLUGIN_ROOT}`를 채워주므로 probe가 성립.
  - 런처는 probe로 `LANE_DIR`를 계산: `${CLAUDE_PLUGIN_ROOT}`가 **비어있지 않고** `$PLUGIN_ROOT/commands/triage.md`가 존재하면 → plugin mode; 아니면 → `$REPO_ROOT/.claude/commands` (copy-in mode). 빈 `PLUGIN_ROOT`이면 `[ -f "/commands/triage.md" ]`가 항상 실패하므로 copy-in으로 안전하게 떨어진다.
- **레인별 sweep 형태:**
  - Triager / Reviewer / QA → **drain-once** (현재 큐 전체를 처리한 뒤 종료). bounded background task에 자연스럽게 매핑됨.
  - QA의 기존 `/goal` 시맨틱 = bounded drain-the-queue; 에이전트가 이를 직접 재현하며 **요약에 전체 test/build 출력을 반드시 포함**해야 함(그 요약이 운영자가 보는 전부).
  - Coder → **sweep당 최대 3 work-issue 사이클** (조기 종료 조건: 큐 빔=claim exit 1 / claim race·assignee·코멘트 실패=claim exit 2 / WIP EXCEED=wip-check exit 1 / **wip-check API 실패=exit 2**). 주의: 현행 work-issue.md는 wip-check exit 2(API 실패) 정지를 명시하지 않으므로, run-all의 Coder 프롬프트에서 **exit 2도 정지**로 명시할 것. Coder의 self-paced cadence를 한 틱으로 평탄화하면서 생기는 처리량 손실을 완화하되 bounded 유지.
- **동시성(advisory lock 한계 인지):** 엔진은 N개의 racing worker를 견디도록 설계됨 — 단 `claim.sh`의 lock은 **advisory**(GitHub label + claim 토큰 코멘트)이며 진짜 atomic이 아니다. 두 Coder가 후보 선정을 동시에 통과하면 일시적 double-claim이 가능하지만 토큰 lexicographic tie-break로 해소됨(패자는 한 사이클 낭비). `wip-check.sh`의 WIP gate, Triager sweep 안에서 도는 `reclaim.sh`의 orphan recovery도 동일하게 동작. run-all은 이 **기존 모델을 그대로 사용**하며 새 locking gap을 추가하지 않는다 — 한 틱에서 놓친 전이는 다음 틱에 처리됨. (단일 run-all 인스턴스 권장; 2개 동시 실행 시 double-claim/낭비 사이클 빈도↑.)
- **Cadence 트레이드오프 (숨기지 말고 문서화):** 단일 outer interval은 원래의 레인별 cadence(10m/5m/self-paced)를 평탄화함. Coder가 가장 손해(연속 대비 ≤3 issues/tick). 완화책은 설계에 포함(×3/sweep); 추가로 깊은 백로그에는 전용 `/loop /ganpan:work-issue` 터미널을 run-all과 병행 가능. 참고: `/loop ... /ganpan:run-all`을 2개 돌리면 worker pool이 2배 — 안전하지만 WIP 압력도 2배.

## Changes

### 1. 신규 파일: `plugins/orchestration/commands/run-all.md`
Frontmatter는 `description:`만, 다른 커맨드와 동일. Body(번호 단계, 기존 컨벤션 준수 — `REPO_ROOT="$PWD"` 캡처, security blockquote, `${CLAUDE_PLUGIN_ROOT}` 사용):

1. **메인 세션에서 anchor 캡처** + install mode 감지:
   ```bash
   REPO_ROOT="$PWD"
   PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
   if [ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/commands/triage.md" ]; then
     LANE_DIR="$PLUGIN_ROOT/commands"; MODE=plugin
   else
     LANE_DIR="$REPO_ROOT/.claude/commands"; MODE=copyin
   fi
   test -f "$REPO_ROOT/.claude/orchestration.json" || { echo "not a configured repo root"; exit 1; }
   echo "MODE=$MODE REPO_ROOT=$REPO_ROOT LANE_DIR=$LANE_DIR PLUGIN_ROOT=$PLUGIN_ROOT"
   ```
   (두 anchor sanity-check; 없으면 멈추고 보고.)
2. **4개 레인을 한 메시지로 spawn** — Agent tool + `run_in_background: true` (동시 실행되고 Agent View에 함께 표시). 런처(메인 모델)는 **모드에 따라 preamble 문자열을 2가지로 구성**한다: plugin mode 변형에는 아래 토큰-치환 문장을 **포함**하고, copy-in mode 변형에서는 그 문장을 **생략**한다(copy-in 레인 파일은 이미 `./`로 rewrite되어 치환 불필요). 각 에이전트 프롬프트에 `<REPO_ROOT>`/`<LANE_DIR>`/`<PLUGIN_ROOT>`를 리터럴로 치환해 주입:
   > "메인 repo root `<REPO_ROOT>`에서 실행하라. Read tool로 레인 파일 `<LANE_DIR>/<lane>.md`를 읽고 단계를 정확히 따르라. **〈plugin mode 변형에만 포함〉** 파일에 `${CLAUDE_PLUGIN_ROOT}`가 보이면 리터럴 경로 `<PLUGIN_ROOT>`로 치환하라. 모든 orchestration 스크립트 호출에 `REPO_ROOT=<REPO_ROOT>`를 export하고 `ORCH_CONFIG=<REPO_ROOT>/.claude/orchestration.json`를 prefix하라. 아래 기술된 대로 정확히 한 번의 bounded sweep을 수행하고, **레인 이름을 prefix한 요약 줄로 시작**(요약 형식은 레인별 지정)한 뒤 EXIT하라 — 단 QA는 요약 줄 다음에 전체 출력 블록을 덧붙인다. PR을 절대 approve/merge하지 마라 — 그건 사람의 행동이다."

   레인별 tail:
   - **Triager** (`triage.md`): reclaim + 현재 `status:triage` 전부 분류. 요약 `Triager: reclaimed <r>, classified <c> (ready <a>, blocked <b>).`
   - **Coder** (`work-issue.md`): 풀 사이클을 이번 sweep에 최대 3회, 조기 종료(큐 빔=exit1 / claim 실패=exit2 / WIP EXCEED=exit1 / wip-check API 실패=exit2). 각 사이클은 work-issue.md 전체(step 9의 heartbeat 정지 포함)를 1회 완주하고, **다음 사이클 시작 전 이전 사이클의 heartbeat PID(`${TMPDIR:-/tmp}/hb-<ISSUE>.pid`)가 정지됐는지 확인**(잔존 시 kill — 안 그러면 이미 전이된 이슈의 claim 코멘트를 계속 patch함). 요약 `Coder: completed <k> cycle(s); last <claimed #N / queue-empty / wip-exceed / claim-failed / api-fail>.` (api-fail=wip-check exit 2 등 GH API 실패, claim-failed=claim exit 2와 구분).
   - **Reviewer** (`review-queue.md`): 현재 `status:in-review` 전부 처리(human merge 요청 또는 rework 반려; approve/merge 금지). 요약 `Reviewer: reviewed <n> (→qa <q>, →rework <w>, awaiting-merge <m>).`
   - **QA** (`qa-check.md`): 현재 `status:qa` 전부 bounded drain. 답변은 **구조화된 다중 줄 블록** — 첫 줄에 요약 `QA: verified <n> (pass <p>, rework <w>, blocked <b>).`, 그 다음 **이슈별 전체 test/build 출력**(운영자가 보는 유일한 근거이므로 생략 불가). 이 레인만 preamble의 "요약 줄로 시작" 제약에서 다중 줄로 확장된다.
3. **무엇을 띄웠는지 보고:** 4개 백그라운드 에이전트 실행 확인(Agent View / `claude agents`에서 보임), 레인 + bounded 동작 나열, 운영자에게 안내: *"이건 1회 sweep입니다. 연속 운영은 감싸세요: `/loop 20m /ganpan:run-all` (copy-in install은 `/loop 20m /run-all`). Coder는 sweep당 ≤3 사이클; 깊은 백로그엔 전용 `/loop /ganpan:work-issue`를 병행하세요."* 에이전트 완료를 기다리지 않음.

> Security blockquote (다른 레인과 동일하게): 런처는 dispatch만 하고 untrusted issue/PR 텍스트를 직접 읽지 않음; 각 레인 파일이 자체 untrusted-input 규칙을 가짐 — 약화시키지 말 것.

### 2. `install.sh` (copy-in 경로 — copy-in 사용자도 run-all + 경로 rewrite를 받도록 REQUIRED)
- Line 105: `for name in work-issue triage review-queue qa-check; do`에 `run-all` 추가.
- Line 110: info 문자열을 정확히 교체 — `info ".claude/commands/{work-issue,triage,review-queue,qa-check,run-all}.md"` (brace-expansion 리터럴이므로 단순 "포함"이 아니라 목록에 `run-all` 추가).
- Line 140 (next-steps 힌트, copy-in 짧은 이름 사용): `/loop 20m /run-all`(20m은 예시·조정 가능) 단일 커맨드 옵션 추가(선택).

### 3. Docs
- **`README.md`** — lane table(~20-26줄, 컬럼 `| 레인 | 커맨드 | 역할 |`): 행 추가 `| 통합 런처 | /ganpan:run-all | 4개 레인을 백그라운드 에이전트로 병렬 1회 스윕 |`. "레인 실행" 섹션(~88-95줄): 권장 단일 커맨드 진입점으로 `통합 런처: /loop 20m /ganpan:run-all`(20m은 예시·조정 가능) 추가, Coder 처리량 노트(깊은 백로그엔 전용 `/loop /ganpan:work-issue` 병행 권장). 디렉터리 트리 주석(~138줄, `commands/` 라인의 인라인 주석 `(triage / work-issue / ...)`)에 run-all 추가.
- **`docs/SETUP.md`** — "running all lanes at once" 하위 섹션 신설: 백그라운드 에이전트 spawn(Agent View에서 보임), 단일 cadence 평탄화 트레이드오프, single-instance 권장(두 개의 `/loop /ganpan:run-all` = worker pool 2배, 안전하나 WIP 2배), Coder 완화책.
- **`CLAUDE.md`** — `## Layout` 섹션의 커맨드 bullet(line 15, `plugins/orchestration/commands/` 라인): 레인 커맨드 목록 `(triage, work-issue, review-queue, qa-check, orch-setup)`에 `run-all` 추가.

## Critical files
- `plugins/orchestration/commands/run-all.md` (신규)
- `install.sh` (105, 110, 선택적으로 140줄)
- `tests/install.bats` (residue 가드 패턴을 `CLAUDE_PLUGIN_ROOT}/`로 narrowing + run-all.md assertion 3종 추가 — Verification §2 참조)
- `README.md`, `docs/SETUP.md`, `CLAUDE.md`
- 재사용(변경 없음): `triage.md`, `work-issue.md`, `review-queue.md`, `qa-check.md`, `scripts/orchestration/{claim,reclaim,wip-check,lib}.sh`
- **매니페스트 변경 불필요(확인됨):** `.claude-plugin/marketplace.json`·`plugin.json`에 commands 배열이 없어 커맨드는 파일로 auto-discover됨 — run-all 추가에 manifest 편집 없음.
- **`plugins/orchestration/assets/CLAUDE.md` 변경 불필요(확인됨):** 이 파일은 커밋/브랜치/merge-gate 컨벤션만 담고 커맨드를 열거하지 않으므로 run-all 언급 대상 아님.

## Verification
1. **Manifest/lint:** `jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json`; `shellcheck plugins/orchestration/scripts/orchestration/*.sh install.sh`.
2. **Install suite:** `bats tests/orchestration/ tests/install.bats`. 주의: install.bats에는 **command-count assertion이 없음** — work-issue.md 기준의 개별 assertion만 있음. run-all.md용으로 다음을 **명시적으로 추가**(work-issue.md 체크 미러링): ① 존재 `[ -f "$TARGET/.claude/commands/run-all.md" ]`(line 13 패턴), ② sentinel 카운트 `grep -c 'ganpan-orchestration:' run-all.md`(line 30 패턴), ③ HTML 주석 형식 `grep -q '<!-- ganpan-orchestration:' run-all.md`(line 33 패턴).
   **⚠ 필수 테스트 수정(CRITICAL):** install.bats line 18-23의 *"zero CLAUDE_PLUGIN_ROOT residue"* 가드는 `grep -rl CLAUDE_PLUGIN_ROOT "$TARGET/.claude/commands" ...`로 **bare 토큰까지** 잡는다. 그런데 run-all.md는 mode-detection(`${CLAUDE_PLUGIN_ROOT:-}`)과 preamble 산문에서 trailing slash 없는 토큰을 **의도적으로 보존**하므로(§Design 26줄), copy-in 설치 후 이 grep이 run-all.md를 매치해 **기존 테스트가 깨진다**. 해결: 가드 패턴을 rewrite 대상인 path 형태로 좁혀 `grep -rl 'CLAUDE_PLUGIN_ROOT}/'`로 변경한다 — path-drift 방지 의도는 그대로 유지하면서 run-all.md의 합법적 bare 토큰은 허용(다른 파일의 `${CLAUDE_PLUGIN_ROOT}/script` 미치환도 여전히 검출). (대안: 가드 grep에서 run-all.md만 제외.)
   또한 임시 target에 `install.sh`를 돌려 `.claude/commands/run-all.md`가 존재하고 **`${CLAUDE_PLUGIN_ROOT}/`(trailing slash) 잔재가 없음**을 확인 — 단, mode-detection의 `${CLAUDE_PLUGIN_ROOT:-}` 대입 라인은 trailing slash가 없어 sed에 안 잡히고 의도적으로 남는다(copy-in 런타임에 빈 값으로 확장). (참고: install.sh `stamp()`는 `*.md`에 `<!-- ganpan-orchestration: ... -->` HTML 주석 형태로 sentinel을 자동 추가하므로 위 ②③ 체크가 성립 — run-all.md에 별도 sentinel 줄을 미리 넣을 필요 없음.)
3. **Plugin-mode dispatch smoke test:** 설정된 repo에서 `/ganpan:run-all`을 1회 실행하고 확인: `claude agents`에 4개 백그라운드 에이전트가 보이고, 각자 레인 파일을 읽어 메인 체크아웃 config에 대해 스크립트를 실행(`${CLAUDE_PLUGIN_ROOT}`-빈 경로 에러 없음). 합격 기준은 표시 여부가 아니라 **각 에이전트가 exit 0으로 종료하고 지정 prefix의 요약 줄(QA는 요약 줄 + 출력 블록)을 실제로 반환**했는지(`claude agents`에 보이는 것만으로는 즉시 크래시한 에이전트도 표시되므로 불충분).
4. **Loop wrap:** `/loop 20m /ganpan:run-all`가 한 틱을 fire해 4개의 새 배치를 spawn하고, 레인들이 이슈를 상태 머신을 통해 기대대로 전이시킴.
