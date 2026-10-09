FROM calciumion/new-api:latest

USER root

# 基础工具：curl 传备份，sqlite3 做安全快照
RUN apt-get update && apt-get install -y curl ca-certificates sqlite3 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /data && chmod 777 /data

# --- 环境变量配置区 ---
# BATCH_UPDATE_ENABLED=true：用户额度/用量改为批量写库，并发时不再每个请求同步打 SQLite。
#   这是"调用不丝滑"在应用层最大的优化点；BATCH_UPDATE_INTERVAL=5 为批量间隔（秒）。
# BACKUP_INTERVAL_SECONDS：备份间隔（秒），默认 4 小时。原脚本 sleep 144000 = 40 小时，疑似笔误。
# RESET_CHANNELS_ON_BOOT：默认 false。设为 true 才恢复旧行为（全渠道强制复活，含已确认死亡的渠道）。
# LOG_RETENTION_DAYS：日志保留天数，空 = 不清理。设为 30 即每天删除 30 天前的 logs 记录，阻止 DB 无限增长。
#   注意：new-api 的用量统计读 logs 表，删掉后后台就看不到更早的历史曲线了；按需开启。
# REDIS_CONN_STRING：可选。接 Render Key Value / Upstash Redis 后，限流与缓存走 Redis，进一步给 SQLite 减负。
# CPU_USAGE_THRESHOLD：保持不设置（沿用 new-api 默认），按你原来的要求不动它。
ENV SQL_DSN="" \
    GLOBAL_API_RATE_LIMIT=10000 \
    GLOBAL_WEB_RATE_LIMIT=10000 \
    BATCH_UPDATE_ENABLED=true \
    BATCH_UPDATE_INTERVAL=5 \
    LOG_LEVEL=warn \
    DATA_DIR="/data" \
    BACKUP_INTERVAL_SECONDS=14400 \
    RESET_CHANNELS_ON_BOOT=false \
    LOG_RETENTION_DAYS="30"
    # REDIS_CONN_STRING=""

# --- 启动脚本（heredoc 写法，避免 printf 转义地狱） ---
RUN cat > /entrypoint.sh <<'EOS' && chmod +x /entrypoint.sh
#!/bin/bash
DB_PATH="/data/one-api.db"
BACKUP_INTERVAL="${BACKUP_INTERVAL_SECONDS:-14400}"

# 1. 启动前从 Supabase 拉取最新备份
if [ -n "${SUPABASE_URL:-}" ]; then
    echo "Checking for cloud backup from Supabase..."
    if curl -fsSL --retry 3 --max-time 600 \
        "${SUPABASE_URL}/storage/v1/object/authenticated/${BUCKET_NAME}/one-api.db" \
        -H "Authorization: Bearer ${SUPABASE_KEY}" \
        -o "/tmp/one-api.db"; then
        FILE_SIZE=$(stat -c%s "/tmp/one-api.db" 2>/dev/null || echo 0)
        # 只有大于 100 字节且含 SQLite 头才恢复
        if [ "$FILE_SIZE" -gt 100 ] && head -c 100 "/tmp/one-api.db" | grep -q "SQLite format 3"; then
            # 先删旧的 WAL 附属文件，避免新 db 配旧 -wal/-shm 导致损坏
            rm -f "${DB_PATH}-wal" "${DB_PATH}-shm"
            cp "/tmp/one-api.db" "$DB_PATH"
            echo "Executing database optimization and state reset..."
            sqlite3 "$DB_PATH" "PRAGMA journal_mode=WAL;"
