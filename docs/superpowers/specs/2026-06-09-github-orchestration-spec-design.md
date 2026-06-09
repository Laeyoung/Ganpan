# 개발 Spec: GitHub 네이티브 AI 코딩 에이전트 오케스트레이션 (v1)

> **상태:** Draft v1 (구현 착수 전 검토 대기)
> **작성일:** 2026-06-09
> **작성자:** Laeyoung (Modulabs)
> **상위 문서:** [PRD-github-claude-code-orchestration.md](../../../PRD-github-claude-code-orchestration.md)
> **다음 단계:** 본 Spec 검토·승인 후 구현 계획(writing-plans)으로 전환

---

## 0. 이 문서의 위치

PRD가 미뤄 둔 11개 open question을 모두 확정하고, 실행 가능한 구현 명세로 전환한 문서다. PRD의 "왜/무엇"을 전제로, 본 문서는 "어떻게"를 정의한다. 코드를 작성하지는 않으며, 파일 구조·인터페이스·동작·빌드 순서를 규정한다.

### 0.1 확정된 결정 (PRD open questions → 본 Spec)

| # | Open question (PRD 9장) | 확정 |
| :-- | :--- | :--- |
| 1 | 격리 방식 | **Option A — git worktree** |
| 2 | lane 구성 | **풀 v1 — 4 lane** (Triager/Coder/Reviewer/QA) |
| 3 | 폴링 vs 이벤트 | **v1은 전부 폴링** (Channels/Monitor는 향후) |
| 4 | WIP 한도 | **5** (in-review + qa 합계) |
| 5 | durable 전환 | **v1 범위 밖** (`/loop` 능동 세션 전제) |
| 6 | 커밋/PR 컨벤션 | **Conventional Commits** + `Closes #<issue>` |
| 7 | 테스트 커맨드 | **자동감지 + `.claude/orchestration.json` override** |
| 8 | 토큰 격리 | **Fine-grained PAT (단일 봇 계정)** |
| 9 | 이슈 유입 | **Issue template + 기본 라벨 `status:triage`** |
| 10 | label·Project 부트스트랩/동기화 | **라벨 부트스트랩 스크립트 + `/work-issue`가 `gh project item-edit`로 명시 동기화** |
| 11 | 고아 락 reclaim | **timeout 2h / heartbeat 15m** (설정으로 조정) |

### 0.2 핵심 설계 선택 (구현 구조)

**공유 셸 헬퍼 + 얇은 커맨드.** 경합에 민감한 핵심 로직(claim CAS, reclaim, WIP 체크, 테스트 커맨드 감지, 라벨 부트스트랩)을 `scripts/orchestration/*.sh`로 추출하고 `bats`로 테스트한다. `.claude/commands/*.md`는 얇게 유지하고 이 스크립트를 호출한다. PRD의 "경량" 목표를 지키면서(서비스·런타임 의존성 없음, 셸 + `gh`만) 동시성 위험 지점에 테스트를 둔다.

### 0.3 수반되는 트레이드오프 (명시)

open question 10에서 **`/work-issue`의 명시 Project 동기화**를 선택했으므로, 봇 토큰은 **Projects: write** 권한을 유지한다. 이는 PRD §6.3(3)의 "에이전트 토큰에서 Projects write 제거" 권고를 적용하지 **않는다**는 뜻이다. 대가로 실시간 칸반 보드를 얻는다. blast radius(프로젝트 전체 아이템/필드 수정 가능)는 알려진 잔여 위험으로 문서화하고 SETUP에 명시한다.

---

## 1. 비목표 (v1 범위 밖)

PRD 2.3과 일관. 본 Spec은 다음을 **구현하지 않는다**.

