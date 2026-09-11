#!/usr/bin/env bash
# Meridian 캐시 및 세션 재개 현황을 유형별로 빠르게 집계하는 스크립트.
# 내부적으로 ./scripts/telemetry.sh 를 호출합니다.
#
# 사용법:
#   ./scripts/cache-report.sh [유형] [옵션]
#
# 유형:
#   summary        (기본) 어댑터별 요청 수, 단순평균/가중평균 캐시율, 캐시 토큰량
#   resume         대화 지속(continuation) 시 SDK 세션 재개(resume) 성공률 및 캐시율 비교
#   corrected      03:48 어댑터 수정 이전의 opencode를 'claude-code (오분류)'로 분리 집계
#   hourly [N]     최근 N시간(기본 24) 시간대별·어댑터별 캐시율 추이 (로컬 시간)
#   depth          대화 길이(message_count 구간)에 따른 캐시율 및 TTFB 변화
#   recent [N]     최근 N건(기본 15) 요청 상세 내역 (시각, 어댑터, 세션재개, 캐시율, 토큰, TTFB)
#   all            주요 지표(요약, resume, 깊이별, 시간대별)를 한눈에 볼 수 있는 종합 리포트
#
# 옵션:
#   --json         테이블 대신 JSON 형식으로 출력
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELEMETRY="$DIR/telemetry.sh"

if [ ! -x "$TELEMETRY" ]; then
  echo "오류: $TELEMETRY 실행 파일이 없습니다." >&2
  exit 1
fi

JSON_FLAG=""
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--json" ]; then
    JSON_FLAG="--json"
  else
    ARGS+=("$arg")
  fi
done

CMD="${ARGS[0]:-help}"
EXTRA="${ARGS[1]:-}"

# 어댑터 설정 변경(claudecode 적용) 시각 (기본값: 2026-09-09 03:48:00)
FIX_TIME="${MERIDIAN_FIX_TIME:-2026-09-09T03:48:00}"

run_sql() {
  local sql="$1"
  if [ -n "$JSON_FLAG" ]; then
    "$TELEMETRY" --json "$sql"
  else
    "$TELEMETRY" "$sql"
  fi
}

case "$CMD" in
  summary|adapter)
    run_sql "
SELECT adapter,
       COUNT(*)                                    AS reqs,
       ROUND(AVG(cache_hit_rate) * 100, 1)         AS avg_rate_pct,
       ROUND(100.0 * SUM(cache_read_input_tokens)
             / SUM(cache_read_input_tokens + cache_creation_input_tokens + input_tokens), 1)
                                                   AS weighted_pct,
       SUM(cache_read_input_tokens)                AS cache_read,
       SUM(cache_creation_input_tokens)            AS cache_write
FROM metrics
WHERE status = 200 AND cache_hit_rate IS NOT NULL
GROUP BY adapter
ORDER BY reqs DESC"
    ;;

  resume)
    run_sql "
SELECT adapter,
       COUNT(*)                                                     AS reqs,
       SUM(is_resume)                                               AS resumed,
       ROUND(100.0 * SUM(is_resume) / COUNT(*), 1)                  AS resume_pct,
       ROUND(AVG(CASE WHEN is_resume = 1 THEN cache_hit_rate END) * 100, 1) AS cache_on_resume,
       ROUND(AVG(CASE WHEN is_resume = 0 THEN cache_hit_rate END) * 100, 1) AS cache_no_resume
FROM metrics
WHERE status = 200 AND lineage_type = 'continuation'
GROUP BY adapter
ORDER BY reqs DESC"
    ;;

  corrected)
    run_sql "
WITH tagged AS (
  SELECT *,
         CASE WHEN adapter = 'opencode'
                   AND timestamp < strftime('%s', '$FIX_TIME') * 1000
              THEN 'claude-code (오분류)'
              ELSE adapter
         END AS client
  FROM metrics
  WHERE status = 200 AND cache_hit_rate IS NOT NULL
)
SELECT client,
       COUNT(*)                                     AS reqs,
       SUM(is_resume)                               AS resumed,
       ROUND(100.0 * SUM(cache_read_input_tokens)
             / SUM(cache_read_input_tokens + cache_creation_input_tokens + input_tokens), 1)
                                                    AS weighted_pct,
       SUM(cache_read_input_tokens)                 AS cache_read,
       SUM(cache_creation_input_tokens)             AS cache_write
FROM tagged
GROUP BY client
ORDER BY reqs DESC"
    ;;

  hourly)
    LIMIT_HOURS="${EXTRA:-24}"
    run_sql "
