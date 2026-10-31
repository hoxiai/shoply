#!/usr/bin/env bash
set -e

# ========================================================
# Shopark 智能运维与运行管理工具 (支持 Docker / Podman)
# ========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# 1. 自动检测容器编排命令
detect_compose() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v podman-compose >/dev/null 2>&1; then
        echo "podman-compose"
    elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
        echo "podman compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo ""
    fi
}

COMPOSE_CMD=$(detect_compose)
if [ -z "$COMPOSE_CMD" ]; then
    echo "[Shopark] 错误: 未检测到 docker compose 或 podman compose，请先安装 Docker 或 Podman 环境。" >&2
    exit 1
fi

# 2. 端口检测辅助函数
check_port() {
    local host="$1"
    local port="$2"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 2 "$host" "$port" >/dev/null 2>&1
    else
        (echo > "/dev/tcp/$host/$port") >/dev/null 2>&1
    fi
}

# 3. 随机字符串生成工具
generate_secret() {
    local length="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$((length / 2))"
    else
        LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$length" || echo "shopark_rand_key_$(date +%s)"
    fi
}

# 3.1 验证 MySQL 数据库连接与权限 (建库、建表、读写权限)
verify_mysql_connection() {
    local host="$1"
    local port="$2"
    local db="$3"
    local user="$4"
    local pass="$5"

    local probe_host="$host"
    if [ "$probe_host" = "host.docker.internal" ] || [ "$probe_host" = "localhost" ]; then
        probe_host="127.0.0.1"
    fi

    # 1. 端口检查
    if ! check_port "$probe_host" "$port"; then
        echo "无法连接至 MySQL 端口 ($probe_host:$port)，服务未运行或网络不可达。"
        return 1
    fi

    # 2. 优先使用 PHP PDO 测试 (精准捕获错误与 DDL/DML 权限)
    if command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi "pdo_mysql"; then
        local php_code='
        $host = $argv[1];
        $port = $argv[2];
        $db   = $argv[3];
        $user = $argv[4];
        $pass = $argv[5];
        try {
            $dsn = "mysql:host={$host};port={$port};charset=utf8mb4";
            $pdo = new PDO($dsn, $user, $pass, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_TIMEOUT => 4
            ]);
            try {
                $pdo->exec("CREATE DATABASE IF NOT EXISTS `{$db}` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
            } catch (Exception $e) {
                try {
                    $pdo->exec("USE `{$db}`");
                } catch (Exception $e2) {
                    echo "目标数据库 [{$db}] 不存在，且当前账号无建库权限: " . $e->getMessage() . "\n";
                    exit(2);
                }
            }
            $pdo->exec("USE `{$db}`");
            $test_table = "__shopark_chk_" . time() . "__";
            $pdo->exec("CREATE TABLE IF NOT EXISTS `{$test_table}` (id INT PRIMARY KEY)");
            $pdo->exec("INSERT INTO `{$test_table}` VALUES (1)");
            $stmt = $pdo->query("SELECT id FROM `{$test_table}` WHERE id=1");
            $stmt->fetch();
            $pdo->exec("DROP TABLE IF EXISTS `{$test_table}`");
            echo "OK\n";
            exit(0);
        } catch (PDOException $e) {
            echo "MySQL 连接或权限异常: " . $e->getMessage() . "\n";
            exit(1);
        }
        '
        local php_res
        php_res=$(php -r "$php_code" "$probe_host" "$port" "$db" "$user" "$pass" 2>&1 || true)
        if [ "$php_res" = "OK" ]; then
            return 0
        else
            echo "$php_res"
            return 1
        fi
    fi

    # 3. 备选方案：mysql 客户端
    if command -v mysql >/dev/null 2>&1; then
        local sql_check="CREATE DATABASE IF NOT EXISTS \`$db\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; USE \`$db\`; CREATE TABLE IF NOT EXISTS __shopark_chk__ (id INT PRIMARY KEY); INSERT INTO __shopark_chk__ VALUES (1); SELECT id FROM __shopark_chk__ WHERE id=1; DROP TABLE IF EXISTS __shopark_chk__;"
        local mysql_err
        if mysql_err=$(MYSQL_PWD="$pass" mysql -h "$probe_host" -P "$port" -u "$user" -e "$sql_check" 2>&1); then
            return 0
        else
            echo "$mysql_err"
            return 1
        fi
    fi

    # 4. 备选方案：容器引擎 (docker / podman)
    local engine=""
    if command -v docker >/dev/null 2>&1; then
        engine="docker"
    elif command -v podman >/dev/null 2>&1; then
        engine="podman"
    fi
    if [ -n "$engine" ]; then
        if $engine image inspect mysql:8.0 >/dev/null 2>&1; then
            local sql_check="CREATE DATABASE IF NOT EXISTS \`$db\`; USE \`$db\`; CREATE TABLE IF NOT EXISTS __shopark_chk__ (id INT); DROP TABLE __shopark_chk__;"
            local container_err
            if container_err=$($engine run --rm --net=host -e MYSQL_PWD="$pass" mysql:8.0 mysql -h "$probe_host" -P "$port" -u "$user" -e "$sql_check" 2>&1); then
                return 0
            else
                echo "$container_err"
                return 1
            fi
        fi
    fi

    return 0
}