- **durable 운영**: GitHub Actions(`schedule`)·Claude Code Routines·Desktop scheduled tasks로의 이전. → 향후 별도 Spec.
- **이벤트 기반 lane**: Channels(CI 푸시)·Monitor 도구. v1은 전부 `/loop` 폴링. (문서에 5.2 최적화 항목으로만 언급.)
- **Docker 격리(Option C)**: worktree(A)로 시작.
- **다중 모델 비교**.
- **commitlint 등 강제 훅**: 컨벤션은 커맨드 프롬프트 + `CLAUDE.md`로 유도(강제 아님).
- **사람 검토 없는 머지**: human-in-the-loop 유지. 에이전트는 자기 PR 승인·머지 불가.

---

## 2. 리포지터리 레이아웃

```
.claude/
  commands/
    triage.md
    work-issue.md
    review-queue.md
    qa-check.md
  orchestration.json          # 단일 런타임 설정 (2.1)
  loop.md                     # 인자 없는 /loop 기본 동작 (선택)
scripts/orchestration/
  lib.sh                      # 설정 로드, gh 래퍼, 구조화 로깅, 공용 상수
  claim.sh                    # 원자적 claim (CAS + assignee + tie-break + 백오프)
  heartbeat.sh                # claim 토큰 타임스탬프 갱신
  reclaim.sh                  # 고아 락 sweeper
  wip-check.sh                # in-review + qa 카운트 vs 한도
  detect-test-cmd.sh          # test/build/lint 자동감지 + 설정 override
  bootstrap-labels.sh         # labels.yml로부터 7개 status 라벨 생성 (idempotent)
tests/orchestration/
  claim.bats
  reclaim.bats
  wip-check.bats
  detect-test-cmd.bats
  helpers/gh-stub.sh          # PATH에 끼우는 gh 목(mock)
.github/
  ISSUE_TEMPLATE/
    task.yml                  # 생성 시 status:triage 기본 라벨
  labels.yml                  # 7개 status 라벨 정의 (부트스트랩 소스)
CLAUDE.md                     # 커밋 컨벤션 + repo 규약
docs/
  SETUP.md                    # 1회성 셋업: PAT, branch protection, 부트스트랩, Project
```

### 2.1 설정 — `.claude/orchestration.json`

모든 런타임 파라미터의 단일 진실 공급원. 스크립트와 커맨드는 `lib.sh`의 로더를 통해서만 읽는다.

```json
{
  "repo": "owner/repo",
  "bot": "bot-login",
  "candidateN": 5,
  "wipLimit": 5,
  "reclaim": { "timeoutMinutes": 120, "heartbeatMinutes": 15 },
  "commands": { "test": null, "build": null, "lint": null },
  "worktreeBaseDir": "../",
  "project": { "number": null, "statusField": "Status" }
}
```

- `repo`: `gh ... --repo` 대상. 제네릭 — 어떤 repo에도 적용.
- `bot`: claim 식별자·assignee로 쓰이는 봇 로그인.
- `candidateN`: claim 후보 풀 크기(상위 N개 중 무작위 1개).
- `commands.{test,build,lint}`: `null`이면 `detect-test-cmd.sh`가 자동 채움. 문자열이면 그 값을 강제 사용(override).
- `project.number`: `null`이면 Project 동기화 단계를 건너뜀(보드 미사용). 숫자면 `/work-issue`·전이 시 `gh project item-edit`로 동기화.

---

## 3. 상태 머신 & 라벨 (PRD §3.1 그대로)

7개 라벨이 상태이자 동시성 락이다.

```
status:triage → status:agent-ready → status:in-progress
   → status:in-review → status:qa → status:done
                ↓ (실패·모호·반복 실패 시)
            status:blocked

반려: status:in-review → status:in-progress (Reviewer가 수정 요구 시)
```

### 3.1 `.github/labels.yml` (부트스트랩 소스)

