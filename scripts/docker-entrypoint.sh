#!/usr/bin/env bash
set -e

# Explicit utility commands do not start or migrate the application.
case "$1" in
    prepare|doctor|--doctor|-d) set -- ./shopark "$@" ;;
esac

case "${1##*/}" in
    shopark|shopark-linux-*)
        doctor_requested=false
        utility_subcommand=false
        doctor_config_value=false
        prepare_config=./config/conf.yaml
        for doctor_arg in "${@:2}"; do
            if $doctor_config_value; then
                prepare_config="$doctor_arg"
                doctor_config_value=false
                continue
            fi
            case "$doctor_arg" in
                -c|--config) doctor_config_value=true ;;
                --config=*|-c=*) prepare_config="${doctor_arg#*=}" ;;
                -c?*) prepare_config="${doctor_arg#-c}" ;;
                --doctor|-d) doctor_requested=true ;;
                --doctor=*|-d=*)
                    case "${doctor_arg#*=}" in
                        1|t|T|true|TRUE|True) doctor_requested=true ;;
                        0|f|F|false|FALSE|False) doctor_requested=false ;;
                    esac
                    ;;
                prepare|doctor) utility_subcommand=true ;;
            esac
        done
        if $doctor_requested || $utility_subcommand; then
            exec "$@"
        fi
        ;;
    *) exec "$@" ;;
esac

# 0. 初始化必要目录；plugins/app 与 themes 通常是宿主机挂载：
#    - 若 data/system-release/current 存在高于镜像版本的在线更新包，优先自愈恢复（保证容器重启或重建后不还原）
#    - 内置应用与官方主题缺失时释放，仅在镜像版本高于已安装版本时升级覆盖（保留在线热更的高版本与源码检出）。
mkdir -p public/uploads data config runtime plugins/app themes

version_gt() {
    local v1="${1#v}"
    local v2="${2#v}"
    v1="${v1#V}"
    v2="${v2#V}"
    v1="${v1%%+*}"
    v2="${v2%%+*}"
    [ -n "$v1" ] || return 1
    [ -n "$v2" ] || return 0
    [ "$v1" = "$v2" ] && return 1
    awk -v v1="$v1" -v v2="$v2" '
        function cmp_id(a, b,    pa, pb, na, nb) {
            if (a == b) return 0
            if (a ~ /^[0-9]+$/ && b ~ /^[0-9]+$/) {
                return ((a + 0) > (b + 0)) ? 1 : (((a + 0) < (b + 0)) ? -1 : 0)
            }
            if (a ~ /^[0-9]+$/) return -1
            if (b ~ /^[0-9]+$/) return 1
            if (match(a, /[0-9]+$/) && RSTART > 1) {
                pa = substr(a, 1, RSTART - 1)
                na = substr(a, RSTART) + 0
                if (match(b, /[0-9]+$/) && RSTART > 1) {
                    pb = substr(b, 1, RSTART - 1)
                    nb = substr(b, RSTART) + 0
                    if (pa == pb) {
                        return (na > nb) ? 1 : ((na < nb) ? -1 : 0)
                    }
                }
            }
            return (a > b) ? 1 : -1
        }
        BEGIN {
            idx1 = index(v1, "-")
            if (idx1 > 0) { m1 = substr(v1, 1, idx1 - 1); p1 = substr(v1, idx1 + 1) } else { m1 = v1; p1 = "" }
            idx2 = index(v2, "-")
            if (idx2 > 0) { m2 = substr(v2, 1, idx2 - 1); p2 = substr(v2, idx2 + 1) } else { m2 = v2; p2 = "" }

            n1 = split(m1, a1, ".")
            n2 = split(m2, a2, ".")
            maxm = (n1 > n2) ? n1 : n2
            for (i = 1; i <= maxm; i++) {
                x1 = (i <= n1) ? (a1[i] + 0) : 0
                x2 = (i <= n2) ? (a2[i] + 0) : 0
                if (x1 > x2) exit 0
                if (x1 < x2) exit 1
            }

            if (p1 == "" && p2 == "") exit 1
            if (p1 == "" && p2 != "") exit 0
            if (p1 != "" && p2 == "") exit 1

            np1 = split(p1, b1, /[.-]/)
            np2 = split(p2, b2, /[.-]/)
            minp = (np1 < np2) ? np1 : np2
            for (i = 1; i <= minp; i++) {
                c = cmp_id(b1[i], b2[i])
                if (c > 0) exit 0
                if (c < 0) exit 1
            }
            if (np1 > np2) exit 0
            exit 1
        }
    '
}