SELECT strftime('%m-%d %H:00', timestamp / 1000, 'unixepoch', 'localtime') AS hour,
       adapter,
       COUNT(*)                                     AS reqs,
       ROUND(100.0 * SUM(cache_read_input_tokens)
             / SUM(cache_read_input_tokens + cache_creation_input_tokens + input_tokens), 1)
                                                    AS weighted_pct,
       ROUND(AVG(ttfb_ms))                          AS avg_ttfb_ms
FROM metrics
WHERE status = 200 AND cache_hit_rate IS NOT NULL
GROUP BY hour, adapter
ORDER BY hour DESC, reqs DESC
LIMIT $LIMIT_HOURS"
    ;;

  depth)
    run_sql "
SELECT CASE WHEN message_count < 10  THEN '1: <10'
            WHEN message_count < 50  THEN '2: 10-49'
            WHEN message_count < 150 THEN '3: 50-149'
            ELSE '4: 150+'
       END AS depth,
       COUNT(*)                                     AS reqs,
       ROUND(100.0 * SUM(cache_read_input_tokens)
             / SUM(cache_read_input_tokens + cache_creation_input_tokens + input_tokens), 1)
                                                    AS weighted_pct,
       SUM(cache_creation_input_tokens)             AS cache_write,
       ROUND(AVG(ttfb_ms))                          AS avg_ttfb_ms,
       ROUND(AVG(total_duration_ms) / 1000.0, 2)    AS avg_total_sec
FROM metrics
WHERE status = 200 AND cache_hit_rate IS NOT NULL
GROUP BY depth
ORDER BY depth"
    ;;

  recent)
    LIMIT_ROWS="${EXTRA:-15}"
    run_sql "
SELECT strftime('%H:%M:%S', timestamp / 1000, 'unixepoch', 'localtime') AS time,
       adapter,
       CASE WHEN is_resume = 1 THEN 'Y' ELSE 'N' END AS resume,
       message_count AS msgs,
       ROUND(cache_hit_rate * 100, 1) AS hit_pct,
       input_tokens,
       output_tokens,
       cache_read_input_tokens AS cache_read,
       ROUND(ttfb_ms) AS ttfb_ms,
       ROUND(total_duration_ms / 1000.0, 1) AS total_s
FROM metrics
WHERE status = 200 AND cache_hit_rate IS NOT NULL
ORDER BY id DESC
LIMIT $LIMIT_ROWS"
    ;;

  all)
    echo "================================================================================"
    echo "1. 어댑터별 캐시 집계 (전체 누적)"
    echo "================================================================================"
    "$0" summary $JSON_FLAG
    echo ""
    echo "================================================================================"
    echo "2. 세션 재개(Resume) 성공 여부 및 캐시율 비교 (continuation 요청 대상)"
    echo "================================================================================"
    "$0" resume $JSON_FLAG
    echo ""
    echo "================================================================================"
    echo "3. 어댑터 오분류 보정 (수정 전 opencode → claude-code 오분류 분리)"
    echo "================================================================================"
    "$0" corrected $JSON_FLAG
    echo ""
    echo "================================================================================"
    echo "4. 대화 길이(메시지 수) 구간별 캐시 효율 및 응답 속도"
    echo "================================================================================"
    "$0" depth $JSON_FLAG
    echo ""
    echo "================================================================================"
    echo "5. 최근 시간대별 추이 (최근 8개 슬롯)"
    echo "================================================================================"
    "$0" hourly 8 $JSON_FLAG
    ;;

  help|--help|-h)
    cat << 'EOF'
Meridian 텔레메트리 캐시 히트 집계 도구

사용법:
  ./scripts/cache-report.sh <명령> [옵션]

명령 목록:
  summary          어댑터별 캐시율 (단순평균, 가중평균, 캐시 토큰량)
  resume           대화 지속 시 세션 재개(is_resume) 성공률과 캐시율 상관관계
  corrected        어댑터 수정 전 opencode 요청을 claude-code(오분류)로 분리
  hourly [N]       최근 N시간(기본 24) 시간대별 추이 (KST 기준)
  depth            대화 깊이(메시지 수: <10, 10-49, 50-149, 150+)별 캐시율
  recent [N]       최근 N건(기본 15) 개별 요청 상세 내역
  all              위 주요 보고서를 한 번에 출력

옵션:
  --json           출력 형식을 JSON 배열로 변경

예시:
  ./scripts/cache-report.sh summary
  ./scripts/cache-report.sh resume
  ./scripts/cache-report.sh hourly 12
  ./scripts/cache-report.sh recent 20
  ./scripts/cache-report.sh all
  ./scripts/cache-report.sh summary --json | jq .
EOF
    ;;

  *)
    echo "알 수 없는 명령: $CMD" >&2
    echo "도움말을 보려면 './scripts/cache-report.sh help' 를 실행하십시오." >&2
    exit 1
    ;;
esac