# 3.2 验证 Redis 连接与权限 (网络、认证、读写权限)
verify_redis_connection() {
    local addr="$1"
    local pass="$2"

    local redis_host=$(echo "$addr" | cut -d: -f1)
    local redis_port=$(echo "$addr" | cut -d: -f2)
    redis_port="${redis_port:-6379}"

    local probe_host="$redis_host"
    if [ "$probe_host" = "host.docker.internal" ] || [ "$probe_host" = "localhost" ]; then
        probe_host="127.0.0.1"
    fi

    # 1. 端口检查
    if ! check_port "$probe_host" "$redis_port"; then
        echo "无法连接至 Redis 端口 ($probe_host:$redis_port)，服务未运行或无法建立 TCP 连接。"
        return 1
    fi

    # 2. 优先 PHP socket 测试
    if command -v php >/dev/null 2>&1; then
        local php_code='
        $host = $argv[1];
        $port = (int)$argv[2];
        $pass = $argv[3] ?? "";
        $fp = @fsockopen($host, $port, $errno, $errstr, 3);
        if (!$fp) {
            echo "无法建立 Redis TCP 连接: {$errstr} ({$errno})\n";
            exit(1);
        }
        if ($pass !== "") {
            fwrite($fp, "*2\r\n\$4\r\nAUTH\r\n\$" . strlen($pass) . "\r\n{$pass}\r\n");
            $resp = fgets($fp);
            if (strpos($resp, "+OK") !== 0) {
                echo "Redis 密码认证失败: " . trim($resp) . "\n";
                fclose($fp);
                exit(2);
            }
        }
        fwrite($fp, "*1\r\n\$4\r\nPING\r\n");
        $resp = fgets($fp);
        if (strpos($resp, "-NOAUTH") === 0) {
            echo "Redis 启用了密码认证，需要提供访问密码 (-NOAUTH)\n";
            fclose($fp);
            exit(3);
        }
        if (strpos($resp, "+PONG") !== 0) {
            echo "Redis PING 异常: " . trim($resp) . "\n";
            fclose($fp);
            exit(4);
        }
        $test_key = "__shopark_chk_" . time() . "__";
        fwrite($fp, "*3\r\n\$3\r\nSET\r\n\$" . strlen($test_key) . "\r\n{$test_key}\r\n\$1\r\n1\r\n");
        $resp = fgets($fp);
        if (strpos($resp, "+OK") !== 0) {
            echo "Redis 写入权限受限 (只读模式或无写入权限): " . trim($resp) . "\n";
            fclose($fp);
            exit(5);
        }
        fwrite($fp, "*2\r\n\$3\r\nDEL\r\n\$" . strlen($test_key) . "\r\n{$test_key}\r\n");
        fgets($fp);
        fclose($fp);
        echo "OK\n";
        exit(0);
        '
        local php_res
        php_res=$(php -r "$php_code" "$probe_host" "$redis_port" "$pass" 2>&1 || true)
        if [ "$php_res" = "OK" ]; then
            return 0
        else
            echo "$php_res"
            return 1
        fi
    fi

    # 3. 备选方案：使用 redis-cli
    if command -v redis-cli >/dev/null 2>&1; then
        local cli_args=(-h "$probe_host" -p "$redis_port")
        if [ -n "$pass" ]; then
            cli_args+=(-a "$pass")
        fi
        local ping_res
        if ! ping_res=$(redis-cli "${cli_args[@]}" ping 2>&1); then
            echo "Redis 连接/认证失败: $ping_res"
            return 1
        fi
        if [ "$ping_res" != "PONG" ]; then
            echo "Redis 响应异常: $ping_res"
            return 1
        fi
        local set_res
        set_res=$(redis-cli "${cli_args[@]}" set __shopark_chk__ 1 2>&1 || true)
        redis-cli "${cli_args[@]}" del __shopark_chk__ >/dev/null 2>&1 || true
        if [ "$set_res" != "OK" ]; then
            echo "Redis 写入权限不足: $set_res"
            return 1
        fi
        return 0
    fi

    # 4. 备选方案：使用 nc
    if command -v nc >/dev/null 2>&1; then
        local cmd_buf=""
        if [ -n "$pass" ]; then
            cmd_buf="AUTH $pass\r\n"
        fi
        cmd_buf="${cmd_buf}PING\r\nSET __shopark_chk__ 1\r\nDEL __shopark_chk__\r\nQUIT\r\n"
        local nc_resp
        nc_resp=$(printf "%b" "$cmd_buf" | nc -w 3 "$probe_host" "$redis_port" 2>/dev/null || true)
        if echo "$nc_resp" | grep -qi -- "-NOAUTH"; then
            echo "Redis 启用了密码保护，需要提供访问密码 (-NOAUTH)"
            return 1
        elif echo "$nc_resp" | grep -qi -- "-WRONGPASS\|-ERR invalid password"; then
            echo "Redis 密码错误: $(echo "$nc_resp" | grep -i -- "-WRONGPASS\|-ERR" | head -n 1)"
            return 1
        elif echo "$nc_resp" | grep -qi -- "+PONG"; then
            return 0
        fi
    fi

    return 0
}