app_version() {
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/app.json" 2>/dev/null | head -n 1
}

theme_version() {
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/theme-package.json" 2>/dev/null | head -n 1
}

sync_apps_from_dir() {
    local src_apps_dir="$1"
    [ -d "$src_apps_dir" ] || return 0
    for src_app in "$src_apps_dir"/*/; do
        src_app="${src_app%/}"
        [ -d "$src_app" ] || continue
        local app_name="${src_app##*/}"
        local app_target="plugins/app/$app_name"
        local src_ver
        src_ver="$(app_version "$src_app")"
        if [ ! -d "$app_target" ]; then
            echo "[Shopark] Installing built-in application $app_name $src_ver"
            cp -r "$src_app" "$app_target"
        elif [ -n "$src_ver" ] && version_gt "$src_ver" "$(app_version "$app_target")"; then
            if [ -e "$app_target/.git" ]; then
                echo "[Shopark] WARNING: $app_target is a source checkout; keeping it instead of version $src_ver" >&2
                continue
            fi
            echo "[Shopark] Upgrading built-in application $app_name to version $src_ver"
            rm -rf "$app_target.next"
            cp -r "$src_app" "$app_target.next"
            rm -rf "$app_target"
            mv "$app_target.next" "$app_target"
        fi
    done
}

sync_themes_from_dir() {
    local src_themes_dir="$1"
    [ -d "$src_themes_dir" ] || return 0
    for src_theme in "$src_themes_dir"/*/; do
        src_theme="${src_theme%/}"
        [ -d "$src_theme" ] || continue
        local theme_name="${src_theme##*/}"
        local theme_target="themes/$theme_name"
        local src_theme_ver
        src_theme_ver="$(theme_version "$src_theme")"
        if [ ! -f "$theme_target/theme-package.json" ]; then
            echo "[Shopark] Installing built-in theme $theme_name $src_theme_ver"
            rm -rf "$theme_target.next"
            cp -r "$src_theme" "$theme_target.next"
            rm -rf "$theme_target"
            mv "$theme_target.next" "$theme_target"
        elif [ -n "$src_theme_ver" ] && version_gt "$src_theme_ver" "$(theme_version "$theme_target")"; then
            if [ -e "$theme_target/.git" ]; then
                echo "[Shopark] WARNING: $theme_target is a source checkout; keeping it instead of version $src_theme_ver" >&2
                continue
            fi
            echo "[Shopark] Upgrading built-in theme $theme_name to version $src_theme_ver"
            rm -rf "$theme_target.next"
            cp -r "$src_theme" "$theme_target.next"
            rm -rf "$theme_target"
            mv "$theme_target.next" "$theme_target"
        fi
    done
}

