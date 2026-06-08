# PRD: GitHub 네이티브 AI 코딩 에이전트 오케스트레이션 워크플로

> **상태:** Draft v0.1
> **작성일:** 2026-06-04
> **작성자:** Laeyoung (Modulabs)
> **다음 단계:** 본 PRD 승인 후 개발 Spec 문서로 전환 (격리 방식·CI 연동 방식 확정)

---

## 1. 개요 (Summary)

Vibe Kanban·Conductor·Cline Kanban 같은 별도 오케스트레이션 도구를 도입하지 않고, **GitHub가 기본 제공하는 Issues / Pull Requests / Projects를 상태 저장소로 사용**하고, **`gh` CLI를 폴링·조작 인터페이스로, Claude Code를 워커로** 사용하여 "에이전트용 칸반" 워크플로의 경량 버전을 구축한다.

핵심 아이디어는 다음 대응 관계다.

| 칸반/에이전트 도구의 구성요소 | 본 워크플로의 구현 |
| :--- | :--- |
| 작업 카드(Task card) | GitHub Issue |
| 칸반 컬럼(Column / status) | GitHub Project status 필드 + Issue label |
| 워커(Worker / agent) | 터미널별 Claude Code 세션 |
| 작업 격리(Isolation) | git worktree 또는 단일 디렉터리 (4장에서 옵션 비교) |
| 동시성 락(Lock) | `status:in-progress` label |
| 상태 저장소(State store) | GitHub API (Hermes의 SQLite, Vibe Kanban의 로컬 DB 역할) |
| 스케줄러(Scheduler) | Claude Code 내장 `/loop` (cron 도구 기반) |
| 완료 조건 강제(Goal enforcement) | Claude Code 내장 `/goal` |
| 리뷰/머지 게이트 | PR + 사람의 리뷰 승인 |

별도 인프라(서버, DB, 데스크탑 앱)를 운영하지 않고, 개발자가 이미 쓰는 GitHub와 Claude Code만으로 동작하는 것이 설계 목표다.

---

## 2. 배경 및 동기 (Background & Motivation)

### 2.1 문제

Claude Code 같은 코딩 에이전트가 자율적으로 수 분~수 시간 단위 작업을 수행하게 되면서, 병목이 "코드 생성 속도"에서 "사람이 얼마나 빨리 계획·검토·관리하느냐"로 이동했다. 단일 에이전트와 동기적으로 일하면 에이전트가 "생각하는" 동안 개발자가 유휴 상태로 대기하는 시간(소위 "doomscrolling gap")이 발생한다.

기존 해법인 Vibe Kanban·Conductor 등은 이 문제를 잘 풀지만:

- 별도 도구·앱·서버를 도입·유지해야 하고,
- 일부는 레포 전체에 대한 광범위한 GitHub 권한을 요구하며(Conductor가 HN에서 비판받은 지점),
- 벤더 안정성 리스크가 있다(Vibe Kanban의 모회사 Bloop은 2026년 4월 사업 종료).

### 2.2 기회

2026년 3~5월 Claude Code에 추가된 두 기본 기능이 자체 구축의 비용을 크게 낮췄다.

- **`/loop`** (v2.1.72+): 세션이 열려 있는 동안 프롬프트·커스텀 커맨드를 일정 간격 또는 동적 간격으로 반복 실행하는 번들 스킬. 내부적으로 cron 도구(`CronCreate`/`CronList`/`CronDelete`)를 사용한다. → **폴링 워커 lane**을 외부 cron 없이 구현 가능.
- **`/goal`** (v2.1.139+): 완료 조건을 설정하면, 매 턴 후 별도의 작고 빠른 모델(evaluator)이 조건 충족 여부를 검증하고, 충족될 때까지 다음 턴을 자동으로 이어간다. 조건이 충족되면 goal 상태가 자동 해제된다. → **"조건이 충족될 때까지 밀어붙이는" 작업**(예: CI green 될 때까지 수정)에 적합.

이 둘 덕분에 "GitHub를 상태 저장소로 쓰는 다수 워커" 패턴을 Claude Code 안에서 거의 완결할 수 있다.

### 2.3 비목표 (Non-Goals)

- Vibe Kanban 수준의 GUI 보드를 만드는 것 (시각화는 GitHub Projects 웹 UI로 충분)
- 다중 호스트·분산 워커 (단일 개발 머신 전제)
- 완전 무인(unattended) 24/7 운영 (이는 GitHub Actions/Routines로 별도 처리 — 8장 참고)
- 에이전트가 사람 검토 없이 main에 직접 머지하는 것 (human-in-the-loop 유지)