# 4. 智能环境向导配置
interactive_setup() {
    echo "========================================================"
    echo "       Shopark 部署配置智能向导"
    echo "========================================================"
    echo ""

    local use_embedded_mysql="true"
    local db_host="mysql"
    local db_port="3306"
    local db_name="shopark"
    local db_user="shopark"
    local db_pass=""
    local mysql_root_pass=""

    local use_embedded_redis="true"
    local redis_addr="redis:6379"
    local redis_pass=""

    local is_interactive=false
    if [ -t 0 ]; then
        is_interactive=true
    fi

    # ------------------ MySQL 检测与验证 ------------------
    local has_local_mysql=false
    if check_port 127.0.0.1 3306; then
        has_local_mysql=true
    fi

    if [ "$has_local_mysql" = true ]; then
        echo "[Shopark] 🔍 检测到宿主机 3306 端口已有运行中的 MySQL 服务。"
        local choice_mysql="Y"
        if [ "$is_interactive" = true ]; then
            read -r -p "是否直接使用宿主机现有的 MySQL 数据库？ [Y/n]: " input_choice_mysql
            choice_mysql=${input_choice_mysql:-Y}
        fi

        if [[ "$choice_mysql" =~ ^[Yy]$ ]]; then
            use_embedded_mysql="false"
            db_host="host.docker.internal"
            while true; do
                if [ "$is_interactive" = true ]; then
                    read -r -p "请输入 MySQL 数据库名称 [默认: shopark]: " input_db
                    db_name=${input_db:-shopark}
                    read -r -p "请输入 MySQL 用户名 [默认: root]: " input_user
                    db_user=${input_user:-root}
                    read -r -p "请输入 MySQL 密码 [留空表示无密码]: " input_pass
                    db_pass=$input_pass
                else
                    db_pass="root"
                fi

                echo "[Shopark] 正在验证 MySQL 连接及读写/建库权限..."
                local mysql_err=""
                if mysql_err=$(verify_mysql_connection "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass"); then
                    echo "[Shopark] ✔️ MySQL 连接与权限验证通过！(目标数据库: ${db_name})"
                    echo "[Shopark] ✔️ 将连接宿主机 MySQL (${db_host}:${db_port}/${db_name})，跳过启动 MySQL 容器。"
                    break
                else
                    echo "[Shopark] ❌ MySQL 验证失败: $mysql_err"
                    if [ "$is_interactive" = true ]; then
                        read -r -p "是否重新输入 MySQL 信息？ [Y/n] (输入 n 则放弃连接，改为在容器中独立启动 MySQL): " retry_mysql
                        retry_mysql=${retry_mysql:-Y}
                        if [[ ! "$retry_mysql" =~ ^[Yy]$ ]]; then
                            echo "[Shopark] ℹ️ 已切换为在容器中独立启动 MySQL 8.0。"
                            use_embedded_mysql="true"
                            db_host="mysql"
                            db_port="3306"
                            read -r -p "请设置容器 MySQL 数据库密码 [留空自动生成随机强密码]: " input_db_pass
                            if [ -n "$input_db_pass" ]; then
                                db_pass="$input_db_pass"
                                mysql_root_pass="$input_db_pass"
                            else
                                db_pass=$(generate_secret 16)
                                mysql_root_pass=$(generate_secret 20)
                            fi
                            break
                        fi
                    else
                        echo "[Shopark] 警告: 非交互模式下 MySQL 验证未通过，将切换为容器内独立启动 MySQL。"
                        use_embedded_mysql="true"
                        db_host="mysql"
                        db_port="3306"
                        db_pass=$(generate_secret 16)
                        mysql_root_pass=$(generate_secret 20)
                        break
                    fi
                fi
            done
        else
            echo "[Shopark] ✔️ 将在容器中独立启动 MySQL 8.0。"
            if [ "$is_interactive" = true ]; then
                read -r -p "请设置容器 MySQL 数据库密码 [留空自动生成随机强密码]: " input_db_pass
                if [ -n "$input_db_pass" ]; then
                    db_pass="$input_db_pass"
                    mysql_root_pass="$input_db_pass"
                else
                    db_pass=$(generate_secret 16)
                    mysql_root_pass=$(generate_secret 20)
                fi
            else
                db_pass=$(generate_secret 16)
                mysql_root_pass=$(generate_secret 20)
            fi
        fi
    else
        echo "[Shopark] ℹ️ 未检测到宿主机 3306 端口。"
        local choice_ext_mysql="n"
        if [ "$is_interactive" = true ]; then
            read -r -p "是否连接外部已有的 MySQL 数据库 (例如云 RDS / 远程主机)？ [y/N]: " input_ext_mysql
            choice_ext_mysql=${input_ext_mysql:-n}
        fi

        if [[ "$choice_ext_mysql" =~ ^[Yy]$ ]]; then
            use_embedded_mysql="false"
            while true; do
                read -r -p "请输入外部 MySQL 主机地址/IP: " input_host
                db_host=${input_host:-127.0.0.1}
                read -r -p "请输入 MySQL 端口 [默认: 3306]: " input_port
                db_port=${input_port:-3306}
                read -r -p "请输入 MySQL 数据库名称 [默认: shopark]: " input_db
                db_name=${input_db:-shopark}
                read -r -p "请输入 MySQL 用户名 [默认: root]: " input_user
                db_user=${input_user:-root}
                read -r -p "请输入 MySQL 密码 [留空表示无密码]: " input_pass
                db_pass=$input_pass

                echo "[shopark] 正在验证外部 MySQL 连接及读写权限..."
                local mysql_err=""
                if mysql_err=$(verify_mysql_connection "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass"); then
                    echo "[Shopark] ✔️ 外部 MySQL 数据库连接与权限验证通过！(目标数据库: ${db_name})"
                    break
                else
                    echo "[Shopark] ❌ MySQL 验证失败: $mysql_err"
                    read -r -p "是否重新输入 MySQL 信息？ [Y/n] (输入 n 则切换为容器内启动 MySQL): " retry_choice
                    retry_choice=${retry_choice:-Y}
                    if [[ ! "$retry_choice" =~ ^[Yy]$ ]]; then
                        echo "[Shopark] ℹ️ 已切换为在容器中独立启动 MySQL 8.0。"
                        use_embedded_mysql="true"
                        db_host="mysql"
                        db_port="3306"
                        read -r -p "请设置容器 MySQL 数据库密码 [留空自动生成随机强密码]: " input_db_pass
                        if [ -n "$input_db_pass" ]; then
                            db_pass="$input_db_pass"
                            mysql_root_pass="$input_db_pass"
                        else
                            db_pass=$(generate_secret 16)
                            mysql_root_pass=$(generate_secret 20)
                        fi
                        break
                    fi
                fi
            done
        else
            echo "[Shopark] ✔️ 将在容器中自动启动 MySQL 8.0。"
            if [ "$is_interactive" = true ]; then
                read -r -p "请设置容器 MySQL 数据库密码 [留空自动生成随机强密码]: " input_db_pass
                if [ -n "$input_db_pass" ]; then
                    db_pass="$input_db_pass"
                    mysql_root_pass="$input_db_pass"
                else
                    db_pass=$(generate_secret 16)
                    mysql_root_pass=$(generate_secret 20)
                fi
            else
                db_pass=$(generate_secret 16)
                mysql_root_pass=$(generate_secret 20)
            fi
        fi
    fi
    echo ""

    # ------------------ Redis 检测与验证 ------------------
    local has_local_redis=false
    if check_port 127.0.0.1 6379; then
        has_local_redis=true
    fi

    if [ "$has_local_redis" = true ]; then
        echo "[Shopark] 🔍 检测到宿主机 6379 端口已有运行中的 Redis 服务。"
        local choice_redis="Y"
        if [ "$is_interactive" = true ]; then
            read -r -p "是否直接使用宿主机现有的 Redis 缓存？ [Y/n]: " input_choice_redis
            choice_redis=${input_choice_redis:-Y}
        fi

        if [[ "$choice_redis" =~ ^[Yy]$ ]]; then
            use_embedded_redis="false"
            redis_addr="host.docker.internal:6379"
            while true; do
                if [ "$is_interactive" = true ]; then
                    read -r -p "请输入 Redis 访问密码 [若无密码直接回车]: " input_redis_pass
                    redis_pass=$input_redis_pass
                fi

                echo "[Shopark] 正在验证 Redis 连接、认证及读写权限..."
                local redis_err=""
                if redis_err=$(verify_redis_connection "$redis_addr" "$redis_pass"); then
                    echo "[Shopark] ✔️ Redis 连接、认证及读写权限验证通过！"
                    echo "[Shopark] ✔️ 将连接宿主机 Redis (${redis_addr})，跳过启动 Redis 容器。"
                    break
                else
                    echo "[Shopark] ❌ Redis 验证失败: $redis_err"
                    if [ "$is_interactive" = true ]; then
                        read -r -p "是否重新输入 Redis 密码？ [Y/n] (输入 n 则放弃连接，改为在容器中独立启动 Redis): " retry_redis
                        retry_redis=${retry_redis:-Y}
                        if [[ ! "$retry_redis" =~ ^[Yy]$ ]]; then
                            echo "[Shopark] ℹ️ 已切换为在容器中独立启动 Redis 7。"
                            use_embedded_redis="true"
                            redis_addr="redis:6379"
                            read -r -p "请设置容器 Redis 密码 [留空自动生成随机密码]: " input_redis_pass
                            if [ -n "$input_redis_pass" ]; then
                                redis_pass="$input_redis_pass"
                            else
                                redis_pass=$(generate_secret 16)
                            fi
                            break
                        fi
                    else
                        echo "[Shopark] 警告: 非交互模式下 Redis 验证未通过，将切换为容器内独立启动 Redis。"
                        use_embedded_redis="true"
                        redis_addr="redis:6379"
                        redis_pass=$(generate_secret 16)
                        break
                    fi
                fi
            done
        else
            echo "[Shopark] ✔️ 将在容器中独立启动 Redis 7。"
            if [ "$is_interactive" = true ]; then
                read -r -p "请设置容器 Redis 密码 [留空自动生成随机密码]: " input_redis_pass
                if [ -n "$input_redis_pass" ]; then
                    redis_pass="$input_redis_pass"
                else
                    redis_pass=$(generate_secret 16)
                fi
            else
                redis_pass=$(generate_secret 16)
            fi
        fi
    else
        echo "[Shopark] ℹ️ 未检测到宿主机 6379 端口。"
        local choice_ext_redis="n"
        if [ "$is_interactive" = true ]; then
            read -r -p "是否连接外部已有的 Redis 缓存服务 (例如云 Redis / 远程服务)？ [y/N]: " input_ext_redis
            choice_ext_redis=${input_ext_redis:-n}
        fi

        if [[ "$choice_ext_redis" =~ ^[Yy]$ ]]; then
            use_embedded_redis="false"
            while true; do
                read -r -p "请输入外部 Redis 地址及端口 (例: 192.168.1.100:6379): " input_redis_addr
                redis_addr=${input_redis_addr:-127.0.0.1:6379}
                read -r -p "请输入 Redis 访问密码 [若无密码直接回车]: " input_redis_pass
                redis_pass=$input_redis_pass

                echo "[Shopark] 正在验证外部 Redis 连接、认证及读写权限..."
                local redis_err=""
                if redis_err=$(verify_redis_connection "$redis_addr" "$redis_pass"); then
                    echo "[Shopark] ✔️ 外部 Redis 连接与读写权限验证通过！"
                    break
                else
                    echo "[Shopark] ❌ Redis 验证失败: $redis_err"
                    read -r -p "是否重新输入 Redis 信息？ [Y/n] (输入 n 则切换为容器内启动 Redis): " retry_choice
                    retry_choice=${retry_choice:-Y}
                    if [[ ! "$retry_choice" =~ ^[Yy]$ ]]; then
                        echo "[Shopark] ℹ️ 已切换为在容器中独立启动 Redis 7。"
                        use_embedded_redis="true"
                        redis_addr="redis:6379"
                        read -r -p "请设置容器 Redis 密码 [留空自动生成随机密码]: " input_redis_pass
                        if [ -n "$input_redis_pass" ]; then
                            redis_pass="$input_redis_pass"
                        else
                            redis_pass=$(generate_secret 16)
                        fi
                        break
                    fi
                fi
            done
        else
            echo "[Shopark] ✔️ 将在容器中自动启动 Redis 7。"
            if [ "$is_interactive" = true ]; then
                read -r -p "请设置容器 Redis 密码 [留空自动生成随机密码]: " input_redis_pass
                if [ -n "$input_redis_pass" ]; then
                    redis_pass="$input_redis_pass"
                else
                    redis_pass=$(generate_secret 16)
                fi
            else
                redis_pass=$(generate_secret 16)
            fi
        fi
    fi
    echo ""

    # ------------------ 管理员账户与密钥 ------------------
    local admin_pwd
    admin_pwd=$(generate_secret 16)
    if [ "$is_interactive" = true ]; then
        while true; do
            read -r -p "请输入超级管理员登录密码 (登录邮箱: admin@shopark.ai) [至少8位]: " input_admin_pwd
            if [ -z "$input_admin_pwd" ]; then
                echo "[Shopark] 提示: 密码不能为空，请输入管理员密码。"
            elif [ ${#input_admin_pwd} -lt 8 ]; then
                echo "[Shopark] 提示: 密码长度至少需要8位，请重新输入。"
            else
                admin_pwd="$input_admin_pwd"
                break
            fi
        done
    fi

    local jwt_sign_key=$(generate_secret 24)
    local jwt_secret_key=$(generate_secret 32)

    # ------------------ 写入 .env 文件 ------------------
    cat <<EOF > .env
# ========================================================
# Shopark 运行环境配置文件 (.env) - 智能向导自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ========================================================

# 容器镜像配置
SHOPARK_IMAGE_REGISTRY=crpi-vvvid8bdlzbcxo4s.cn-shenzhen.personal.cr.aliyuncs.com
SHOPARK_IMAGE_NAME=hoxiai/shopark
SHOPARK_VERSION=latest
SHOPARK_HTTP_PORT=5490

# 架构与服务开关 (控制是否启动内置容器)
USE_EMBEDDED_MYSQL=${use_embedded_mysql}
USE_EMBEDDED_REDIS=${use_embedded_redis}

# 数据库配置
SHOPARK_DB_DRIVER=mysql
SHOPARK_DB_HOST=${db_host}
SHOPARK_DB_PORT=${db_port}
SHOPARK_DB_DATABASE=${db_name}
SHOPARK_DB_USERNAME=${db_user}
SHOPARK_DB_PASSWORD=${db_pass}
SHOPARK_MYSQL_ROOT_PASSWORD=${mysql_root_pass}

# 缓存配置
SHOPARK_REDIS_ADDR=${redis_addr}
SHOPARK_REDIS_PASSWORD=${redis_pass}
SHOPARK_REDIS_DB=0

# 站点与超级管理员
SHOPARK_STORE_NAME=Shopark Store
SHOPARK_SITE_URL=http://localhost:5490
SHOPARK_SITE_EMAIL=admin@shopark.ai
SHOPARK_SITE_PASSWORD=${admin_pwd}

# 安全密钥
SHOPARK_JWT_SIGN_KEY=${jwt_sign_key}
SHOPARK_JWT_SECRET_KEY=${jwt_secret_key}
SHOPARK_JWT_ADMIN_PERMISSION_MODE=enforce
EOF

    echo "========================================================"
    echo "  配置生成成功: .env"
    echo "  - 数据库: ${db_host}:${db_port} (${db_name})"
    echo "  - 缓  存: ${redis_addr}"
    echo "  - 管理员: admin@shopark.ai (初始密码: ${admin_pwd})"
    echo "========================================================"
    echo ""
}

# 5. 计算并获取 Profile 参数
get_profile_args() {
    local args=()
    if [ -f ".env" ]; then
        local db_driver=$(grep -E "^SHOPARK_DB_DRIVER=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' | tr '[:upper:]' '[:lower:]' || true)
        local db_host=$(grep -E "^SHOPARK_DB_HOST=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' || true)
        local use_mysql=$(grep -E "^USE_EMBEDDED_MYSQL=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' || true)
        local use_postgres=$(grep -E "^USE_EMBEDDED_POSTGRES=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' || true)
        local use_redis=$(grep -E "^USE_EMBEDDED_REDIS=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' || true)

        case "$db_driver" in
            pgsql|postgres|postgresql)
                if [ "$use_postgres" = "true" ] || { [ -z "$use_postgres" ] && [ "$db_host" = "postgres" ]; }; then
                    args+=(--profile postgres)
                fi
                ;;
            *)
                if [ "$use_mysql" = "true" ] || [ -z "$use_mysql" ]; then
                    args+=(--profile mysql)
                fi
                ;;
        esac
        if [ "$use_redis" = "true" ] || [ -z "$use_redis" ]; then
            args+=(--profile redis)
        fi
    else
        args+=(--profile mysql --profile redis)
    fi
    echo "${args[@]}"
}

# 6. 运行环境前置准备 (挂载目录与 Podman Rootless 权限)
ensure_runtime_env() {
    # 1. 预先以宿主机当前用户身份创建所有持久化挂载目录，杜绝 Docker(root)/Podman 卷权限冲突
    mkdir -p data config public/uploads runtime data/theme-releases plugins/app

    # 2. 若检测到以非 root 用户使用 Podman (Rootless)，检查并启用用户会话常驻 (Linger)
    if [[ "$COMPOSE_CMD" == *"podman"* ]] && [ "$(id -u)" -ne 0 ]; then
        if command -v loginctl >/dev/null 2>&1; then
            if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
                loginctl enable-linger "$USER" 2>/dev/null || echo "[Shopark] 提示: 建议执行 'loginctl enable-linger \$USER' 以确保 SSH 会话断开后 Podman 容器持续常驻后台。"
            fi
        fi
    fi
}

# 7. 打印访问入口信息
print_service_endpoints() {
    local http_port="5490"
    local admin_email="admin@shopark.ai"
    if [ -f ".env" ]; then
        local p
        p=$(grep -E "^SHOPARK_HTTP_PORT=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' || true)
        [ -n "$p" ] && http_port="$p"
        local e
        e=$(grep -E "^SHOPARK_SITE_EMAIL=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' || true)
        [ -n "$e" ] && admin_email="$e"
    fi
    echo "[Shopark] 前台入口: http://localhost:${http_port}"
    echo "[Shopark] 管理后台: http://localhost:${http_port}/admin/"
    echo "[Shopark] 登录账号: ${admin_email}"
}

# 8. 服务启动流程
start_service() {
    if [ ! -f ".env" ]; then
        interactive_setup
    fi

    ensure_runtime_env
    local profile_args
    profile_args=$(get_profile_args)
    echo "[Shopark] 正在启动服务 (使用: $COMPOSE_CMD $profile_args)..."
    $COMPOSE_CMD $profile_args up -d
    echo ""
    echo "[Shopark] 🚀 服务启动成功！"
    print_service_endpoints
}

# 9. 服务重启流程 (重载 .env 与服务配置)
restart_service() {
    if [ ! -f ".env" ]; then
        echo "[Shopark] 未检测到 .env 配置文件，正在启动向导..."
        interactive_setup
    fi

    ensure_runtime_env
    local profile_args
    profile_args=$(get_profile_args)
    echo "[Shopark] 正在安全重启服务 (重新加载 .env 配置与容器编排)..."

    # 先停用所有可能运行的容器 profile (包含内置 mysql/postgres/redis)，确保变更被彻底重置
    $COMPOSE_CMD --profile mysql --profile postgres --profile redis down 2>/dev/null || $COMPOSE_CMD down 2>/dev/null || true
    # 强制重建并拉起符合最新 .env 配置的服务
    $COMPOSE_CMD $profile_args up -d --force-recreate

    echo ""
    echo "[Shopark] 🚀 服务重启成功！"
    print_service_endpoints
}

# 10. 命令路由
case "$1" in
    init|config)
        interactive_setup
        if [ -t 0 ]; then
            read -r -p "配置已保存。是否立即重启/启动服务以使新配置生效？ [Y/n]: " input_restart
            input_restart=${input_restart:-Y}
            if [[ "$input_restart" =~ ^[Yy]$ ]]; then
                restart_service
            else
                echo "[Shopark] 提示: 您可以随时执行 './shopark.sh restart' 或 './shopark.sh start' 启动服务。"
            fi
        else
            echo "[Shopark] 提示: 配置已保存，执行 './shopark.sh restart' 即可使新配置生效。"
        fi
        ;;
    start|up)
        start_service
        ;;
    stop|down)
        PROFILE_ARGS=$(get_profile_args)
        echo "[Shopark] 正在停止服务..."
        $COMPOSE_CMD $PROFILE_ARGS down
        echo "[Shopark] 服务已停止。"
        ;;
    restart)
        restart_service
        ;;
    status|ps)
        PROFILE_ARGS=$(get_profile_args)
        $COMPOSE_CMD $PROFILE_ARGS ps
        ;;
    logs)
        PROFILE_ARGS=$(get_profile_args)
        shift
        $COMPOSE_CMD $PROFILE_ARGS logs -f "${@:-shopark}"
        ;;
    update|pull|upgrade)
        shift 2>/dev/null || true
        exec ./scripts/upgrade.sh "$@"
        ;;
    build)
        shift
        exec ./scripts/build-image.sh "$@"
        ;;
    help|*)
        echo "Shopark 容器管理工具"
        echo ""
        echo "用法: ./scripts/shopark.sh [命令]"
        echo ""
        echo "常用命令:"
        echo "  start     启动服务（若未初始化会自动启动智能检测与向导）"
        echo "  init      重新运行配置向导生成 .env 配置，并提示重启生效"
        echo "  stop      停止并移除当前容器"
        echo "  restart   安全重启所有服务（自动重载 .env 与服务配置）"
        echo "  status    查看各服务运行状态"
        echo "  logs      跟踪实时日志 (例: ./scripts/shopark.sh logs)"
        echo "  update    一键检查并在线平滑升级应用 (支持版本指定与自动回滚)"
        echo "  upgrade   同 update"
        echo "  build     构建本地 Docker / Podman 镜像 (例: ./scripts/shopark.sh build v1.0.0)"
        echo "  help      显示此帮助信息"
        echo ""
        ;;
esac