```yaml
- name: "status:triage"
  color: "ededed"
  description: "분류 대기"
- name: "status:agent-ready"
  color: "0e8a16"
  description: "에이전트 작업 가능 큐"
- name: "status:in-progress"
  color: "fbca04"
  description: "워커 작업 중 (락)"
- name: "status:in-review"
  color: "1d76db"
  description: "PR 리뷰 대기"
- name: "status:qa"
  color: "5319e7"
  description: "머지됨, QA 검증 대기"
- name: "status:done"
  color: "0e8a16"
  description: "완료"
- name: "status:blocked"
  color: "b60205"
  description: "사람 개입 필요"
```

`bootstrap-labels.sh`는 이 파일을 읽어 `gh label create`(존재하면 `--force`로 갱신 또는 skip)로 멱등 생성한다.

---

## 4. 워커 lane (4개, 전부 폴링)

각 lane은 별도 터미널의 Claude Code 세션. 담당 라벨이 겹치지 않아 충돌하지 않는다.

| 터미널 | 역할 | 실행 명령 | 담당 전이 |
| :-- | :--- | :--- | :--- |
| 1 | **Triager** | `/loop 10m /triage` | reclaim 스윕 + `triage`→`agent-ready`/`blocked` |
| 2 | **Coder** | `/loop /work-issue` (동적 간격) | `agent-ready`→`in-progress`→`in-review` |
| 3 | **Reviewer** | `/loop 5m /review-queue` | `in-review`→(사람 머지 후 `qa` / 반려 시 `in-progress`) |
| 4 | **QA** | `/goal` 기반 `/qa-check` | `qa`→`done` (또는 회귀 이슈) |

> 가장 단순한 출발점은 Coder lane 1개(walking skeleton). 본 Spec은 4 lane을 모두 명세하되, 빌드 순서(11장)에서 Coder를 먼저 end-to-end로 세운 뒤 나머지를 붙인다.

---

## 5. 공유 스크립트 (테스트되는 핵심)

모든 스크립트는 `lib.sh`를 source하여 설정을 로드하고, `set -euo pipefail`, 구조화 로그(`log INFO|WARN|ERROR <msg>`)를 쓴다. `gh`는 항상 `--repo "$REPO"`로 호출한다.

### 5.1 `lib.sh`
- `load_config`: `.claude/orchestration.json`을 파싱해 환경변수(`REPO`, `BOT`, `CANDIDATE_N`, `WIP_LIMIT`, `RECLAIM_TIMEOUT_MIN`, `HEARTBEAT_MIN`, `WORKTREE_BASE`, `PROJECT_NUMBER`, `PROJECT_STATUS_FIELD`)로 노출. 누락 필드는 명확한 에러로 종료.
- `gh_json <args...>`: `gh` 호출 래퍼(공통 `--repo`, 실패 시 재시도/로그).
- `claim_token`: `date -u +%Y-%m-%dT%H:%M:%SZ` + `-${BOT}` 형식의 정렬 가능 토큰 생성(이른 시각이 어휘적으로 먼저).
- `now_epoch`, `iso_to_epoch` 등 시간 유틸.

### 5.2 `claim.sh` — 원자적 claim (PRD §3.3 하드닝 반영)

입력: 없음(설정에서 `agent-ready` 큐를 읽음). 출력: 성공 시 stdout에 이슈 번호. 종료코드 `0`=claim 성공, `1`=후보 없음, `2`=경합 패배(상위 호출자는 재시도).

절차:
1. `gh issue list --label status:agent-ready --json number,createdAt --limit 1000` → 상위 `CANDIDATE_N`개 중 무작위 1개 선택. (큐 맨 앞만 집으면 경합↑.)
2. `gh issue edit <n> --add-label status:in-progress --remove-label status:agent-ready` → `gh issue edit <n> --add-assignee "$BOT"` → `gh issue comment <n> --body "claim: <claim_token>"`.
3. 라벨/코멘트 전파 지연을 고려해 짧게 대기(기본 3s) 후 `gh issue view <n> --json labels,assignees,comments`로 재확인:
   - `status:in-progress` 반영 확인.
   - **assignee가 정확히 1명이고 본인(`$BOT`)인지** 확인. assignee는 복수 가능하므로 "본인 포함"만으로 불충분.
   - assignee ≥ 2명이면 타이-브레이크: claim 코멘트 전파가 보장되지 않으므로 코멘트 읽기를 **짧은 백오프로 N회 재시도**(코멘트 수 증가 확인)한 뒤, **claim 토큰 어휘 최솟값**을 승자로. 패자는 본인 라벨/assignee 해제 후 1번으로(종료코드 2).