---

## 3. 워크플로 설계 (Workflow Design)

### 3.1 상태 머신 (Label 기반)

Issue/PR의 생애주기를 label로 표현한다. label은 동시에 상태 표시이자 동시성 락 역할을 한다.

```
status:triage → status:agent-ready → status:in-progress
   → status:in-review → status:qa → status:done
                ↓ (실패 시)
            status:blocked
```

- **`status:triage`** — 새로 들어온, 아직 분류되지 않은 이슈
- **`status:agent-ready`** — 분류 완료, 에이전트가 집어갈 수 있음 (작업 가능 큐)
- **`status:in-progress`** — 워커가 집어 작업 중 (**락**: 다른 워커는 건드리지 않음)
- **`status:in-review`** — PR이 열렸고 리뷰 대기 중
- **`status:qa`** — 머지됨, QA 검증 대기
- **`status:done`** — 완료
- **`status:blocked`** — 사람 개입 필요 (의존성, 모호성, 반복 실패 등)

GitHub Project의 status 필드를 이 label과 동기화하면, 웹 UI에서 칸반 보드로 시각화된다.

### 3.2 워커 lane (터미널 = 역할)

각 터미널에서 서로 다른 역할(role)의 커스텀 커맨드를 `/loop` 또는 `/goal`로 감싼다. lane끼리는 담당하는 label(컬럼)이 겹치지 않아 충돌하지 않는다.

| 터미널 | 역할 | 실행 명령 | 담당 전이 |
| :--- | :--- | :--- | :--- |
| 1 | **Triager** | `/loop 10m /triage` | `triage` → `agent-ready` |
| 2 | **Coder** | `/loop /work-issue` (동적 간격) | `agent-ready` → `in-progress` → `in-review` |
| 3 | **Reviewer** | `/loop 5m /review-queue` | `in-review` → (`qa` 또는 코멘트 후 `in-progress`로 반려) |
| 4 | **QA** | `/goal` 기반 (3.4 참고) | `qa` → `done` (또는 회귀 이슈 생성) |

> **lane 수는 가변이다.** 가장 단순한 출발점은 Coder lane 1개이고, 검토 부하가 늘면 Reviewer를 분리하는 식으로 점진 확장한다.

### 3.3 `/loop` lane의 원자적 claim (동시성 제어)

가장 중요한 안전장치다. 여러 워커(또는 같은 lane의 중복 실행)가 같은 이슈를 동시에 집는 것을 막아야 한다. GitHub는 트랜잭션 락을 제공하지 않으므로, **label을 compare-and-swap처럼** 사용한다.

Coder lane의 claim 절차:

1. `gh issue list --label "status:agent-ready" --limit 1` 로 후보 1개 선택
2. 해당 이슈에 `status:in-progress` 추가 + `status:agent-ready` 제거
3. **재확인**: `gh issue view <n> --json labels` 로 라벨이 실제로 반영됐는지, 그리고 다른 워커가 먼저 집지 않았는지 확인
4. 본인이 집은 것이 확실하면 작업 시작, 아니면 1번으로 돌아가 다른 이슈 선택

이는 Hermes Kanban 디스패처의 "원자적 claim"을 GitHub label로 흉내 낸 것이다. 완벽한 원자성은 아니지만(label 반영에 지연·경합 가능), 단일 개발 머신에서 소수 lane을 돌리는 규모에서는 충분하다. claim 충돌 가능성을 더 낮추려면 lane별로 담당 이슈 범위를 나누거나(예: 라벨·assignee 기준), 동시 Coder lane을 1개로 제한한다.

### 3.4 QA lane에서의 `/goal` 활용

QA lane은 "조건이 충족될 때까지" 작업을 이어가야 하므로 `/loop`(간격 폴링)보다 `/goal`(조건 기반)이 더 맞는다. 예:

```
/goal PR #<n>의 CI가 모두 green이 되고, 변경된 모듈의 테스트가 통과할 때까지 수정한다.
완료 조건: (1) `gh pr checks <n>` 의 모든 체크가 pass, (2) 로컬 `npm test` (또는 해당 프로젝트 테스트 커맨드) exit code 0.
src/ 와 tests/ 밖의 파일은 수정하지 않는다. 30턴 후에도 미완이면 status:blocked 라벨을 붙이고 남은 작업을 보고한다.
```

