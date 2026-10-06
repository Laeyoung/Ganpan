# Ganpan 전체 테스트 보고서 — 2026-10-06

> **다음 세션용 안내:** 이 문서는 이어서 고칠 작업 목록입니다. 아래 "발견 사항"의 각 항목에는
> 재현 명령, 수정 위치, 권장 수정, 검증 명령, 완료 체크박스가 있습니다. 한 항목씩 처리하고 체크한 뒤
> 커밋하세요. 레포 규칙(Conventional Commits, `docs/log/` 기록, 버전 bump, 머지 후
> `scripts/release.sh X.Y.Z` 태그)은 `CLAUDE.md`를 따릅니다.

## 테스트 대상

| 항목 | 값 |
|---|---|
| 브랜치 / 커밋 | `main` @ `3b6281e` (PR #92 머지 직후, 태그 `v1.16.1`) |
| 버전 | plugin.json = package.json = `ganpan-setup` 고정 버전 = `1.16.1` |
| 환경 | macOS (darwin 25), bash 5.3.9 + `/bin/bash` 3.2.57, Node v24.13.0 (+ `npx node@18`), Bats 1.13.0, shellcheck 0.11.0, jq 1.7.1, yq v4.53.3 |

## 결과 요약

| # | 검사 | 결과 |
|---|---|---|
| 1 | `bats tests/*.bats tests/orchestration/*.bats` (bash 5) | ✅ 310/310, skip 0 (약 82초) |
| 2 | 같은 스위트를 **bash 3.2** (`/bin/bash`, macOS 기본)로 실행 | ✅ 310/310 |
| 3 | `shellcheck plugins/orchestration/scripts/orchestration/*.sh scripts/release.sh` | ✅ clean |
| 4 | `shellcheck install.sh` (CI 대상 아님) | ✅ clean, 단 CI에서 보호되지 않음 → **F2** |
| 5 | `jq .` manifest 3종 (marketplace, plugin, package) | ✅ |
| 6 | `claude plugin validate .` | ⚠️ 통과, 경고 1건 → **F5** |
| 7 | `install.sh` target 5종 × 새 설치 + 재실행 + 기존 CLAUDE.md/AGENTS.md | ✅ 모두 멱등, 추가 블록 1회만, config·skills(6)·commands(8)가 target별 기대대로 |
| 8 | 업그레이드 (sentinel v1.15.1 → 재설치) | ✅ 1.16.1로 갱신, sentinel 없는 사용자 파일은 경고 후 보존 |
| 9 | 문서 상대 링크 (README, docs/*.md, CLAUDE.md) | ✅ 깨진 링크 없음 |
| 10 | `npx skills add Laeyoung/Ganpan --list` (GitHub main) | ✅ `ganpan-*` 6개 |
| 11 | 이전 태그 `npx -y github:Laeyoung/Ganpan#v1.16.0 --version` | ✅ 1.16.0 (하위 호환) |
| 12 | Node 18: `--version` / `init` / `validate` | ✅ |
| 13 | v1.16.1 실사용 흐름 (`npx skills add -g` → `init --target claude` → `validate`) | ✅ (머지 후 별도 확인) |
| 14 | npx로 설치한 레포에서 `update-info.sh` | ✅ 버전 고정 npx 안내 출력, 기존 install.sh 안내 문구는 → **F4** |
| 15 | config 두 개가 다를 때 `validate` | ⚠️ 경고 없음 → **F3** |
| 16 | 이 레포의 dogfood 엔진 사본 | ⚠️ v1.15.1, 공식 업그레이드 경로 없음 → **F1** |

**결론:** 테스트 실패나 기능 버그는 없습니다. 아래 발견 사항은 운영, 일관성, 문서에 관한 것이며
심각도는 Medium 1건, Low 5건, Info 2건입니다.

---

## 발견 사항 (수정 대상)

### F1 — [Medium] dogfood 엔진 사본이 오래됐고, 공식 업그레이드 경로가 없음
- **현상:** 이 레포는 자기 이슈에 레인을 돌리려고 엔진을 레포 루트에 설치해 둡니다(`.gitignore`의
  `/scripts/*`, `/references/`, `/.claude/commands/` 주석 참고). 그런데 그 사본이 `v1.15.1`입니다.
  또 `reviewer.autoMerge: true`라 레인이 실제로 PR을 머지합니다.
  - sentinel을 빼고 비교하면 내용이 다른 파일은 **`scripts/orchestration/update-info.sh` 하나**입니다(#90의 npx 안내 줄).
  - 나머지 파일은 1.16.x와 내용이 같고 sentinel만 다릅니다.
- **원인:** 두 설치 경로가 모두 자기 레포를 의도적으로 거부합니다.
  - `install.sh:72` — `target must differ from the toolkit source`
  - `bin/ganpan.mjs:183` — `… is a ganpan checkout`
- **재현:**
  ```bash
  tail -1 scripts/orchestration/lib.sh            # → # ganpan-orchestration: v1.15.1
  bash install.sh . --target codex                # → error: target must differ …
  node bin/ganpan.mjs init .                      # → … is a ganpan checkout
  for f in plugins/orchestration/scripts/orchestration/*.sh; do b=$(basename $f); \
    diff -qB <(grep -v ganpan-orchestration: $f) <(grep -v ganpan-orchestration: scripts/orchestration/$b) >/dev/null || echo $b; done
  ```
- **권장 수정 (택 1, 설계 결정 필요):**
  1. `install.sh`에 명시적 플래그 `--self`(또는 `--allow-self`)를 추가합니다. TARGET==SRC일 때 이
     플래그가 있으면 허용하고, 없으면 지금처럼 거부합니다. `bin/ganpan.mjs`의 체크아웃 거부는 유지합니다.
     npx 사용자를 보호하는 장치이기 때문입니다. 테스트는 `tests/install.bats`에 넣습니다(플래그 없이
     거부, 플래그가 있으면 루트에 설치되고 sentinel이 갱신됨).
  2. 전용 스크립트 `scripts/dogfood-sync.sh`를 만듭니다(`.gitignore`의 `!/scripts/release.sh`처럼
     예외 추가 필요). install.sh를 임시 디렉터리에 설치한 뒤 루트로 복사하는 래퍼입니다.
  3. 최소 대응: `docs/RELEASE_PLAYBOOK.md` §7에 "dogfood 사본 갱신" 수동 절차를 문서화합니다.
- **검증:** 수정 후 `tail -1 scripts/orchestration/lib.sh`가 현재 버전을 보이고, 위 diff 루프 출력이 비어야 합니다.
- [ ] 완료

### F2 — [Low] `install.sh`가 shellcheck 보호 범위 밖
- **현상:** `install.sh`는 지금 shellcheck에서 경고가 없지만, CI와 문서의 lint 명령에 빠져 있어 회귀를 막지 못합니다.
  사용자 레포에 직접 실행되는 가장 중요한 스크립트입니다.
- **위치:**
  - `.github/workflows/ci.yml:70`
  - `CLAUDE.md:10`
  - `docs/RELEASE_PLAYBOOK.md:46`
  - `docs/RELEASE_CHECKLIST.md:18`
- **권장 수정:** 네 곳의 shellcheck 명령에 `install.sh`를 추가합니다:
  `shellcheck plugins/orchestration/scripts/orchestration/*.sh scripts/release.sh install.sh`
- **검증:** `shellcheck plugins/orchestration/scripts/orchestration/*.sh scripts/release.sh install.sh` → exit 0.
  PR CI가 통과하는지 확인합니다.
- [ ] 완료

### F3 — [Low] `ganpan validate`가 config 두 개가 다를 때 경고하지 않음
- **현상:** `.ganpan/orchestration.json`과 `.claude/orchestration.json`이 둘 다 있고 내용이 다를 때:
  - `install.sh`는 `warning: both … exist and differ; .ganpan wins`를 출력합니다.
  - `ganpan validate`는 아무 말 없이 `.ganpan`을 `ok`로 보고합니다.

  사용자는 `.claude` 쪽 설정이 무시되는 줄 모릅니다.
- **위치:** `bin/ganpan.mjs:49-55` (`checkConfig`)
- **재현:**
  ```bash
  T=$(mktemp -d); mkdir -p $T/.git; bash install.sh $T --target codex >/dev/null
  jq '.repo="acme/a"|.bot="a-bot"' $T/.ganpan/orchestration.json > /tmp/c && mv /tmp/c $T/.ganpan/orchestration.json
  mkdir -p $T/.claude && jq '.repo="acme/b"|.bot="b-bot"' $T/.ganpan/orchestration.json > $T/.claude/orchestration.json
  node bin/ganpan.mjs validate $T     # 경고 없음
  ```
- **권장 수정:** `$ORCH_CONFIG`가 없고 두 파일이 모두 있으며 내용이 다르면
  `warn both .ganpan/orchestration.json and .claude/orchestration.json exist and differ; using .ganpan`을
  출력합니다(warn이므로 exit 코드는 그대로). 테스트는 `tests/cli.bats`에 넣습니다(내용이 다르면 warn,
  같으면 warn 없음). fix이므로 patch bump(1.16.2)가 필요합니다.
- **검증:** `bats tests/cli.bats`
- [ ] 완료

### F4 — [Low] `update-info.sh`의 install.sh 안내 문구가 헷갈림
- **현상:** copy-in 모드 안내 `./install.sh . --target both --force`에서 `.`가 대상 레포처럼 읽힙니다.
  그런데 이 명령은 ganpan 체크아웃 안에서 실행해야 하고, 실제 인자는 대상 레포 경로입니다.
  `--target both`도 원래 설치한 target과 무관하게 고정되어 있습니다.
  (target별 맞춤 안내는 `docs/superpowers/specs/2026-06-26-ganpan-update-command.md`에서 의도적으로
  범위 밖으로 둔 결정입니다. 바꾸기 전에 그 결정을 다시 확인하세요.)
- **위치:** `plugins/orchestration/scripts/orchestration/update-info.sh:77`
- **권장 수정 (문구만):**
  `./install.sh <this-repo-path> --target <your-target> --force   # run from a ganpan checkout`.
  `tests/orchestration/update-info.bats`의 copy-in 안내 테스트(`install.sh`와 `--force`가 출력에
  포함되는지 확인)가 계속 통과하는지 봅니다.
- **검증:** `bats tests/orchestration/update-info.bats`
- [ ] 완료

### F5 — [Low] `claude plugin validate`가 marketplace description 누락을 경고
- **현상:** `claude plugin validate .` → `⚠ description: No marketplace description provided`.
- **위치:** `.claude-plugin/marketplace.json`
- **권장 수정:** `metadata.description`을 추가합니다. 스크래치 복사본에서 최상위 `description`과
  `metadata.description` 둘 다 경고 없이 통과하는 것을 확인했습니다.
  ```json
  "metadata": { "description": "GitHub-native agent orchestration toolkit (ganpan)." }
  ```
- **검증:** `claude plugin validate .` → `✔ Validation passed`(경고 없음). `jq . .claude-plugin/marketplace.json`.
- [ ] 완료

### F6 — [Low] `docs/RELEASE_PLAYBOOK.md`의 "Current release readiness" 수치가 오래됨
- **현상:** `bats = 204/204 passing`이라고 적혀 있지만 현재는 310개입니다.
- **위치:** `docs/RELEASE_PLAYBOOK.md:119`
- **권장 수정:** 수치를 지우고 "릴리스할 때마다 §3 게이트를 실행" 같은 시점 독립 문장으로 바꿉니다.
  숫자를 계속 유지하려면 릴리스마다 갱신해야 합니다.
- [ ] 완료

## 참고 사항 (Info — 수정 선택)

- **I1 — 테스트 헬퍼 shellcheck SC2010:** `tests/orchestration/helpers/common.bash:21`
  (`ls "$GH_RESPONSES" | grep -c '^[0-9]'`). 파일 이름이 숫자뿐이라 실제 문제는 없고,
  헬퍼는 CI shellcheck 대상도 아닙니다. 고친다면 glob 카운트로 바꿉니다
  (`set -- "$GH_RESPONSES"/[0-9]*; [ -e "$1" ] && n=$(($#+1)) || n=1`).
- **I2 — macOS CI의 `yq`는 brew 버전 그대로:** `.github/workflows/ci.yml:59`. Linux는 #91에서
  v4.54.1과 sha256으로 고정했습니다. brew bottle은 자체 checksum이 있어 의도적으로 두었습니다
  (`docs/log/2026-10-06-ci-pin-yq.md`). CI 로그상 macOS는 yq v4.53.6입니다.

## 확인했으나 문제 없음 (재검토 불필요)

- install.sh가 sentinel 없는 사용자 파일을 보존할 때 `warn: … user-owned; skipping`을 **stdout**에
  찍습니다. 사람이 보는 설치 출력이고, 이 출력을 `$(…)`로 받아 쓰는 곳이 없어 CLAUDE.md의 stdout 계약
  위반이 아닙니다.
- Linux와 macOS 양쪽 CI 통과(`main` @ `3b6281e`). 브랜치 4개 검토 루프(dev-review-loop)를
  2회 연속 무결점으로 마쳤습니다.
- 원격 태그: `v1.16.0` → `66e499c`, `v1.16.1` → `3b6281e` (annotated).

## 다음 세션 권장 순서

1. **F2 + F5 + F6** (문서/CI/manifest만, 버전 bump 불필요) → PR 하나.
2. **F3** (`bin/ganpan.mjs` 동작 변경, 1.16.2 patch) — 테스트를 먼저 작성 → PR → 머지 후 `scripts/release.sh 1.16.2`.
   - 이때 `ganpan-setup/SKILL.md`와 README의 `#v1.16.1`도 1.16.2로 올려야 합니다
     (`tests/codex-skills.bats` 버전 고정 테스트가 확인).
3. **F4** — 스펙 결정을 다시 확인한 뒤 문구만 바꿉니다. F3와 같은 PR로 묶어도 됩니다.
4. **F1** — 설계 결정(옵션 1/2/3)을 사용자와 합의한 뒤 진행합니다.

## 재실행 명령 모음

```bash
bats tests/*.bats tests/orchestration/*.bats
shellcheck plugins/orchestration/scripts/orchestration/*.sh scripts/release.sh install.sh
jq . .claude-plugin/marketplace.json plugins/orchestration/.claude-plugin/plugin.json package.json >/dev/null
claude plugin validate .
# bash 3.2 호환 (macOS):
mkdir -p /tmp/b32 && ln -sf /bin/bash /tmp/b32/bash && PATH="/tmp/b32:$PATH" bats tests/*.bats tests/orchestration/*.bats
# 네트워크 smoke:
npx -y skills add Laeyoung/Ganpan --list
npx -y github:Laeyoung/Ganpan#v$(jq -r .version plugins/orchestration/.claude-plugin/plugin.json) --version
```
