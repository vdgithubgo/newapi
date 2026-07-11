FROM calciumion/new-api:latest

USER root

# 安装基础工具：curl 用于传输，sqlite3 用于安全快照备份
RUN apt-get update && apt-get install -y curl ca-certificates sqlite3 && rm -rf /var/lib/apt/lists/*

# 创建并授权数据目录
RUN mkdir -p /data && chmod 777 /data

# --- 环境变量配置区 ---
# 🚨 修复坑 1：CPU_USAGE_THRESHOLD 必须是系统的环境变量，不能随意调成 100
ENV SQL_DSN="" \
    GLOBAL_API_RATE_LIMIT=10000 \
    GLOBAL_WEB_RATE_LIMIT=10000 \
    BATCH_UPDATE_ENABLED=false \
    LOG_LEVEL=warn \
    DATA_DIR="/data"

# --- 启动脚本生成 ---
RUN printf '#!/bin/bash\n\
DB_PATH="/data/one-api.db"\n\
\n\
# 1. 启动前强制拉取最新备份并强制复原 CPU/渠道状态
if [ -n "$SUPABASE_URL" ]; then\n\
    echo "Checking for cloud backup from Supabase..."\n\
    curl -s -L -X GET "${SUPABASE_URL}/storage/v1/object/authenticated/${BUCKET_NAME}/one-api.db" \\\n\
         -H "Authorization: Bearer ${SUPABASE_KEY}" \\\n\
         -o "/tmp/one-api.db"\n\
    \n\
    if [ -f "/tmp/one-api.db" ]; then\n\
        FILE_SIZE=$(stat -c%%s "/tmp/one-api.db")\n\
        # 只有文件大于 100 字节且包含 SQLite 头才恢复\n\
        if [ "$FILE_SIZE" -gt 100 ] && head -c 100 "/tmp/one-api.db" | grep -q "SQLite format 3"; then\n\
            cp "/tmp/one-api.db" "$DB_PATH"\n\
            \n\
            echo "Executing database optimization and state reset..."\n\
            # 1) 开启 WAL 模式提高并发性能\n\
            sqlite3 "$DB_PATH" "PRAGMA journal_mode=WAL;"\n\
            \n\
            # 2) 💥 降维打击：只改确定存在的绝对核心字段，强制全渠道复活，清空失败计数器\n\
            sqlite3 "$DB_PATH" "UPDATE channels SET status = 1, response_time = 0, failure_count = 0;"\n\
            \n\
            chmod 777 "$DB_PATH"\n\
            echo "Cloud backup restored successfully ($FILE_SIZE bytes), WAL enabled, and ALL channel states reset to default."\n\
        else\n\
            echo "No valid backup found (file empty or wrong format). Using local/new database."\n\
        fi\n\
        rm -f "/tmp/one-api.db"\n\
    fi\n\
fi\n\
\n\
# 2. 定义备份函数\n\
do_backup() {\n\
    if [ ! -f "$DB_PATH" ]; then return; fi\n\
    echo "Starting safe backup to Supabase..."\n\
    # 使用 sqlite3 backup 命令避免主程序运行中锁定文件\n\
    sqlite3 "$DB_PATH" ".backup '"'/tmp/one-api.bak'"'" \n\
    nice -n 19 curl -s -X POST "${SUPABASE_URL}/storage/v1/object/${BUCKET_NAME}/one-api.db" \\\n\
         -H "Authorization: Bearer ${SUPABASE_KEY}" \\\n\
         -H "Content-Type: application/x-sqlite3" \\\n\
         -H "x-upsert: true" \\\n\
         --data-binary "@/tmp/one-api.bak"\n\
    rm -f /tmp/one-api.bak\n\
    echo "Backup finished at $(date)"\n\
}\n\
\n\
# 3. 后台同步守护进程\n\
( \n\
    while true; do\n\
        do_backup\n\
        sleep 144000\n\
    done \n\
) &\n\
\n\
# 4. 运行主程序\n\
echo "Starting New API..."\n\
exec /new-api --port 3000 --log-dir /data/logs\n' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
