# Meridian (Docker)

[Meridian](https://github.com/rynfar/meridian)을 Docker로 실행하기 위한 compose 설정입니다.
Meridian은 Claude Agent SDK를 표준 Anthropic API와 OpenAI 호환 API로 노출하므로,
Pi, OpenCode, Claude Code, Crush, Droid 같은 도구에서 Claude Max 구독을 그대로
사용할 수 있습니다.

| 파일 | 설명 |
|---|---|
| `compose.yaml` | 서비스를 정의합니다. 1회만 실행되는 `init`과 본체인 `meridian`으로 구성됩니다. |
| `.env.example` | 환경변수 템플릿입니다. `.env`로 복사해서 사용합니다. |
| `.env` | 실제 토큰이 기재되는 파일입니다(`MERIDIAN_PROFILES` 한 곳). `.gitignore`에 등록되어 있습니다. |
| `config/sdk-features.json` | 어댑터별 SDK 기능 토글입니다. 기동할 때마다 컨테이너 설정 볼륨으로 복사됩니다. |

---

## 1. 사전 준비

- Docker Desktop 또는 OrbStack 같은 컨테이너 런타임이 실행되고 있어야 합니다.
- 호스트에 claude CLI가 설치되어 있어야 합니다. 인증은 아래의 `claude setup-token`으로만 처리합니다.

이미지는 `ghcr.io/rynfar/meridian:latest`를 내려받아 사용합니다. amd64와 arm64를
모두 지원하는 멀티아키텍처 이미지이므로 Apple Silicon에서도 에뮬레이션 없이
동작하며, 소스를 직접 빌드할 필요가 없습니다.

## 2. 인증 토큰 발급

인증은 `claude setup-token`으로 발급한 장기 OAuth 토큰을 주입하는 방식만 사용합니다.
컨테이너 안에서 `claude login`을 실행하거나 자격증명 디렉터리를 마운트하는 방식은
사용하지 않습니다.

> **macOS에서는 `~/.claude` 디렉터리를 마운트하는 방식이 동작하지 않습니다.**
> macOS의 claude CLI는 OAuth 토큰을 파일이 아니라 **Keychain**에 보관합니다.
> 따라서 디렉터리를 마운트해도 컨테이너는 비어 있는 자격증명 저장소를 참조하게 되고,
> 모든 요청이 401로 실패합니다.

```bash
cd ~/dev/meridian
cp .env.example .env

claude setup-token          # sk-ant-oat01-... 형태의 토큰이 출력됩니다
```

출력된 토큰은 `.env`의 **`MERIDIAN_PROFILES`** 한 곳에만 기재합니다. 계정이 하나여도
원소가 하나인 배열로 씁니다. 토큰을 넣는 자리를 하나로 고정해 두기 위해
`CLAUDE_CODE_OAUTH_TOKEN`은 사용하지 않습니다.

```
MERIDIAN_PROFILES=[{"id":"personal","oauthToken":"sk-ant-oat01-..."}]
MERIDIAN_DEFAULT_PROFILE=personal
MERIDIAN_ROUTING=active
```

`MERIDIAN_PROFILES`는 반드시 **한 줄짜리 JSON**이어야 합니다. 형식이 깨지면 기동
로그에 `[meridian] Failed to parse MERIDIAN_PROFILES:`가 남고 인증이 붙지 않습니다.

이 토큰 하나가 곧 자격증명이므로, 마운트할 대상도 없고 컨테이너 안에서 브라우저를 열
필요도 없습니다. 토큰이 만료에 가까워지면 `/health` 응답의 `auth.renewalRequiredSoon`이
`true`로 바뀌므로, 그때 같은 명령으로 다시 발급해 같은 자리에 덮어쓰면 됩니다.

## 3. 실행

```bash
docker compose up -d
docker compose logs -f meridian     # 기동 로그
curl -s localhost:3456/health | jq  # auth.loggedIn 이 true 여야 정상입니다
```

정상적으로 기동되었다면 다음과 같은 응답을 확인할 수 있습니다.

```json
{
  "status": "healthy",
  "version": "1.68.0",
  "build": { "source": "local", "version": "1.68.0" },
  "auth": { "loggedIn": true, "renewalRequiredSoon": false },
  "mode": "passthrough",
  "claudeExecutable": { "path": "/app/node_modules/@anthropic-ai/claude-code/bin/claude.exe", "source": "bundled" },
  "plugin": { "opencode": "not-configured" }
}
```

몇 가지는 처음 보면 오해하기 쉬우므로 미리 설명해 둡니다.

- `build.source`가 `npm`이 아니라 `local`로 나오는 것이 정상입니다. 공식 이미지는 소스를 빌드해서 만들기 때문에, npm 설치본으로 인식되지 않습니다.
- `auth`에 `email`과 `subscriptionType`이 없는 것도 정상입니다. 토큰 방식에서는 계정 정보가 담긴 자격증명 파일을 읽지 않기 때문입니다.
- `plugin.opencode`가 `not-configured`인 것은 컨테이너 안에서 `meridian setup`을 실행하지 않았다는 뜻이며, OpenCode를 쓰지 않는다면 신경 쓰지 않아도 됩니다.

브라우저에서 확인할 수 있는 화면은 다음과 같습니다.

- 대시보드 <http://127.0.0.1:3456/telemetry>: 요청 성능, 토큰 사용량, 프롬프트 캐시 효율, 비용 추정치를 보여줍니다.
- 프로필 <http://127.0.0.1:3456/profiles>: 계정 프로필을 조회하고 전환합니다.
- 설정 <http://127.0.0.1:3456/settings>: SDK 기능 토글과 모델 단가 재정의 값을 관리합니다.

## 4. SDK 기능 토글 (`config/sdk-features.json`)

`/settings` 화면의 토글은 컨테이너 안의 `~/.config/meridian/sdk-features.json`에
저장됩니다. 이 값을 화면에서만 바꾸면 볼륨을 삭제할 때 함께 사라지므로, 레포의
`config/sdk-features.json`을 선언된 상태로 두고 `init` 컨테이너가 기동할 때마다
볼륨으로 복사하도록 구성했습니다.

현재 설정은 다음과 같습니다.

```json
{
  "pi": {
    "codeSystemPrompt": true,
    "clientSystemPrompt": false
  }
}
```

`clientSystemPrompt`는 설정 화면의 **Client Prompt** 항목이며, 연결한 에이전트가 보낸
시스템 프롬프트를 SDK 요청에 포함할지 결정합니다. Pi 어댑터에서는 이 값을 끕니다.
`codeSystemPrompt`는 Claude Code 자체의 시스템 프롬프트 프리셋을 포함할지 결정하며,
기본값 그대로 켜 둡니다. 기본값과 같더라도 명시해 두면 의도가 드러나므로 함께
기재했습니다.

최상위 키는 어댑터 이름이므로, 다른 도구를 쓴다면 `opencode`, `crush`, `droid`,
`claude-code`, `openai`, `passthrough` 같은 키를 같은 방식으로 추가하면 됩니다.
지정하지 않은 어댑터와 항목은 Meridian의 기본값을 따릅니다.

설정 파일은 요청을 처리할 때마다 다시 읽히므로(약 5초 캐시) 값을 바꾼 뒤 재시작할
필요는 없습니다. 다만 레포의 파일을 볼륨에 반영하려면 `init`을 다시 실행해야 합니다.

```bash
docker compose up -d          # init 이 다시 돌면서 파일을 복사합니다
docker compose logs init      # [init] seeded sdk-features.json 확인
```

`/settings` 화면에서 값을 바꾸면 그 자리에서 바로 적용되지만, 다음에 `up`을 실행할
때 레포의 파일 내용으로 되돌아갑니다. 계속 유지하려면 레포의 파일에도 반영하십시오.

## 5. 포트

호스트의 **3456** 포트가 컨테이너의 3456 포트로 연결됩니다. npm 전역 설치본이
사용하던 포트를 그대로 쓰므로, 클라이언트 설정을 바꾸지 않고 컨테이너로 옮겨올 수
있습니다. 두 가지를 동시에 띄워서 비교하려면 `.env`에 `MERIDIAN_HOST_PORT=3466`처럼
다른 포트를 지정하십시오.

포트는 `127.0.0.1`에만 바인딩되어 있습니다. 다른 기기에서 접속해야 한다면
`compose.yaml`의 `127.0.0.1:` 접두사를 제거하고, 이때 **반드시** `.env`에
`MERIDIAN_API_KEY`를 설정하십시오. 인증 수단 없이 네트워크에 공개된 프록시는
포트에 접근할 수 있는 누구나 Claude Max 구독을 소진할 수 있게 만듭니다.

## 6. 클라이언트 연결

API 키 값은 자리표시자입니다. Meridian은 API 키가 아니라 Claude Code SDK로 인증하기
때문에 아무 문자열이나 지정해도 됩니다. `MERIDIAN_API_KEY`를 설정했다면 그 값을
지정합니다.

**Pi**는 `~/.pi/agent/models.json`에 전용 프로바이더를 추가해서 연결합니다.

```json
{
  "providers": {
    "meridian": {
      "name": "Meridian (Claude Max)",
      "baseUrl": "http://127.0.0.1:3456",
      "api": "anthropic-messages",
      "apiKey": "x",
      "headers": { "x-meridian-agent": "pi" },
      "models": [
        { "id": "claude-opus-5", "name": "Claude Opus 5 (Meridian)", "contextWindow": 1000000, "maxTokens": 128000 }
      ]
    }
  }
}
```

Pi는 Claude Code의 User-Agent를 그대로 모방하기 때문에 자동 감지가 불가능합니다.
위와 같이 `x-meridian-agent` 헤더로 어댑터를 지정해야 하며, 이 헤더가 있어야 4번
항목의 Pi 설정도 적용됩니다. Pi만 사용한다면 `.env`에 `MERIDIAN_DEFAULT_AGENT=pi`를
지정하는 방법도 있습니다.

**Claude Code**는 환경변수만으로 연결됩니다.

```bash
ANTHROPIC_AUTH_TOKEN=x ANTHROPIC_BASE_URL=http://127.0.0.1:3456 claude
```

**OpenCode**도 같은 방식으로 연결됩니다.

```bash
ANTHROPIC_API_KEY=x ANTHROPIC_BASE_URL=http://127.0.0.1:3456 opencode
```

> OpenCode는 `meridian setup`으로 플러그인을 설정하는 절차가 별도로 필요합니다.
> 이 명령은 호스트에 있는 OpenCode 설정 파일을 수정하므로, 컨테이너가 아니라
> **호스트에서** 실행해야 합니다.

**OpenAI 프로토콜만 지원하는 도구**로는 Open WebUI, Continue, OpenAI SDK 등이
있습니다. base URL을 `http://127.0.0.1:3456`으로 지정하고 API 키에는 임의의 값을
넣으면 됩니다. `/v1/chat/completions`, `/v1/models`, 그리고 Codex CLI가 사용하는
`/v1/responses`를 지원합니다.

연결이 제대로 되었는지 확인하려면 다음 요청을 보내 보십시오. `ok`가 돌아오면
인증부터 응답까지 전 구간이 정상입니다.

```bash
curl -s -X POST localhost:3456/v1/messages \
  -H 'content-type: application/json' -H 'x-api-key: x' -H 'x-meridian-agent: pi' \
  -d '{"model":"claude-sonnet-5","max_tokens":16,"messages":[{"role":"user","content":"reply with the single word: ok"}]}' | jq -r '.content[0].text'
```

## 7. 도구 실행 위치 (passthrough)

Docker 이미지는 `CLAUDE_PROXY_PASSTHROUGH=1` 상태로 기동합니다. 즉 파일 읽기와 쓰기,
bash 실행 같은 도구는 **클라이언트 쪽에서** 실행되고, Meridian은 `tool_use` 블록만
중계합니다. 그래서 컨테이너에 소스 코드를 마운트할 필요가 없습니다.

컨테이너 내부에서 도구를 직접 실행시키려면 `.env`에 `MERIDIAN_PASSTHROUGH=0`을
지정하고 `compose.yaml`에 주석으로 처리해 둔 작업 디렉터리 마운트를 활성화하십시오.
이 경우 컨테이너가 호스트 파일을 실제로 수정하게 되므로, 마운트 범위를 좁게
한정하는 편이 안전합니다.

## 8. 다중 계정

계정을 늘릴 때에는 [2장](#2-인증-토큰-발급)에서 만든 `MERIDIAN_PROFILES` 배열에
원소를 추가하기만 하면 됩니다. 설정하는 자리는 단일 계정일 때와 동일합니다.

```
MERIDIAN_PROFILES=[{"id":"personal","oauthToken":"sk-ant-oat01-..."},{"id":"work","oauthToken":"sk-ant-oat01-..."}]
MERIDIAN_DEFAULT_PROFILE=personal
MERIDIAN_ROUTING=active
```

프로필별 SDK 설정 디렉터리(`CLAUDE_CONFIG_DIR`)는 `meridian-config` 볼륨 아래
`profiles/<id>`로 자동 분리되므로, 계정끼리 상태가 섞이지 않습니다.

`MERIDIAN_ROUTING`으로 지정할 수 있는 라우팅 방식은 세 가지입니다.

- `active`: 모든 트래픽을 현재 활성화된 프로필로 전달합니다.
- `sticky`: 세션을 여러 계정에 분산하면서도 계정별 프롬프트 캐시를 계속 유효한 상태로 유지합니다.
- `priority`: 한도가 소진되면 다음 계정으로 페일오버합니다. 순서는 `MERIDIAN_PROFILE_ORDER=work,personal`처럼 지정합니다.

실행 중에 프로필을 전환할 때에는 `x-meridian-profile` 헤더를 사용하거나 `/profiles`
페이지에서 변경합니다.

## 9. 운영

```bash
docker compose ps                  # 상태 (healthy 표시 확인)
docker compose logs -f meridian    # 로그 추적
docker compose restart meridian    # 재시작
docker compose down                # 중지 (볼륨은 유지)

docker compose pull && docker compose up -d   # 최신 이미지로 업데이트
```

버전을 고정하려면 `.env`에 `MERIDIAN_VERSION=1.68.0`처럼 태그를 명시합니다.
`:latest`는 편리하지만 어느 시점에 무엇이 변경되었는지 추적할 수 없습니다.

상태를 보관하는 볼륨은 다음 세 개입니다.

| 볼륨 | 마운트 위치 | 내용 |
|---|---|---|
| `claude-state` | `/home/claude/.claude` | SDK가 쓰는 상태를 보관합니다. 대화 기록(`projects/`), 세션(`sessions/`), 작업(`jobs/`)이 들어갑니다. 자격증명은 들어가지 않습니다. |
| `meridian-config` | `/home/claude/.config/meridian` | SDK 기능 토글, 프로필, 모델 단가, 그리고 텔레메트리 데이터베이스가 들어갑니다. |
| `meridian-cache` | `/home/claude/.cache/meridian` | 세션 저장소가 들어갑니다. 재시작 후에도 대화가 이어지는 근거입니다. |

> `docker compose down -v`를 실행하면 위 볼륨이 **모두 삭제**됩니다. 대화 기록과
> 텔레메트리 누적치가 함께 삭제되므로, 완전히 초기화할 때에만 사용하십시오.
> 인증 토큰은 `.env`에 있으므로 함께 사라지지 않고, SDK 기능 토글도 다음 기동 때
> `config/sdk-features.json`에서 다시 복원됩니다.

`init` 서비스는 설정 파일을 복사하고 볼륨의 소유권을 uid 1000(`claude`)으로 변경하는
1회성 컨테이너입니다. 런타임이 root가 아니라 `claude` 사용자로 동작하기 때문에
필요하며, 작업을 마치면 즉시 종료됩니다. `docker compose ps -a`에서 `Exited (0)`으로
표시되는 것이 정상입니다.

## 10. 주요 엔드포인트

| 경로 | 설명 |
|---|---|
| `POST /v1/messages` | Anthropic Messages API입니다. |
| `POST /v1/chat/completions` | OpenAI 호환 API입니다. |
| `POST /v1/responses` | OpenAI Responses API이며, Codex CLI 0.96 이상이 사용합니다. |
| `GET /v1/models` | OpenAI 호환 모델 목록을 반환합니다. |
| `GET /health` | 인증 상태와 동작 모드, 버전을 반환합니다. |
| `GET /telemetry` | 성능 대시보드입니다. `/telemetry/summary`는 같은 내용을 JSON으로 반환합니다. |
| `GET /metrics` | Prometheus 형식의 메트릭을 노출합니다. |
| `GET /profiles` | 프로필 관리 화면입니다. |
| `GET /settings` | SDK 기능 토글과 모델 단가를 관리하는 화면입니다. `/settings/api/features`는 어댑터별로 해석된 값을 JSON으로 반환합니다. |
| `GET /v1/usage/quota` | 활성 프로필에 적용된 사용량 윈도우를 반환합니다. |
| `POST /auth/refresh` | OAuth 토큰을 수동으로 갱신합니다. |

전체 목록과 환경변수는 [configuration 문서](https://github.com/rynfar/meridian/blob/main/docs/configuration.md)에서 확인할 수 있습니다.

## 11. 문제 해결

**모든 요청이 401로 실패합니다.** 토큰에 문제가 있는 상황입니다.
`curl -s localhost:3456/health | jq .auth`로 `loggedIn` 값을 확인하십시오. `false`라면
`.env`의 `MERIDIAN_PROFILES` 안에 있는 `oauthToken`이 비어 있거나 만료된 것입니다.
`claude setup-token`으로 다시 발급한 다음 `docker compose up -d`로 재기동하면
해결됩니다. `.env`를 변경한 내용은 `restart`가 아니라 `up -d`를 실행해야 반영됩니다.

`docker compose logs meridian | grep MERIDIAN_PROFILES`로
`Failed to parse MERIDIAN_PROFILES`가 찍혔는지도 함께 보십시오. JSON이 여러 줄로
나뉘었거나 따옴표가 빠진 경우가 대부분입니다.

**포트가 충돌합니다(`address already in use`).** 호스트의 3456 포트를 다른 프로세스가
사용하고 있습니다. npm 전역 설치본이 아직 떠 있는 경우가 대부분이므로
`lsof -nP -iTCP:3456 -sTCP:LISTEN`으로 확인해서 종료하거나, `.env`의
`MERIDIAN_HOST_PORT`를 다른 값으로 변경하십시오.

**`/home/claude/` 아래에서 권한 오류(`EACCES`)가 발생합니다.** `init` 컨테이너가
정상적으로 실행되지 않았을 수 있습니다. `docker compose up init`을 한 번 직접
실행해 보십시오.

**Client Prompt를 껐는데 계속 적용되지 않습니다.** 요청에 `x-meridian-agent: pi`
헤더가 실려 있는지 먼저 확인하십시오. 이 헤더가 없으면 Pi는 Claude Code로 감지되어
`pi`가 아닌 다른 어댑터의 설정이 적용됩니다. 실제로 어떤 값이 적용되고 있는지는
`curl -s localhost:3456/settings/api/features | jq .pi`로 확인할 수 있습니다.

**응답이 비어 있거나 도구 호출이 반환되지 않습니다.** 어댑터가 잘못 감지된 상황일 수
있습니다. `.env`에 `MERIDIAN_DEBUG=1`을 지정하고 로그에서 어떤 어댑터가 선택되었는지
확인하십시오.

## 12. npm 전역 설치본과의 관계

호스트에는 `@rynfar/meridian`이 npm 전역으로 설치되어 있습니다. 지금은 호스트
프로세스를 중지하고 컨테이너가 3456 포트를 사용하고 있으므로, 두 가지를 함께
띄우려면 `.env`의 `MERIDIAN_HOST_PORT`로 포트를 분리해야 합니다.

`meridian setup`이나 `meridian profile add`처럼 호스트의 설정 파일을 수정하는 CLI
명령은 컨테이너가 아니라 호스트의 npm 설치본으로 실행하십시오. 다만 컨테이너의
프로필과 설정은 호스트의 `~/.config/meridian`이 아니라 `meridian-config` 볼륨에
저장되므로, 호스트에서 실행한 프로필 명령의 결과는 컨테이너에 반영되지 않습니다.
컨테이너 쪽 설정은 `.env`와 `config/sdk-features.json`, 그리고 `/settings` 화면으로
관리합니다.