4. 승자면 이슈 번호 출력(종료 0). 모호/패배면 종료 2.

### 5.3 `heartbeat.sh`
입력: 이슈 번호. 동작: 해당 이슈에 `claim: <새 claim_token>` 코멘트를 추가(또는 기존 claim 코멘트 갱신)해 타임스탬프를 최신화. `/work-issue`가 주요 단계마다 호출한다(살아있음 신호).

### 5.4 `reclaim.sh` — 고아 락 sweeper (Triager 소유)
1. `gh issue list --label status:in-progress --json number --limit 1000`.
2. 각 이슈의 최신 claim 토큰 타임스탬프를 코멘트에서 파싱.
3. `now - tokenTime > RECLAIM_TIMEOUT_MIN` **그리고** 연결된 PR에 최근 활동이 없으면(없거나 `updatedAt`이 오래됨) → `status:agent-ready`로 되돌리고 assignee 제거 + `reclaimed: orphan lock` 코멘트.
4. 살아있는(heartbeat 갱신 중) 워커는 timeout을 넘지 않으므로 회수되지 않음.

### 5.5 `wip-check.sh`
`in-review`와 `qa` 라벨 이슈 수를 각각 `gh issue list --label <L> --limit 1000 --json number | jq length`로 세어 합산(기본 limit 30 누락 방지 위해 `--limit 1000`). 합계 ≥ `WIP_LIMIT`이면 `EXCEED`, 아니면 `OK`를 출력.

### 5.6 `detect-test-cmd.sh`
설정의 `commands.{test,build,lint}`가 문자열이면 그대로 출력(override). `null`이면 순서대로 탐지:
- `package.json`의 `scripts.test`/`build`/`lint` → `npm test` 등.
- `Makefile`의 `test`/`build`/`lint` 타깃 → `make test` 등.
- `pyproject.toml`/`pytest.ini`/`tox.ini` → `pytest` 등.
- 감지 실패 시 비어 있는 값 + `WARN` 로그(QA lane은 이를 blocked 사유로 처리).

### 5.7 `bootstrap-labels.sh`
`.github/labels.yml`을 읽어 7개 라벨을 멱등 생성. 1회성 셋업(SETUP.md에서 안내) 또는 CI에서 실행.

---

## 6. 커맨드 명세 (`.claude/commands/*.md`, 얇게)

각 커맨드는 프롬프트(마크다운)로, 위 스크립트를 호출하고 결과에 따라 라벨을 전이한다.

### 6.1 `/triage`
1. `reclaim.sh` 실행(고아 락 회수) — Triager가 sweeper를 겸한다.
2. `gh issue list --label status:triage`로 미분류 이슈를 읽는다.
3. 각 이슈 내용 분석 → 영역/우선순위 라벨 부여.
4. 처리 가능하면 `status:triage` 제거 + `status:agent-ready` 추가. 모호하면 질문 코멘트 후 `status:blocked`.