# 0.1 自愈恢复持久化在线系统更新 (data/system-release/current)
persisted_release_dir="data/system-release/current"
if [ -f "$persisted_release_dir/VERSION" ] && [ -f "$persisted_release_dir/shopark" ]; then
    persisted_sys_ver="$(tr -d '[:space:]' < "$persisted_release_dir/VERSION" 2>/dev/null || true)"
    image_sys_ver=""
    if [ -f "VERSION" ]; then
        image_sys_ver="$(tr -d '[:space:]' < "VERSION" 2>/dev/null || true)"
    fi
    if [ -n "$persisted_sys_ver" ] && version_gt "$persisted_sys_ver" "$image_sys_ver"; then
        echo "[Shopark] Restoring persisted online system update $persisted_sys_ver from $persisted_release_dir"
        cp "$persisted_release_dir/shopark" "./shopark.next"
        chmod 755 "./shopark.next"
        mv "./shopark.next" "./shopark"
        for sub in dist resource scripts \
            plugins/src plugins/common plugins/vendor plugins/composer.json plugins/composer.lock \
            plugins/shopark plugins/tcp-worker.php plugins/psr-worker.php \
            public/favicon.svg public/icon.svg public/logo.svg public/logo-inverse.svg; do
            if [ -d "$persisted_release_dir/$sub" ] || [ -f "$persisted_release_dir/$sub" ]; then
                mkdir -p "$(dirname "./$sub")"
                rm -rf "./$sub.next"
                cp -r "$persisted_release_dir/$sub" "./$sub.next"
                rm -rf "./$sub"
                mv "./$sub.next" "./$sub"
            fi
        done
        sync_apps_from_dir "$persisted_release_dir/plugins/app"
        sync_themes_from_dir "$persisted_release_dir/themes"
        # Commit the version last so an interrupted restore is retried at startup.
        cp "$persisted_release_dir/VERSION" "./VERSION"
    fi
fi

sync_apps_from_dir "/var/www/shopark/.builtin-plugins-app"
sync_themes_from_dir "/var/www/shopark/.builtin-themes"

# 等待 TCP 端口就绪工具函数
wait_for_port() {
    local host="$1"
    local port="$2"
    local name="$3"
    local max_retries=60
    local count=0

    echo "[Shopark] Waiting for $name at $host:$port to be ready..."
    while ! nc -z "$host" "$port" >/dev/null 2>&1 && ! (echo > "/dev/tcp/$host/$port") >/dev/null 2>&1; do
        sleep 1
        count=$((count + 1))
        if [ "$count" -ge "$max_retries" ]; then
            echo "[Shopark] ERROR: Timed out waiting for $name at $host:$port"
            exit 1
        fi
    done
    echo "[Shopark] $name is ready!"
}

# 1. 检查并等待外部数据库就绪
if [ -n "$SHOPARK_DB_HOST" ]; then
    DB_DRIVER_LOWER=$(printf '%s' "${SHOPARK_DB_DRIVER:-mysql}" | tr '[:upper:]' '[:lower:]')
    case "$DB_DRIVER_LOWER" in
        pgsql|postgres|postgresql) DEFAULT_DB_PORT=5432 ;;
        *) DEFAULT_DB_PORT=3306 ;;
    esac
    DB_PORT="${SHOPARK_DB_PORT:-$DEFAULT_DB_PORT}"
    wait_for_port "$SHOPARK_DB_HOST" "$DB_PORT" "Database"
fi

# 2. 检查并等待外部 Redis 就绪
if [ -n "$SHOPARK_REDIS_ADDR" ]; then
    REDIS_HOST=$(echo "$SHOPARK_REDIS_ADDR" | cut -d: -f1)
    REDIS_PORT=$(echo "$SHOPARK_REDIS_ADDR" | cut -d: -f2)
    REDIS_PORT="${REDIS_PORT:-6379}"
    if [ -n "$REDIS_HOST" ]; then
        wait_for_port "$REDIS_HOST" "$REDIS_PORT" "Redis"
    fi
fi

# 3. 配置和应用注册先准备好，PHP CLI 才能读取同一份配置与注册表。
"$1" prepare --config "$prepare_config"

# 4. 迁移失败不启动 HTTP；每次发布都检查应用模型，而非依赖临时根目录标记。
if [ ! -f "plugins/shopark" ] || ! command -v php >/dev/null 2>&1; then
    echo "[Shopark] ERROR: PHP CLI or plugins/shopark is missing" >&2
    exit 1
fi
echo "[Shopark] Syncing PHP plugin database tables..."
(cd plugins && php shopark db:sync)

echo "[Shopark] Starting application server..."
exec "$@"