`/goal` 조건 작성 원칙(공식 권고):
- **측정 가능한 종료 상태**: 테스트 결과, 빌드 exit code, 파일 수, 빈 큐 등 관찰 가능한 사건이어야 한다.
- **검증 방법 명시**: "`npm test` exits 0", "`git status` clean" 처럼 evaluator가 확인할 구체적 기준.
- **변경 금지 범위(constraints)**: 건드리면 안 되는 파일·디렉터리.
- **턴/시간 상한**: 무한 루프 방지 (`30턴 후 보고`).

> 주의: `/goal`의 evaluator는 **도구를 호출하지 않고** Claude가 대화에 표면화한 내용만 보고 판단한다. 따라서 완료 조건은 Claude 자신의 출력으로 증명 가능해야 한다(예: 테스트 결과를 출력에 포함). 모호한 조건은 evaluator가 성공을 환각하거나 무한 루프를 유발한다.

`/goal`은 "라벨링된 이슈 백로그를 큐가 빌 때까지 처리" 같은 용도로 Coder lane에도 응용할 수 있으나, 검토 게이트(human-in-the-loop)를 우회하지 않도록 "PR 생성까지만"을 종료 조건으로 둔다.

### 3.5 커스텀 커맨드 (`.claude/commands/`)

각 lane이 호출하는 커맨드는 프로젝트의 `.claude/commands/` 에 마크다운으로 정의한다. 개략 사양:

- **`/triage`** — `status:triage` 이슈를 읽고, 내용 분석 후 적절한 label(영역·우선순위) 부여, 처리 가능하면 `status:agent-ready`로, 모호하면 질문 코멘트 후 `status:blocked`로.
- **`/work-issue`** — 3.3의 claim 절차 수행 → 작업 디렉터리/worktree 준비 → 구현 → 커밋 → `gh pr create` → 이슈에 PR 링크 → `status:in-review`로 전이. (커밋 메시지 품질 규칙을 여기에 명시 — 6.4 참고)
- **`/review-queue`** — `status:in-review` PR의 diff를 읽고 인라인 코멘트, 기준 충족 시 `status:qa`, 수정 필요 시 코멘트 후 `status:in-progress`로 반려.
- **`/qa-check`** 또는 `/goal` 프롬프트 — 머지된/머지 예정 PR의 테스트·회귀 검증, 통과 시 `status:done`, 실패 시 회귀 이슈 생성.

> `loop.md` ( `.claude/loop.md` 또는 `~/.claude/loop.md` )를 두면 인자 없는 `/loop`의 기본 동작을 커스터마이즈할 수 있다. 단, 프롬프트를 명시적으로 넘기면 무시된다. 25,000 바이트 초과분은 잘린다.

---

## 4. 작업 격리 방식 (Isolation Options) — **Spec 단계에서 확정**

본 워크플로의 가장 중요한 미결정 사항. 아래 옵션을 두고, 개발 Spec 문서로 넘어갈 때 팀 상황에 맞춰 선택한다. (요청에 따라 옵션을 모두 기재하고 결정은 보류한다.)

### Option A — git worktree (워커별 독립 브랜치/디렉터리)

각 작업을 `git worktree add ../wt-issue-<n> <branch>` 로 별도 작업 트리에서 처리한다.

- **장점**
  - 병렬 작업 간 파일 충돌 없음 (Vibe Kanban·Cline·Conductor가 채택한 방식)
  - 단일 클론을 공유하므로 디스크 효율이 풀 클론보다 나음
  - 브랜치-작업 1:1 매핑이 자연스럽고, PR 생성과 매끄럽게 연결됨
- **단점**
  - 작업 수만큼 worktree가 쌓여 디스크 비대화 → **정리 정책 필수** (머지/종료 시 `git worktree remove`)
  - `node_modules` 등 의존성이 worktree마다 필요 → Cline은 gitignore 파일을 심링크로 공유해 재설치를 회피. 동일 기법 검토 필요
  - 빌드 산출물·포트 충돌 관리 필요 (Vibe Kanban은 포트 풀 데몬으로 해결)
- **적합한 경우**: 진짜 병렬로 여러 이슈를 동시에 돌리고 싶을 때

### Option B — 단일 작업 디렉터리 (순차 처리)

하나의 작업 디렉터리에서 한 번에 한 작업씩, 브랜치만 갈아끼우며 순차 처리한다.

