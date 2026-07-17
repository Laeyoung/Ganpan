# Ganpan (간판)

**GitHub-native 멀티 에이전트 오케스트레이션 툴킷** — Issues / PRs / 라벨을 단일 상태 머신으로 삼아, 여러 AI 에이전트가 **Triager → Coder → Reviewer → QA** 레인을 나눠 협업하도록 만드는 Claude Code + Codex + Antigravity CLI 지원 툴킷입니다.

별도의 큐나 DB 없이 GitHub 자체를 작업 보드로 사용합니다. 각 이슈는 `status:*` 라벨로 상태가 표현되고, 에이전트들은 라벨을 보고 자기 일을 집어가며, **머지는 항상 사람이** 합니다(branch protection으로 강제).

---

## 동작 개요

이슈 하나가 라벨을 따라 흐릅니다:

```
status:triage      ── /triage ──▶   status:agent-ready
status:agent-ready ── /work-issue ▶ status:in-progress ──▶ status:in-review (PR 생성)
status:in-review   ── 사람이 머지 + /review-queue ──▶ status:qa
status:qa          ── /qa-check ──▶ status:done   (실패 시 rework / blocked)
```

| 레인 | Claude Code | Codex Skill | 역할 |
|------|-------------|-------------|------|
| **Triager** | `/ganpan:triage` | `ganpan-triage` | 고아 락 회수(reclaim) 후 `status:triage` 이슈를 분류 → `agent-ready` 또는 `blocked` |
| **Coder** | `/ganpan:work-issue` | `ganpan-work-issue` | `agent-ready` 이슈를 클레임 → worktree에서 구현 → PR 생성 → `in-review` |
| **Coder (deep)** | `/ganpan:work-issue-deep` | — | 더 크거나 위험한 이슈용. 같은 클레임/락 계약이되, 단일 "구현" 단계를 **Spec → 리뷰 → Plan → 리뷰 → 구현 → 리뷰** 루프로 대체 (Claude Code 전용) |
| **Reviewer** | `/ganpan:review-queue` | `ganpan-review-queue` | `in-review` PR을 리뷰. **머지/승인은 절대 안 함** — 사람에게 머지 요청, 통과 시 `qa` |
| **Reviewer (deep)** | `/ganpan:review-queue-deep` | — | 각 `in-review` PR을 **멀티패스 에이전트팀**으로 리뷰한 뒤 표준 4-way 프로토콜로 라우팅 (Claude Code 전용) |
| **QA** | `/ganpan:qa-check` | `ganpan-qa-check` | 머지된 작업을 실제 실행·검증. 통과 → `done`, 실패 → rework 또는 `blocked` |
| **Setup** | `/ganpan:orch-setup` | `ganpan-setup` | 1회 셋업 (아래 참고) |
| **Update** | `/ganpan:update` | `ganpan-update` | 설치된 버전 vs 최신 버전과 업데이트 절차를 **안내만** 함 (자문용 — 레포를 절대 바꾸지 않음) |
| **통합 런처** | `/ganpan:run-all` | — | 4개 레인(Triager·Coder·Reviewer·QA)을 백그라운드 에이전트로 한 번에 병렬 1회 스윕 (Claude Code 전용) |

> 플러그인 커맨드는 플러그인 이름으로 네임스페이싱됩니다. 정식 호출은 `/ganpan:triage`이며, 충돌이 없으면 짧은 `/triage`로도 호출됩니다.
>
> **`-deep` 변형**은 표준 레인과 동일한 클레임/락/전이 계약을 따르되 더 무거운 워크플로를 실행합니다. 평상시 백로그는 표준 레인으로 돌리고, 크거나 위험한 이슈만 deep으로 돌리세요. deep Coder는 Superpowers 플러그인과 `/document-review-loop`·`/dev-review-loop` 스킬을 필요로 하며, 없으면 표준 `/ganpan:work-issue`로 폴백합니다.

---

## 사전 준비물

- `gh` (GitHub CLI, 인증 완료), `git`, `jq`, `yq`
- 테스트 실행 시 `bats`

```bash
command -v gh jq yq git   # 모두 존재하는지 확인
gh auth status            # 인증 확인 (HTTPS 권장)
```

## 지원 표면