# 增加这一行，把查询结果打印到 Render 日志中
echo "Current SQLite journal_mode is: $(sqlite3 "$DB_PATH" "PRAGMA journal_mode;")"
            if [ "${RESET_CHANNELS_ON_BOOT}" = "true" ]; then
                # 旧行为：强制全渠道复活（含已确认死亡的渠道，慎用）
                sqlite3 "$DB_PATH" "UPDATE channels SET status = 1, response_time = 0, failure_count = 0;"
                echo "All channels force-enabled."
            else
                # 默认：只清零失败计数与响应时间；已被自动禁用的坏渠道保持禁用，
                # 避免每次重启后请求随机撞到死渠道，造成偶发失败/超时
                sqlite3 "$DB_PATH" "UPDATE channels SET response_time = 0, failure_count = 0;"
                echo "Channel counters reset; auto-disabled channels stay disabled."
            fi
            chmod 777 "$DB_PATH"
            echo "Cloud backup restored successfully ($FILE_SIZE bytes), WAL enabled."
        else
            echo "No valid backup found (file empty or wrong format). Using local/new database."
        fi
    else
        echo "Backup download failed. Using local/new database."
    fi
    rm -f "/tmp/one-api.db"
fi

# 1b. 日志清理（可选）：LOG_RETENTION_DAYS 为空则跳过
prune_logs() {
    [ -n "${LOG_RETENTION_DAYS:-}" ] || return 0
    case "$LOG_RETENTION_DAYS" in
        ''|*[!0-9]*) echo "Invalid LOG_RETENTION_DAYS='$LOG_RETENTION_DAYS', skip pruning."; return 0;;
    esac
    [ "$LOG_RETENTION_DAYS" -gt 0 ] || return 0
    # 全新库（主程序还没建表）则跳过
    if [ "$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='logs';")" = "0" ]; then
        return 0
    fi
    # 分批删除，每批 2 万行，避免长时间占写锁影响在线请求
    TOTAL=0
    while :; do
        N=$(sqlite3 "$DB_PATH" "DELETE FROM logs WHERE created_at > 0 AND created_at < strftime('%s','now','-${LOG_RETENTION_DAYS} days') LIMIT 20000; SELECT changes();" 2>/dev/null)
        case "$N" in ''|*[!0-9]*) N=0;; esac
        TOTAL=$((TOTAL + N))
        [ "$N" -gt 0 ] || break
        sleep 1
    done
    echo "Pruned $TOTAL log rows older than ${LOG_RETENTION_DAYS} days at $(date)"
}

# 启动时先清一次：此时主程序还没启动，可顺手 VACUUM 把文件真正收缩
if [ -f "$DB_PATH" ] && [ -n "${LOG_RETENTION_DAYS:-}" ]; then
    prune_logs
    echo "Running VACUUM to reclaim space..."
    sqlite3 "$DB_PATH" "VACUUM;" 2>/dev/null || echo "VACUUM skipped (non-fatal)."
fi

# 2. 备份函数：sqlite3 .backup 避免主程序写锁冲突
do_backup() {
    if [ ! -f "$DB_PATH" ]; then return; fi
    echo "Starting safe backup to Supabase..."
    if sqlite3 "$DB_PATH" ".backup '/tmp/one-api.bak'" && \
       nice -n 19 curl -fsSL --retry 2 --max-time 600 -X POST \
         "${SUPABASE_URL}/storage/v1/object/${BUCKET_NAME}/one-api.db" \
         -H "Authorization: Bearer ${SUPABASE_KEY}" \
         -H "Content-Type: application/x-sqlite3" \
         -H "x-upsert: true" \
         --data-binary "@/tmp/one-api.bak"; then
        echo "Backup finished at $(date)"
    else
        echo "Backup failed at $(date)"
    fi
    rm -f /tmp/one-api.bak
}

# 3. 后台备份守护进程：先睡后备，避免启动瞬间把刚恢复的库又原样传回去
if [ -n "${SUPABASE_URL:-}" ]; then
(
    while true; do
        sleep "$BACKUP_INTERVAL"
        do_backup
    done
) &
fi

# 3b. 日志清理守护进程：每天清一次（只删行，腾出的空间由 SQLite 复用，文件不再增长）
if [ -n "${LOG_RETENTION_DAYS:-}" ]; then
(
    while true; do
        sleep 86400
        prune_logs
    done
) &
fi

# 4. 运行主程序
echo "Starting New API..."
exec /new-api --port 3000 --log-dir /data/logs
EOS

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