- **장점**
  - 가장 단순. 디스크·의존성·포트 관리 이슈 없음
  - 멘탈 모델이 명확 (지금 무슨 작업을 하는지 1개만 추적)
  - macOS 개발 환경(pyenv/Homebrew 등)과의 상호작용 부작용이 적음
- **단점**
  - 병렬성 없음 → "doomscrolling gap"을 완전히 메우지 못함
  - lane을 여러 개 띄워도 Coder가 사실상 1개로 직렬화됨
- **적합한 경우**: 도입 초기 검증(PoC), 또는 충돌 위험이 큰 모노레포에서 안전 우선

### Option C — 컨테이너 격리 (Docker per task)

각 작업을 Docker 컨테이너에서 실행 (Imbue Sculptor 방식).

- **장점**
  - 가장 강한 격리. 에이전트가 호스트 환경(home 디렉터리, 전역 설정)을 오염·파괴하는 사고 방지
  - 의존성 충돌 완전 차단, 재현성 높음
  - 프로덕션/독점 코드에 가장 안전
- **단점**
  - 셋업 복잡도 최상 (Dockerfile·이미지 관리·볼륨 마운트)
  - 로컬 IDE와의 양방향 동기화가 별도 과제 (Sculptor는 Pairing Mode로 해결)
  - 본 워크플로의 "경량" 목표와는 거리가 있음
- **적합한 경우**: 신뢰 경계가 중요한 사내 독점 코드, 또는 에이전트에게 넓은 권한을 줄 때

### 권고 (참고용, Spec에서 재검토)

도입 순서로 **B(PoC) → A(병렬 확장) → 필요 시 C(프로덕션 격리 강화)** 를 제안한다. Laeyoung님의 기존 인프라 경험(AWS/GCP, 컨테이너 친숙)을 고려하면 C로의 이행 비용은 상대적으로 낮은 편이다.

---

## 5. 스케줄링·이벤트 모델 (Scheduling & Events)

### 5.1 `/loop` 제약과 대응

| 제약 | 내용 | 본 워크플로에의 영향 / 대응 |
| :--- | :--- | :--- |
| 세션 스코프 | 작업은 현재 대화에만 존재, 세션 종료 시 중단. `--resume`/`--continue`로 미만료분 복원 | 터미널을 열어두는 방식과 부합. 터미널을 닫으면 그 lane 정지 |
| 7일 만료 | 반복 작업은 생성 7일 후 마지막 1회 실행 뒤 자동 삭제 | 상시 운영 시 재생성 필요 → 8장의 durable 옵션 고려 |
| idle일 때만 발화 | 긴 요청 중 예정 시각이 지나면 누락분 몰아 실행 없이 idle 시 1회만 | 폴링 간격을 여유 있게 |
| jitter | 반복 작업은 최대 30분(잦으면 간격 절반) 지연 발화 | 폴링이므로 무방 |
| 동시 작업 상한 | 세션당 최대 50개 스케줄 작업 | 충분 |

### 5.2 폴링 대신 이벤트 (선택적 최적화)

`/loop` 폴링은 토큰을 소비한다. Claude Code는 두 가지 대안을 제공한다.

- **Channels**: CI 등 외부 시스템이 이벤트(예: 빌드 실패)를 세션에 직접 푸시 → Reviewer/QA lane의 일부를 폴링 대신 푸시 기반으로 전환하면 토큰 효율·반응성 개선.
- **Monitor 도구**: 동적 `/loop`에서 Claude가 백그라운드 스크립트의 출력 라인을 스트리밍받아 폴링 자체를 제거.

이 둘은 Spec 단계에서 lane별로 폴링 vs 이벤트를 선택할 때 검토한다.

---

## 6. 위험 및 완화 (Risks & Mitigations)

### 6.1 동시성 경합
label 기반 claim은 완벽한 원자성이 아니다. → 동시 Coder lane을 제한하거나, lane별 이슈 범위를 분할. claim 후 재확인 단계 필수(3.3).

### 6.2 검토 규율 붕괴 ("vibe coding으로의 미끄러짐)
에이전트를 많이 띄울수록 "그냥 머지하고 넘어가자"는 유혹이 커진다(GeekNews 커뮤니티가 지적한 실제 현상). → **검토를 진짜 제약(WIP 한도)으로 관리**: `status:in-review` + `status:qa` 합계에 상한(예: 5~10개)을 두고, 초과 시 Coder lane을 멈춘다. 전통 칸반의 WIP 제한 원칙을 "사람 검토" 컬럼에 적용하는 것.

