#!/usr/bin/env bash
# telemetry.db에 임의의 SQL을 읽기 전용으로 실행한다.
#
# 컨테이너에는 sqlite3 CLI가 없고 DB는 meridian-config 볼륨 안에만 있으므로
# node 22의 node:sqlite로 컨테이너 안에서 직접 조회한다. WAL에 아직 체크포인트되지
# 않은 데이터가 4MB 가까이 쌓여 있어서, 호스트로 .db만 복사하면 최신 요청이 누락된다.
#
#   ./scripts/telemetry.sh "SELECT adapter, COUNT(*) FROM metrics GROUP BY adapter"
#   ./scripts/telemetry.sh < query.sql
#   ./scripts/telemetry.sh --json "SELECT ..."   # 파이프로 넘길 때
set -euo pipefail

CONTAINER=${MERIDIAN_CONTAINER:-meridian}
DB=${MERIDIAN_DB:-/home/claude/.config/meridian/telemetry.db}

FORMAT=table
if [ "${1:-}" = "--json" ]; then FORMAT=json; shift; fi

if [ $# -gt 0 ]; then SQL=$1; else SQL=$(cat); fi

SQL="$SQL" FORMAT="$FORMAT" DB="$DB" \
docker exec -i -e SQL -e FORMAT -e DB "$CONTAINER" node --no-warnings -e '
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.env.DB, { readOnly: true });
const rows = db.prepare(process.env.SQL).all();

if (process.env.FORMAT === "json") {
  console.log(JSON.stringify(rows.map((r) => ({ ...r })), null, 2));
} else if (rows.length === 0) {
  console.log("(0 rows)");
} else {
  const cols = Object.keys(rows[0]);
  const fmt = (v, col) => {
    if (v === null || v === undefined) return "";
    if (typeof v === "number") {
      // 토큰 및 캐시 바이트/토큰 컬럼은 k / M / B 단위로 축약
      const isTokenCol = /token|cache_read|cache_write/i.test(col || "") && !/pct|rate/i.test(col || "");
      if (isTokenCol) {
        const abs = Math.abs(v);
        if (abs >= 1e9) {
          const s = (v / 1e9).toFixed(2);
          return (s.endsWith(".00") ? s.slice(0, -3) : s.endsWith("0") ? s.slice(0, -1) : s) + "B";
        }
        if (abs >= 1e6) {
          const s = (v / 1e6).toFixed(2);
          return (s.endsWith(".00") ? s.slice(0, -3) : s.endsWith("0") ? s.slice(0, -1) : s) + "M";
        }
        if (abs >= 1e3) {
          const s = (v / 1e3).toFixed(1);
          return (s.endsWith(".0") ? s.slice(0, -2) : s) + "k";
        }
        return String(v);
      }
      if (Number.isInteger(v)) return String(v);
      // 소수점은 기본 1자리로 표시하되(백분율 등), 정밀도가 필요한 경우 최대 2자리까지
      const s = (Math.round(v * 100) / 100).toFixed(2);
      return s.endsWith(".00") ? s.slice(0, -3) : s.endsWith("0") ? s.slice(0, -1) : s;
    }
    return String(v);
  };
  // 한글/CJK는 터미널에서 두 칸을 차지하므로 폭 계산에 반영한다.
  const width = (s) => [...s].reduce((n, ch) => n + (/[\u1100-\u115F\u2E80-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE30-\uFE6F\uFF00-\uFF60\uFFE0-\uFFE6]/.test(ch) ? 2 : 1), 0);
  const pad = (s, n) => s + " ".repeat(Math.max(0, n - width(s)));
  const w = cols.map((c) => Math.max(width(c), ...rows.map((r) => width(fmt(r[c], c)))));
  const line = (cells) => cells.map((s, i) => pad(s, w[i])).join("  ").trimEnd();
  console.log(line(cols));
  console.log(w.map((n) => "-".repeat(n)).join("  "));
  for (const r of rows) console.log(line(cols.map((c) => fmt(r[c], c))));
  console.log(`\n(${rows.length} rows)`);
}
'