| Surface | Status | Primary UX |
|---|---|---|
| Claude Code plugin | first-class | `/ganpan:*` commands |
| Copy-in Claude install | first-class fallback | `.claude/commands` + scripts |
| Codex repo-local skills | Phase 1 MVP | `.agents/skills/ganpan-*` |
| Antigravity CLI skills | Phase 1 (shared payload) | `.agents/skills/ganpan-*` |
| CLI runner | planned | `ganpan lane ...` |
| Codex plugin | planned | Codex plugin install |

---

## 설치

### 방법 A — 플러그인 (권장)

```text
1. /plugin marketplace add Laeyoung/Ganpan
2. /plugin install ganpan@laeyoung
3. 대상 레포 루트에서:  /ganpan:orch-setup owner/repo
4. /ganpan:orch-setup 이 출력하는 사람용 체크리스트 완료
```

`/ganpan:orch-setup`이 자동으로 해주는 것:
- 사전 준비물·인증 점검
- `.claude/orchestration.json` 작성 (인자에서 `repo` / `bot` 채움)
- `.github/labels.yml` + 이슈 템플릿 설치
- `CLAUDE.md` 컨벤션 병합
- 라벨 부트스트랩

### 방법 B — copy-in (플러그인을 쓰지 않을 때)

ganpan 체크아웃에서 대상 레포로 파일을 직접 복사합니다:

```bash
./install.sh <대상-레포-경로>
```

이 경우 config는 **템플릿만** 복사되므로, `.claude/orchestration.json`을 열어 `repo`·`bot`(필요 시 `project.number`)을 직접 채워야 합니다.

**업그레이드:** `install.sh`를 다시 실행하면 버전 sentinel이 다른 파일만 갱신됩니다. v1(자동 sentinel 이전) 설치본에서 처음 올릴 때는 `./install.sh <대상> --force`를 쓰거나 기존 `scripts/orchestration/`·`.claude/commands/`를 먼저 지우세요.

### 방법 C — Codex repo-local skills (Phase 1 MVP)

Codex CLI/IDE가 대상 레포에서 repo-local skills를 읽도록 설치합니다:

```bash
./install.sh <대상-레포-경로> --target codex
```

설치되는 항목:
- `.agents/skills/ganpan-*`
- `AGENTS.md` Ganpan conventions block
- `scripts/orchestration/*.sh`
- `.ganpan/orchestration.json` 템플릿. 단, 기존 `.claude/orchestration.json`만 있으면 legacy fallback으로 두고 새 `.ganpan` config를 자동 생성하지 않습니다.
- `.github/labels.yml` + issue template

Claude와 Codex surface를 함께 설치하려면:

```bash
./install.sh <대상-레포-경로> --target both
```

설치 후 설정·라벨 부트스트랩·검증·레인 실행·트러블슈팅까지의 전체 절차는 **[`docs/CODEX_RUNBOOK.md`](docs/CODEX_RUNBOOK.md)** 를 따르세요.

### 방법 D — Antigravity CLI (agy) repo-local skills

Codex와 동일한 agents-skills payload를 설치합니다 (agy는 `.agents/skills/<name>/SKILL.md`를 읽습니다):

```bash
./install.sh <대상-레포-경로> --target antigravity
```

설치되는 항목:
- `.agents/skills/ganpan-*`
- `AGENTS.md` Ganpan conventions block
- `scripts/orchestration/*.sh`
- `.ganpan/orchestration.json` 템플릿 (기존 `.claude/orchestration.json`만 있으면 legacy fallback 유지)
- `.github/labels.yml` + issue template

이미 `--target codex`/`both`로 설치했다면 디스크 상태가 동일하므로 재설치가 필요 없습니다. 설치 후 대상 레포에서 `agy` 실행 → `/skills`에 `ganpan-*` 6종이 보이면 성공. 레인은 이름으로 요청하거나 `/<skill-name>` 슬래시 형태로 호출합니다. Claude + Codex + Antigravity를 한 번에 설치하려면 `--target all`.

---

## 셋업 이후 사람이 해야 할 일

`/ganpan:orch-setup`이 자동화하지 못하는 부분(체크리스트로 안내됨):