### 6.3 권한·보안

워커가 `gh`를 통해 레포에 push하고 PR·이슈를 조작한다. 에이전트에게 개발자 본인의 전체 권한(모든 repo 접근)을 그대로 물려주는 것은 blast radius가 지나치게 크다. **토큰 격리**와 **행동 제약**을 별개의 두 층으로 함께 적용한다.

#### (1) 토큰 격리 — 대상 repo로만 권한 제한

`gh`가 사용하는 자격증명을 "권한을 부여한 특정 repo에서만 동작"하도록 제한한다. 두 가지 방식이 있다.

**방식 A — Fine-grained PAT (PoC·개인 머신 권장 시작점)**

GitHub의 fine-grained personal access token은 단일 사용자/조직 소유 리소스로 제한되고, 그 안에서도 특정 repo만 선택할 수 있으며, scope 대신 세밀한 permission을 부여한다. 생성 절차:

1. Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token
2. **Resource owner**: 본인 또는 조직(`aiffel-dev`) 선택 — 조직이면 owner 승인이 필요할 수 있음
3. **Repository access**: "Only select repositories" → 대상 repo만 선택 ← **핵심**
4. **Permissions** (본 워크플로 lane 매핑):
   - Contents: Read and write (커밋·push)
   - Pull requests: Read and write (PR 생성·코멘트)
   - Issues: Read and write (이슈·라벨 조작)
   - Projects: Read and write (GitHub Project 보드를 쓸 경우)
5. **만료일**: fine-grained 토큰은 무기한 불가, 1~366일 중 선택 (회전 주기에 맞춤; 개발/테스트는 90일이 무난)

`gh` 적용 시 주의:
- fine-grained PAT는 `--with-token`보다 **`GH_TOKEN` 환경변수**로 넘기는 것이 권장됨. `--with-token`은 토큰이 특정 리소스로 스코프된 특성 때문에 다른 리소스와 상호작용할 때 혼란스러운 동작을 유발할 수 있음.
  ```bash
  export GH_TOKEN="github_pat_..."
  gh issue list --repo owner/your-repo
  ```
- `gh auth login`에서 **protocol을 ssh로 설정하면** fine-grained 토큰으로 권한 준 repo에 접근 불가(권한 에러처럼 보이지만 실제로는 인증 에러). → **HTTPS 사용**.

**방식 B — GitHub App + 특정 repo installation (봇/서비스 계정·durable 운영 권장)**

GitHub에는 엄밀한 "service account" 타입이 없으므로, 봇 워크로드에는 GitHub App을 만들어 **특정 repo에만 install**한다. installation token은 설치된 repo에서 부여한 권한만 갖고, 사용자가 아닌 App에 묶이며, 짧은 수명(약 1시간)으로 자동 발급되어 회전·감사에 유리하다. (대안으로 별도 machine user 계정을 만들어 해당 repo에만 collaborator로 추가하고 그 계정의 fine-grained PAT를 쓰는 방식도 있으나, 계정을 하나 더 관리해야 함.)

> 적용 순서: **PoC·개인 머신 → 방식 A**, **durable 운영(GitHub Actions/Routines로 이전, 8장) 또는 팀 공유 → 방식 B**.

#### (2) 행동 제약 — branch protection (토큰 격리와 별개의 층)

토큰 스코핑은 *발급된 토큰의 권한 범위*를 줄일 뿐, 그 범위 안에서 에이전트가 하는 행동을 막지는 못한다. 즉 토큰에 write 권한이 있으면 에이전트는 그 repo에 push할 수 있다. 따라서 토큰 격리와 **함께** 다음을 건다.

- main(보호 브랜치)에 **branch protection**: force-push 금지, PR 리뷰 필수, 직접 push 금지
- 에이전트가 권한 범위 안에서도 main을 직접 머지·파괴하지 못하도록 강제
- 머지는 사람의 리뷰 승인을 거친 PR로만 (human-in-the-loop 유지, 2.3 비목표와 일관)

**요약**: 토큰 격리(blast radius 축소) + branch protection(행동 제약)은 서로를 대체하지 않는 두 개의 층이며, 반드시 함께 적용한다.