### 6.2 `/work-issue`
1. `wip-check.sh` → `EXCEED`면 claim 없이 그 턴 no-op 종료(다음 `/loop` 주기 재확인).
2. `claim.sh` → 종료 2면 다른 이슈로 재시도, 1이면 종료(큐 빔).
3. claim한 이슈 번호로 `git worktree add "$WORKTREE_BASE/wt-issue-<n>" -b issue-<n>` (의존성은 gitignore 심링크 공유 — SETUP 참조).
4. `detect-test-cmd.sh`로 test/build 커맨드 확보.
5. 구현 → 테스트 실행 → **Conventional Commit**(`type(scope): subject`, 본문에 "무엇을·왜", `Closes #<n>`).
6. `gh pr create`(PR 본문에 `Closes #<n>` 링크) → 이슈에 PR 링크 코멘트.
7. `project.number`가 있으면 `gh project item-edit`로 status 필드를 In Review로 동기화.
8. `status:in-progress` 제거 + `status:in-review` 추가.
9. 위 각 주요 단계 후 `heartbeat.sh <n>` 호출.

### 6.3 `/review-queue`
`status:in-review` PR 각각에 대해:
1. diff를 읽고 인라인 코멘트.
2. 기준 충족 → **사람에게 승인·머지 요청**(에이전트는 직접 머지·자기승인 금지 — branch protection의 사람 리뷰 필수가 강제). PR을 승인하지 않는다.
3. 매 폴링 시 `gh pr view <n> --json state,mergedAt`로 merged 확인. merged면 `status:in-review`→`status:qa`, Project 동기화, `git worktree remove`.
4. 수정 필요 → 코멘트 후 `status:in-review`→`status:in-progress` 반려(Coder가 같은 worktree에서 이어받음).

### 6.4 `/qa-check` (`/goal` 기반)
`status:qa` 이슈/머지된 PR에 대해:
1. `detect-test-cmd.sh`의 test(+회귀) 커맨드 실행, **결과를 출력에 표면화**(evaluator가 도구 호출 없이 판단하므로).
2. 통과 → `status:qa`→`status:done`, Project 동기화, worktree 정리.
3. 실패 → 회귀 이슈 생성(`status:triage`), 현재 이슈는 `status:blocked` 또는 재작업 라우팅.
4. `/goal` 완료 조건: 측정 가능(테스트 exit 0) + 턴 상한(예: 30턴 후 `status:blocked`로 보고). PRD §3.4/§6.5 원칙 준수.

`/goal` 프롬프트 예시는 PRD §3.4의 형식을 따른다.

---

## 7. 보안 & 셋업 (`docs/SETUP.md`)

### 7.1 토큰 (Fine-grained PAT, 단일 봇 계정)
- 권한: **Contents** RW, **Pull requests** RW, **Issues** RW, **Projects** RW(명시 동기화 때문에 유지 — §0.3 트레이드오프).
- Repository access: "Only select repositories" → 대상 repo만.
- 만료: 90일. `GH_TOKEN` 환경변수로 주입(`--with-token` 비권장). `gh auth`는 **HTTPS**(ssh면 fine-grained 토큰 접근 불가).

### 7.2 branch protection (main)
- 사람 리뷰 **1인 필수**(또는 CODEOWNERS), force-push 금지, 직접 push 금지.
- **"include administrators"** 켜기(admin override 머지 차단), 리뷰 dismiss 권한 제한.
- 봇 토큰에 **admin 권한 미부여**. 단일 봇 identity이므로 자기 PR 승인은 "사람 리뷰 필수" 규칙으로 차단된다(PRD §6.3).

### 7.3 잔여 위험 (문서화)
- 비보호 feature 브랜치 force-push/삭제 가능(Contents:write) → `wt-issue-*` 네이밍 + 가능 시 브랜치 보호 규칙.
- Projects:write blast radius(§0.3) — 알려진 잔여 위험으로 수용.

### 7.4 1회성 셋업 순서
1. 봇 계정 생성 + Fine-grained PAT 발급(7.1).
2. 대상 repo에 봇을 collaborator로 추가.
3. `bootstrap-labels.sh` 실행(7개 라벨).
4. (선택) Project 생성 + `orchestration.json`의 `project.number` 설정.
5. branch protection 설정(7.2).
6. `.github/ISSUE_TEMPLATE/task.yml` 추가(기본 라벨 `status:triage`).
7. worktree 의존성 심링크 전략 결정(`node_modules` 등).