1. **봇 계정 + Fine-grained PAT** — 대상 레포에만 Contents RW / Pull requests RW / Issues RW / Projects RW, 만료 90일. `GH_TOKEN=github_pat_...`로 export(HTTPS 사용; `--with-token` 금지). **이는 권장이 아니라 실행 전제조건입니다** — 레인은 시작 시 `gh` 행위 주체가 `config.bot`과 일치하는지 확인하고, 일치하지 않으면(예: `GH_TOKEN` 미설정 → 개인 계정으로 폴백) 즉시 중단합니다. (CI 등 봇 PAT가 곧 주체임이 확실한 경우에만 호출 단위로 `ORCH_SKIP_ACTOR_CHECK=1`을 쓸 수 있으며, 전역 export는 금지.)
2. **봇을 대상 레포 협업자로 추가.**
3. **(선택) GitHub Project** 생성 후 `project.number` 설정 — 없으면 `null`로 두면 sync는 no-op.
4. **`main` 브랜치 보호** — 사람 리뷰 1회 필수, force-push·직접 push 금지, **관리자 포함**, 리뷰 dismissal 제한. 봇 토큰은 admin이면 안 됨.
5. **Worktree 의존성 전략** — 이슈별 worktree(`../wt-issue-<n>`)가 의존성을 어떻게 공유할지 결정(예: Node는 `node_modules` 심볼릭 링크).

---

## 레인 실행 (각각 별도 터미널)

```text
Triager :  /loop 10m /ganpan:triage
Coder   :  /loop /ganpan:work-issue
Reviewer:  /loop 5m /ganpan:review-queue
QA      :  /goal 로 /ganpan:qa-check 래핑
```

### 한 번에 실행 (통합 런처)

`claude agents`(Agent View) 한 곳에서 4개 레인을 운영하려면:

```text
/loop 20m /ganpan:run-all      # 20m은 예시 — 조정 가능. bare 실행 시 1회 스윕
```

`/ganpan:run-all`은 매 틱마다 4개 레인을 **백그라운드 에이전트**로 띄워 각자 1회 스윕 후 종료합니다(Agent View에 함께 표시). 단일 인스턴스만 권장(2개 동시 실행 시 worker pool·WIP 압력 2배). Coder는 틱당 최대 3 사이클이라, **백로그가 깊으면** 전용 `/loop /ganpan:work-issue`를 함께 돌리세요.

> ⚠️ **`/loop` 간격은 한 스윕 소요 시간보다 넉넉히** 잡으세요. 런처는 띄운 에이전트를 기다리지 않고 반환하므로, 스윕(특히 Coder의 긴 빌드/테스트)이 간격보다 오래 걸리면 다음 틱이 실행 중인 배치 위에 새 배치를 띄웁니다. Coder claim은 WIP 게이트로 `wipLimit`까지만 묶이지만, 겹친 Reviewer/QA는 같은 이슈를 중복 처리할 수 있습니다(중복 코멘트·낭비).

### 통합 스모크 테스트 (수동)

1. 이슈를 연다 → `status:triage` 부여됨.
2. `/ganpan:triage` 1회 → `status:agent-ready`.
3. `/ganpan:work-issue` 1회 → `status:in-progress` → PR과 함께 `status:in-review`.
4. 사람이 PR 승인·머지 → `/ganpan:review-queue` → `status:qa`.
5. `/ganpan:qa-check` → `status:done` (실패 시 rework/blocked).

---

## 무인 운영 (auto mode)

레인은 `/loop`으로 **사람 개입 없이** 도는 것을 전제로 설계되어 있습니다. 그러려면 Claude Code가 레인이 실행하는 봇 쓰기(`gh`, `git`, `scripts/orchestration/*.sh`)마다 승인 프롬프트를 띄우지 않아야 합니다.

1. **권한 허용 목록(권장).** `.claude/settings.json`의 `permissions.allow`에 레인이 쓰는 명령을 등록해 매번 묻지 않게 합니다. 예:
   ```jsonc
   {
     "permissions": {
       "allow": [
         "Bash(gh issue:*)", "Bash(gh pr:*)", "Bash(gh api:*)",
         "Bash(git:*)", "Bash(./scripts/orchestration/:*)"
       ]
     }
   }
   ```
   허용 범위는 필요에 맞게 좁히세요. 특히 `gh api --method DELETE`처럼 **외부 시스템을 바꾸는** 호출은 안전 분류기가 기본적으로 더 강하게 게이팅하므로, 정말 필요할 때만 명시적으로 허용 규칙(`Bash(gh api --method DELETE:*)` 등)을 추가하세요.