### 6.4 커밋 메시지·diff 품질
Vibe Kanban에서 실제로 보고된 문제(커밋 메시지가 "완료했습니다", "수정되었습니다" 식으로 무의미하게 생성됨). → `/work-issue` 커맨드와 `CLAUDE.md`에 커밋 컨벤션을 명시(예: Conventional Commits, 이슈 번호 참조, "무엇을·왜"를 본문에). 품질이 검토 시간을 오히려 늘리면 병렬 규모를 줄인다.

### 6.5 `/goal` 무한 루프 / 조기 종료
조건이 모호하면 evaluator가 환각으로 성공 처리하거나 턴 상한까지 루프. → 측정 가능·검증 가능한 조건 + 턴 상한 필수(3.4). evaluator가 도구를 호출하지 않음을 전제로, 증거를 출력에 표면화하도록 커맨드 설계.

### 6.6 세션·만료로 인한 작업 유실
`/loop`의 7일 만료·세션 스코프. → 핵심 상태는 전부 GitHub(이슈/PR/label)에 있으므로 세션이 죽어도 상태는 보존된다. 세션 재개 시 label을 읽어 작업을 이어받으면 됨. 이것이 GitHub를 상태 저장소로 쓰는 설계의 가장 큰 이점.

---

## 7. 성공 지표 (Success Metrics)

- **유휴 시간 감소**: 개발자가 에이전트 대기 중 컨텍스트 스위칭하는 빈도/시간 감소
- **처리량**: 일/주 단위 머지된 PR 수 (단, 품질을 희생하지 않는 선에서)
- **검토 적체**: `status:in-review`/`status:qa` 큐가 WIP 한도 내에서 유지되는 비율
- **반려율**: Reviewer가 `in-progress`로 반려하는 비율 (에이전트 1차 품질의 프록시)
- **blocked 비율**: `status:blocked`로 빠지는 이슈 비율 (자동화 적합도의 프록시)

---

## 8. 향후 확장 (Future / Out of Scope for v1)

- **Durable 운영(7일 초과·무인)**: 핵심 lane을 GitHub Actions(`schedule` 트리거), Claude Code Routines(Anthropic 관리 인프라), 또는 Desktop scheduled tasks로 이전. `/loop`는 능동 개발 세션용으로 유지하는 하이브리드.
- **MCP 연동**: GitHub MCP 서버로 `gh` 셸아웃을 구조화된 툴 콜로 대체 검토.
- **Project 자동화**: GitHub Projects 내장 워크플로(label↔status 자동 동기화)로 수동 동기화 제거.
- **다중 모델 비교**: 같은 이슈를 Claude Code와 다른 에이전트로 병렬 실행 후 결과 비교(Conductor 방식) — 단 본 워크플로 범위 밖.

---

## 9. 미결정 사항 (Open Questions → Spec에서 결정)

1. **격리 방식**: Option A / B / C 중 무엇으로 시작할 것인가? (4장)
2. **lane 구성**: 초기 lane 수와 역할 분담 (Coder만? 4-lane 풀셋?)
3. **폴링 vs 이벤트**: 어떤 lane을 Channels/Monitor로 전환할 것인가? (5.2)
4. **WIP 한도 수치**: 검토 컬럼의 구체적 상한 (6.2)
5. **durable 전환 시점**: 언제 `/loop`에서 Actions/Routines로 넘어갈 것인가? (8장)
6. **커밋/PR 컨벤션**: `CLAUDE.md`·커맨드에 박을 구체 규칙 (6.4)
7. **테스트 커맨드 표준화**: `/goal`·QA lane이 검증에 쓸 프로젝트별 테스트·빌드 커맨드
8. **토큰 격리 방식**: Fine-grained PAT(방식 A)로 시작할지, 처음부터 GitHub App installation(방식 B)으로 갈지 (6.3) — durable 운영·팀 공유 시점과 연동

---

## 부록: 참고한 외부 사례

- **Vibe Kanban (BloopAI)** — git worktree + 10+ 에이전트, 본 워크플로의 원형. 모회사 종료로 OSS 유지.
- **Hermes Agent (Nous Research)** — SQLite 상태 저장소 + label 유사 상태 머신 + 디스패처. 본 워크플로의 "GitHub = SQLite" 발상의 참조점.
- **Cline Kanban** — ephemeral worktree + gitignore 심링크로 의존성 공유 (Option A 최적화 참고).
- **Imbue Sculptor** — Docker 컨테이너 격리 (Option C 참조).
- **Conductor (Melty Labs)** — 권한 과다 요구 논란 (6.3 보안 설계의 반면교사).