---

## 8. 이슈 유입 (open question 9)

`.github/ISSUE_TEMPLATE/task.yml`을 두어 이슈 생성 시 `status:triage`를 기본 라벨로 부착한다. 사람이 이슈를 열면 자동으로 큐에 진입하고, Triager lane이 이후 분류한다. (무라벨 이슈 자동 수거는 v1 미포함 — 오탐 방지.)

---

## 9. 테스트 전략

- **단위(bats)**: 모든 스크립트. `tests/orchestration/helpers/gh-stub.sh`를 `PATH` 앞에 끼워 `gh` 호출을 가로채고, 인자/순서/경합 동작을 검증.
  - `claim.bats`: 정상 claim, 후보 없음(종료1), 경합 패배(종료2), **이중 assignee**(타이-브레이크), **전파 지연**(백오프 후 판정) 적대적 케이스.
  - `reclaim.bats`: timeout 초과 회수, heartbeat 갱신 시 미회수, PR 활동 있으면 미회수.
  - `wip-check.bats`: 경계값(=한도, 한도-1, 한도+1), `--limit` 누락 시 30 초과 카운트.
  - `detect-test-cmd.bats`: package.json/Makefile/pyproject 감지, override 우선, 미감지 경고.
- **통합(수동)**: SETUP.md의 체크리스트로 단일 이슈를 triage→done까지 1회 통과.
- **컨벤션**: Conventional Commits는 커맨드 프롬프트 + `CLAUDE.md`로 유도(강제 훅은 범위 밖).

---

## 10. 성공 지표 (PRD 7장 측정 방법 구체화)

라벨/PR 데이터에서 추출:
- 유휴 시간↓: 정성 + lane 가동 시간.
- 처리량: 머지 PR 수 = `gh pr list --state merged --search "merged:>=<date>"` 카운트.
- 검토 적체: `wip-check.sh` 합계의 시계열.
- 반려율: `in-review`→`in-progress` 전이 코멘트 수 / 전체.
- blocked 비율: `status:blocked` 라벨 수 / 전체.

baseline은 PoC 1~2주 측정 후 목표치 설정(현 단계 수치 미고정).

---

## 11. 빌드 순서 (구현 계획의 골격)

각 단계는 독립적으로 검증 가능한 단위. Coder lane을 가장 먼저 end-to-end로 세워 "걷는 해골(walking skeleton)"을 만든다.

1. **기반**: `.github/labels.yml`, `bootstrap-labels.sh`, `.claude/orchestration.json`, `lib.sh` (+설정 로더 bats).
2. **핵심 스크립트**: `claim.sh` → `heartbeat.sh` → `reclaim.sh` → `wip-check.sh` → `detect-test-cmd.sh` (+ 각 bats, 특히 claim 적대적 케이스).
3. **Coder lane (walking skeleton)**: `/work-issue` — 단일 이슈를 agent-ready→in-review까지 실제 통과(PR 생성·Project 동기화 포함).
4. **Triager lane**: `/triage`(+reclaim 스윕).
5. **Reviewer lane**: `/review-queue`(머지 감지·반려).
6. **QA lane**: `/qa-check`(`/goal` 프롬프트·회귀 이슈).
7. **셋업·이슈 유입 문서**: `docs/SETUP.md`, `.github/ISSUE_TEMPLATE/task.yml`, `CLAUDE.md`(커밋 컨벤션).

---

## 12. 미해결/후속 (이번 Spec 이후)

- durable 운영(Actions/Routines) Spec.
- Channels/Monitor 이벤트 전환 Spec.
- worktree 의존성 공유(심링크 vs 재설치)의 구체 전략 — SETUP에서 결정하되 repo 특성에 따라 가변.
- 멀티 봇 identity(자기승인 원천 차단)로의 확장 — 단일 봇 + branch protection으로 시작.
