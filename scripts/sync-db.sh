#!/usr/bin/env bash
# Meridian 컨테이너 볼륨의 telemetry.db(WAL, SHM 포함)를
# 호스트의 data/ 디렉터리로 안전하게 복사하여 DataGrip 등 GUI 도구에서 열 수 있게 합니다.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$DIR/data"
mkdir -p "$TARGET_DIR"

CONTAINER=${MERIDIAN_CONTAINER:-meridian}

echo "==> Meridian 컨테이너($CONTAINER)로부터 telemetry DB 복사 중..."
docker cp "$CONTAINER":/home/claude/.config/meridian/telemetry.db "$TARGET_DIR/telemetry.db"

# WAL 모드 파일이 존재하면 함께 복사 (최신 커밋 내역 보존에 필수)
if docker exec "$CONTAINER" test -f /home/claude/.config/meridian/telemetry.db-wal; then
  docker cp "$CONTAINER":/home/claude/.config/meridian/telemetry.db-wal "$TARGET_DIR/telemetry.db-wal"
fi

if docker exec "$CONTAINER" test -f /home/claude/.config/meridian/telemetry.db-shm; then
  docker cp "$CONTAINER":/home/claude/.config/meridian/telemetry.db-shm "$TARGET_DIR/telemetry.db-shm"
fi

echo "==> 동기화 완료! DataGrip 연결 파일 경로:"
echo "    $TARGET_DIR/telemetry.db"
