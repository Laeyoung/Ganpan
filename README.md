# Ganpan (간판)

**GitHub-native 멀티 에이전트 오케스트레이션 툴킷** — Issues / PRs / 라벨을 단일 상태 머신으로 삼아, 여러 AI 에이전트가 **Triager → Coder → Reviewer → QA** 레인을 나눠 협업하도록 만드는 Claude Code 플러그인입니다.

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

| 레인 | 커맨드 | 역할 |
|------|--------|------|
| **Triager** | `/ganpan:triage` | 고아 락 회수(reclaim) 후 `status:triage` 이슈를 분류 → `agent-ready` 또는 `blocked` |
| **Coder** | `/ganpan:work-issue` | `agent-ready` 이슈를 클레임 → worktree에서 구현 → PR 생성 → `in-review` |
| **Reviewer** | `/ganpan:review-queue` | `in-review` PR을 리뷰. **머지/승인은 절대 안 함** — 사람에게 머지 요청, 통과 시 `qa` |
| **QA** | `/ganpan:qa-check` | 머지된 작업을 실제 실행·검증. 통과 → `done`, 실패 → rework 또는 `blocked` |
| **Setup** | `/ganpan:orch-setup` | 1회 셋업 (아래 참고) |

> 플러그인 커맨드는 플러그인 이름으로 네임스페이싱됩니다. 정식 호출은 `/ganpan:triage`이며, 충돌이 없으면 짧은 `/triage`로도 호출됩니다.

---

## 사전 준비물

- `gh` (GitHub CLI, 인증 완료), `git`, `jq`, `yq`
- 테스트 실행 시 `bats`

```bash
command -v gh jq yq git   # 모두 존재하는지 확인
gh auth status            # 인증 확인 (HTTPS 권장)
```

---

## 설치

### 방법 A — 플러그인 (권장)

```text
1. /plugin marketplace add Laeyoung/Ganpan
2. laeyoung 마켓플레이스에서 ganpan 플러그인 설치
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

---

## 셋업 이후 사람이 해야 할 일

`/ganpan:orch-setup`이 자동화하지 못하는 부분(체크리스트로 안내됨):

1. **봇 계정 + Fine-grained PAT** — 대상 레포에만 Contents RW / Pull requests RW / Issues RW / Projects RW, 만료 90일. `GH_TOKEN=github_pat_...`로 export(HTTPS 사용; `--with-token` 금지).
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

### 통합 스모크 테스트 (수동)

1. 이슈를 연다 → `status:triage` 부여됨.
2. `/ganpan:triage` 1회 → `status:agent-ready`.
3. `/ganpan:work-issue` 1회 → `status:in-progress` → PR과 함께 `status:in-review`.
4. 사람이 PR 승인·머지 → `/ganpan:review-queue` → `status:qa`.
5. `/ganpan:qa-check` → `status:done` (실패 시 rework/blocked).

---

## 설정 (`.claude/orchestration.json`)

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

- **커밋:** Conventional Commits — `type(scope): subject` (`type` ∈ feat, fix, docs, refactor, test, chore, perf, build, ci). 본문은 *무엇을·왜*, 푸터는 `Closes #<n>`.
- **브랜치/worktree:** 이슈 1개 → 브랜치 `issue-<n>` → worktree `../wt-issue-<n>`. 남의 `wt-issue-*`를 force-push·삭제 금지.
- **머지 게이트:** 에이전트는 PR 승인·머지를 하지 않음. 사람이 리뷰·머지(branch protection으로 강제).

---

## 저장소 구조

```
.claude-plugin/marketplace.json          # 마켓플레이스 매니페스트 (name: laeyoung)
plugins/orchestration/
  ├─ .claude-plugin/plugin.json          # 플러그인 매니페스트 (name: ganpan)
  ├─ commands/                           # 레인 커맨드 (triage / work-issue / ...)
  ├─ scripts/orchestration/              # 엔진 셸 스크립트 (claim, reclaim, lib, ...)
  └─ assets/                             # config 템플릿, labels.yml, 이슈 템플릿, CLAUDE.md
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