2. **편집 자동 수락.** 무인 루프에서는 편집 승인 모드(예: `acceptEdits`)를 켜 코드·문서 편집이 멈추지 않게 합니다.
3. **안전장치는 그대로.** auto mode여도 **에이전트는 PR을 머지·승인하지 않습니다**(branch protection으로 강제). 또 각 레인은 시작 시 `gh` 행위 주체가 `config.bot`인지 확인하고 아니면 즉시 중단하므로, `GH_TOKEN`(봇 PAT)을 먼저 export 해야 합니다(위 "셋업 이후 사람이 해야 할 일" 참고).

> `/loop`으로 표준 레인을 돌리면, 각 틱의 실제 작업은 **일회용 서브에이전트**에서 실행되고 메인 세션에는 한 줄 요약만 남습니다 — 반복 틱마다 컨텍스트가 무한히 쌓이는 것을 막기 위한 설계입니다(#66).

---

## 설정 (`.ganpan/orchestration.json` 또는 `.claude/orchestration.json`)

config discovery 순서:

1. `$ORCH_CONFIG`
2. `.ganpan/orchestration.json`
3. `.claude/orchestration.json`

새 Codex 설치는 `.ganpan/orchestration.json`을 사용합니다. 기존 Claude 설치는 `.claude/orchestration.json`을 계속 사용할 수 있습니다.

```jsonc
{
  "repo": "owner/repo",          // 대상 레포
  "bot": "bot-login",            // 봇 계정 로그인
  "candidateN": 5,               // Coder가 한 번에 고려하는 후보 이슈 수
  "wipLimit": 5,                 // 동시 진행(in-progress) 상한
  "reclaim": { "timeoutMinutes": 120, "heartbeatMinutes": 15 },
  "commands": { "test": null, "build": null, "lint": null },  // 자동 감지 보완용
  "worktreeBaseDir": "../",      // wt-issue-<n> 가 생성될 위치
  "project": { "number": null, "statusField": "Status" }      // GitHub Project 연동(선택)
}
```

---

## 컨벤션 (대상 레포에 병합됨)

- **커밋:** Conventional Commits — `type(scope): subject` (`type` ∈ feat, fix, docs, refactor, test, chore, perf, build, ci). 본문은 *무엇을·왜*, 푸터는 자동 종료되지 않는 참조 `Refs #<n>` (QA가 최종 종료를 담당 — 자동 종료 키워드는 머지 시 이슈를 닫아 qa-check를 건너뜀).
- **브랜치/worktree:** 이슈 1개 → 브랜치 `issue-<n>` → worktree `../wt-issue-<n>`. 남의 `wt-issue-*`를 force-push·삭제 금지.
- **머지 게이트:** 에이전트는 PR 승인·머지를 하지 않음. 사람이 리뷰·머지(branch protection으로 강제).

---

## 저장소 구조

```
.claude-plugin/marketplace.json          # 마켓플레이스 매니페스트 (name: laeyoung)
plugins/orchestration/
  ├─ .claude-plugin/plugin.json          # 플러그인 매니페스트 (name: ganpan)
  ├─ commands/                           # 레인 커맨드 (triage / work-issue / ... / run-all)
  ├─ scripts/orchestration/              # 엔진 셸 스크립트 (claim, reclaim, lib, ...)
  ├─ references/lanes/                   # 공유 lane protocol reference
  └─ assets/                             # config 템플릿, labels.yml, 이슈 템플릿, CLAUDE.md
plugins/ganpan-codex/
  ├─ skills/ganpan-*/                    # Codex repo-local skill source
  └─ assets/AGENTS.md                    # Codex target repo conventions
install.sh                               # copy-in 설치/업그레이드
docs/SETUP.md                            # 상세 셋업 가이드
tests/                                   # bats 테스트
```

---

## 알려진 잔여 위험

- 봇 토큰이 Projects:write 보유 → 영향 범위가 넓음(라이브 보드 sync를 위한 트레이드오프).
- 단일 봇 정체성 → self-approval은 토큰 분리가 아니라 branch protection으로만 차단됨.
- Contents:write 봇은 `main` 이외 브랜치를 force-push·삭제할 수 있음.

자세한 내용은 [`docs/SETUP.md`](docs/SETUP.md)를 참고하세요.

Codex 전용 설치와 실행 절차는 [`docs/CODEX_RUNBOOK.md`](docs/CODEX_RUNBOOK.md)를 참고하세요. Phase 2/3 개발자는 [`docs/PHASE1_DEV_LOG.md`](docs/PHASE1_DEV_LOG.md)와 [`docs/CODEX_ADAPTER_RULES.md`](docs/CODEX_ADAPTER_RULES.md)를 먼저 확인하세요.
