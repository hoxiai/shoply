#!/usr/bin/env bash
set -e

# ========================================================
# Shopark 官方在线升级与自动回滚工具 (Upgrade & Rollback)
# 支持 Docker / Podman 容器模式 与 独立二进制模式
# ========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[Shopark]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[Shopark] ✔️${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[Shopark] ⚠️${NC} $1"
}

log_error() {
    echo -e "${RED}[Shopark] ❌ 错误:${NC} $1" >&2
}

# 锁机制，防止并发升级冲突
LOCK_FILE=".upgrade.lock"
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_error "检测到另一个升级进程正在运行 (PID: $pid)。请等待其完成或排查后重试。"
            exit 1
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

cleanup() {
    rm -f "$LOCK_FILE"
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# 参数默认值
TARGET_VERSION=""
MODE="auto" # auto | container | binary
CHECK_ONLY=false
BACKUP_ONLY=false
DO_ROLLBACK=false
AUTO_YES=false
SHOPARK_MIRROR=""
TEMP_DIR=""

show_help() {
    echo "========================================================"
    echo "       Shopark 官方在线更新工具 (scripts/upgrade.sh)"
    echo "========================================================"
    echo ""
    echo "用法:"
    echo "  bash scripts/upgrade.sh [选项] [版本号]"
    echo ""
    echo "常用选项:"
    echo "  -v, --version <VER>    指定升级到的目标版本 (如 v1.1.0 或 latest)"
    echo "  -c, --check            检查是否有新版本，不执行实际升级"
    echo "  -b, --backup           仅备份当前配置与关键数据到 backup/ 目录"
    echo "  -r, --rollback         回滚至上一次升级前的备份版本"
    echo "  -y, --yes              非交互模式，跳过确认提示直接执行"
    echo "  --mirror <gitcode|github> 指定网络镜像源 (国内优先 GitCode，海外优先 GitHub)"
    echo "  --mode <container|binary> 强制指定升级模式 (默认自动检测)"
    echo "  -h, --help             显示此帮助信息"
    echo ""
    echo "使用示例:"
    echo "  bash scripts/upgrade.sh                  # 检查并更新至最新版本"
    echo "  bash scripts/upgrade.sh v1.0.1           # 升级到指定的 v1.0.1 版本"
    echo "  bash scripts/upgrade.sh --check          # 仅检查是否有更新"
    echo "  bash scripts/upgrade.sh --rollback       # 升级失败时快速回滚"
    echo ""
}

# 1. 解析命令行参数
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--check)
            CHECK_ONLY=true
            shift
            ;;
        -b|--backup)
            BACKUP_ONLY=true
            shift
            ;;
        -r|--rollback)
            DO_ROLLBACK=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        -v|--version)
            TARGET_VERSION="$2"
            shift 2
            ;;
        --version=*)
            TARGET_VERSION="${1#*=}"
            shift
            ;;
        --mirror=*)
            SHOPARK_MIRROR="${1#*=}"
            shift
            ;;
        --gitcode|--cn)
            SHOPARK_MIRROR="gitcode"
            shift
            ;;
        --github|--intl)
            SHOPARK_MIRROR="github"
            shift
            ;;
        --mode=*)
            MODE="${1#*=}"
            shift
            ;;
        -*)
            log_error "未知选项: $1"
            show_help
            exit 1
            ;;
        *)
            if [ -z "$TARGET_VERSION" ]; then
                TARGET_VERSION="$1"
            fi
            shift
            ;;
    esac
done

# 2. 检测网络镜像源优先级 (国内优先官方 CDN / GitCode，海外优先 GitHub)
detect_mirror_priority() {
    if [ -n "$SHOPARK_MIRROR" ]; then
        case "$SHOPARK_MIRROR" in
            cdn)
                echo "cdn gitcode github"
                return
                ;;
            gitcode|cn|gitee)
                echo "gitcode cdn github"
                return
                ;;
            github|global|intl)
                echo "github cdn gitcode"
                return
                ;;
        esac
    fi

    local is_cn=0
    local tz=$(date +%z 2>/dev/null || echo "")
    if [[ "$tz" == "+0800" ]] || [[ "${LANG:-}" == *zh_* ]] || [[ "${LC_ALL:-}" == *zh_* ]]; then
        is_cn=1
    fi

    if [ "$is_cn" -eq 1 ]; then
        echo "cdn gitcode github"
    else
        echo "github cdn gitcode"
    fi
}

# 获取最新 Tag
resolve_latest_tag() {
    local source="$1"
    local api_url=""
    if [ "$source" = "cdn" ]; then
        api_url="https://cdn.hoxi.dev/shopark/container/releases.json"
    elif [ "$source" = "gitcode" ]; then
        api_url="https://api.gitcode.com/api/v5/repos/hoxiai/shopark/releases/latest"
    elif [ "$source" = "github" ]; then
        api_url="https://api.github.com/repos/hoxiai/shopark/releases/latest"
    fi

    local resp=""
    if command -v curl >/dev/null 2>&1; then
        resp=$(curl -s -m 6 "$api_url" 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        resp=$(wget -q -T 6 -O - "$api_url" 2>/dev/null || true)
    fi

    echo "$resp" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/'
}

# 3. 容器编排命令检测
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

# 4. 判断运行模式
COMPOSE_CMD=$(detect_compose)
if [ "$MODE" = "auto" ]; then
    if [ -n "$COMPOSE_CMD" ] && [ -f "docker-compose.yml" ]; then
        MODE="container"
    elif [ -f "shopark" ] || [ -f "shopark-linux-amd64" ] || [ -f "shopark-linux-arm64" ]; then
        MODE="binary"
    else
        MODE="container"
    fi
fi

# 5. 容器模式 Profile 解析函数
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

# 6. 回滚逻辑实现
do_rollback() {
    log_info "正在执行系统回滚操作..."
    local backup_root="backup"
    if [ ! -d "$backup_root" ]; then
        log_error "未找到任何历史备份目录 ($backup_root)，无法自动回滚！"
        exit 1
    fi

    # 获取最新备份记录
    local latest_meta=$(ls -t "$backup_root"/meta_*.json 2>/dev/null | head -n 1 || true)
    if [ -z "$latest_meta" ]; then
        log_error "未找到备份元数据描述文件，无法确定回滚目标！"
        exit 1
    fi

    local backup_dir=$(grep -o '"backup_dir"[[:space:]]*:[[:space:]]*"[^"]*"' "$latest_meta" | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/')
    local prev_version=$(grep -o '"previous_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$latest_meta" | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/')
    local backup_mode=$(grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$latest_meta" | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/')

    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        log_error "备份目录不存在: $backup_dir"
        exit 1
    fi

    echo "--------------------------------------------------------"
    echo "  回滚目标: $backup_dir"
    echo "  目标版本: $prev_version"
    echo "  运行模式: $backup_mode"
    echo "--------------------------------------------------------"

    if [ "$AUTO_YES" != true ]; then
        read -r -p "确认将系统立即回滚到上述备份版本吗？ [y/N]: " confirm_rollback
        if [[ ! "$confirm_rollback" =~ ^[Yy]$ ]]; then
            log_warn "用户取消回滚操作。"
            exit 0
        fi
    fi

    if [ "$backup_mode" = "container" ]; then
        if [ -f "$backup_dir/.env" ]; then
            cp -f "$backup_dir/.env" .env
            log_success "已恢复环境变量配置文件: .env"
        fi
        if [ -d "$backup_dir/config" ]; then
            cp -rf "$backup_dir/config/"* config/ 2>/dev/null || true
            log_success "已恢复配置目录: config/"
        fi

        log_info "正在重新拉起回滚版本的容器..."
        local rollback_profile_args
        rollback_profile_args=$(get_profile_args)
        $COMPOSE_CMD $rollback_profile_args up -d --force-recreate shopark
        log_success "容器回滚拉起完成！"

        # 回滚服务就绪探测
        local http_port="5490"
        if [ -f ".env" ]; then
            http_port=$(grep -E "^SHOPARK_HTTP_PORT=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' || echo "5490")
        fi
        http_port="${http_port:-5490}"
        log_info "正在验证回滚后服务就绪状态 (循环探测 http://127.0.0.1:${http_port}) ..."
        local probe_ok=false
        for i in $(seq 1 30); do
            sleep 2
            if curl -s -f -m 3 "http://127.0.0.1:${http_port}" >/dev/null 2>&1 || \
               curl -s -f -m 3 "http://127.0.0.1:${http_port}/api/admin/auth/password-key" >/dev/null 2>&1; then
                probe_ok=true
                break
            fi
            echo -n "."
        done
        echo ""
        if [ "$probe_ok" = true ]; then
            log_success "回滚版本健康探测通过！"
        else
            log_warn "服务尚未响应，建议检查日志: $COMPOSE_CMD logs shopark"
        fi
    else
        # 二进制模式回滚
        if [ -f "$backup_dir/shopark" ]; then
            cp -f "$backup_dir/shopark" ./shopark
            chmod +x ./shopark
        fi
        if [ -f "$backup_dir/shopark-prepare" ]; then
            cp -f "$backup_dir/shopark-prepare" ./shopark-prepare
            chmod +x ./shopark-prepare
        fi
        for dir in plugins resource themes; do
            if [ -d "$backup_dir/$dir" ]; then
                rm -rf "$dir"
                cp -rf "$backup_dir/$dir" ./
            fi
        done
        log_success "文件已恢复至旧版状态。"
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active shopark >/dev/null 2>&1; then
            systemctl restart shopark
            log_success "已平滑重启 shopark.service"
        else
            log_warn "请重启您的 Shopark 服务进程以应用回滚。"
        fi
    fi

    log_success "回滚操作完成！当前系统已恢复至上一稳定版本 ($prev_version)。"
    exit 0
}

if [ "$DO_ROLLBACK" = true ]; then
    do_rollback
fi

# 7. 升级执行主干流程
acquire_lock

echo "========================================================"
echo "         Shopark 在线升级系统 (Mode: $MODE)"
echo "========================================================"
echo ""

# 步骤 7.1：查询当前版本
CURRENT_VERSION="latest"
if [ -f ".env" ]; then
    CURRENT_VERSION=$(grep -E "^SHOPARK_VERSION=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' || echo "latest")
elif [ -f ".version" ]; then
    CURRENT_VERSION=$(cat .version 2>/dev/null | tr -d ' "\r\n')
fi
CURRENT_VERSION="${CURRENT_VERSION:-latest}"
log_info "当前运行版本: ${CYAN}${CURRENT_VERSION}${NC}"

# 步骤 7.2：解析目标版本
TARGET_TAG="$TARGET_VERSION"
if [ -z "$TARGET_TAG" ] || [ "$TARGET_TAG" = "latest" ]; then
    log_info "正在检测官方最新发布版本 (查询镜像源)..."
    MIRROR_SOURCES=$(detect_mirror_priority)
    for src in $MIRROR_SOURCES; do
        LATEST_FOUND=$(resolve_latest_tag "$src")
        if [ -n "$LATEST_FOUND" ]; then
            TARGET_TAG="$LATEST_FOUND"
            log_info "从 $src 成功获取最新版本: ${CYAN}${TARGET_TAG}${NC}"
            break
        fi
    done
fi

TARGET_TAG="${TARGET_TAG:-latest}"
echo "--------------------------------------------------------"
echo "  当前版本: $CURRENT_VERSION"
echo "  目标版本: $TARGET_TAG"
echo "--------------------------------------------------------"

if [ "$CHECK_ONLY" = true ]; then
    if [ "$CURRENT_VERSION" != "latest" ] && [ "$CURRENT_VERSION" = "$TARGET_TAG" ]; then
        log_success "当前系统已是最新版本，无需升级。"
    else
        log_info "检测到可升级版本: $TARGET_TAG"
        log_info "运行 'bash scripts/upgrade.sh' 即可执行升级。"
    fi
    exit 0
fi

# 步骤 7.3：创建系统安全备份 (Backup)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="backup/${MODE}_${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

log_info "正在创建升级前安全备份到: ${BACKUP_DIR} ..."

if [ "$MODE" = "container" ]; then
    if [ -f ".env" ]; then
        cp .env "$BACKUP_DIR/.env"
    fi
    if [ -d "config" ]; then
        cp -r config "$BACKUP_DIR/config"
    fi
else
    if [ -f "shopark" ]; then
        cp shopark "$BACKUP_DIR/shopark"
    fi
    if [ -f "shopark-prepare" ]; then
        cp shopark-prepare "$BACKUP_DIR/shopark-prepare"
    fi
    for dir in plugins resource themes; do
        if [ -d "$dir" ]; then
            cp -r "$dir" "$BACKUP_DIR/$dir"
        fi
    done
    if [ -f ".env" ]; then
        cp .env "$BACKUP_DIR/.env"
    fi
    if [ -d "config" ]; then
        cp -r config "$BACKUP_DIR/config"
    fi
fi

cat <<EOF > "backup/meta_${TIMESTAMP}.json"
{
  "timestamp": "$TIMESTAMP",
  "mode": "$MODE",
  "previous_version": "$CURRENT_VERSION",
  "target_version": "$TARGET_TAG",
  "backup_dir": "$BACKUP_DIR"
}
EOF

log_success "安全快照备份完成！(元数据保存在 backup/meta_${TIMESTAMP}.json)"

if [ "$BACKUP_ONLY" = true ]; then
    log_success "仅执行备份完成。"
    exit 0
fi

# 用户确认环节
if [ "$AUTO_YES" != true ]; then
    read -r -p "确认将系统升级至版本 [${TARGET_TAG}] 吗？ [Y/n]: " input_confirm
    input_confirm=${input_confirm:-Y}
    if [[ ! "$input_confirm" =~ ^[Yy]$ ]]; then
        log_warn "用户取消升级操作。"
        exit 0
    fi
fi

# 步骤 7.4：容器模式升级实现
if [ "$MODE" = "container" ]; then
    PROFILE_ARGS=$(get_profile_args)

    # 1. 更新 .env 中的版本号
    if [ -f ".env" ]; then
        if grep -q "^SHOPARK_VERSION=" .env; then
            # 兼容 Linux / macOS sed 替换
            if sed --version >/dev/null 2>&1; then
                sed -i "s/^SHOPARK_VERSION=.*/SHOPARK_VERSION=${TARGET_TAG}/" .env
            else
                sed -i '' "s/^SHOPARK_VERSION=.*/SHOPARK_VERSION=${TARGET_TAG}/" .env
            fi
        else
            echo "SHOPARK_VERSION=${TARGET_TAG}" >> .env
        fi
    fi

    # 2. 检查 git 编排文件是否有更新（如果是 git 克隆仓库）
    if [ -d ".git" ] && command -v git >/dev/null 2>&1; then
        log_info "正在检查部署编排文件是否有更新 (git pull)..."
        git pull --ff-only 2>/dev/null || log_warn "Git 同步跳过 (本地有修改或网络离线)"
    fi

    # 3. 拉取新镜像
    log_info "正在拉取最新容器镜像: ${TARGET_TAG} ..."
    if ! $COMPOSE_CMD $PROFILE_ARGS pull shopark; then
        log_error "镜像拉取失败！正在恢复原配置..."
        if [ -f "$BACKUP_DIR/.env" ]; then
            cp -f "$BACKUP_DIR/.env" .env
        fi
        exit 1
    fi

    # 4. 预先创建挂载目录并平滑更新拉起容器（entrypoint 自动运行 shopark prepare 和 PHP 迁移）
    mkdir -p data config public/uploads runtime data/theme-releases plugins/app themes
    log_info "正在平滑重建并启动 Shopark 应用容器..."
    $COMPOSE_CMD $PROFILE_ARGS up -d --force-recreate shopark

    # 5. 服务就绪探测 (Health Check Probe)
    HTTP_PORT=5490
    if [ -f ".env" ]; then
        HTTP_PORT=$(grep -E "^SHOPARK_HTTP_PORT=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "\r' || echo "5490")
    fi
    HTTP_PORT="${HTTP_PORT:-5490}"

    log_info "正在验证服务就绪状态 (循环探测 http://127.0.0.1:${HTTP_PORT}) ..."
    PROBE_SUCCESS=false
    for i in $(seq 1 30); do
        sleep 2
        if curl -s -f -m 3 "http://127.0.0.1:${HTTP_PORT}" >/dev/null 2>&1 || \
           curl -s -f -m 3 "http://127.0.0.1:${HTTP_PORT}/api/admin/auth/password-key" >/dev/null 2>&1; then
            PROBE_SUCCESS=true
            break
        fi
        echo -n "."
    done
    echo ""

    if [ "$PROBE_SUCCESS" = true ]; then
        log_success "🎉 恭喜！Shopark 系统在线平滑升级成功！"
        echo "========================================================"
        echo "  当前版本: ${CYAN}${TARGET_TAG}${NC}"
        echo "  前台地址: http://localhost:${HTTP_PORT}"
        echo "  后台地址: http://localhost:${HTTP_PORT}/admin/"
        echo "========================================================"
    else
        log_error "升级后服务健康探测超时！"
        log_warn "打印容器最近 30 行日志辅助排查:"
        $COMPOSE_CMD $PROFILE_ARGS logs --tail=30 shopark || true
        log_warn "如需立即回滚到升级前版本，请执行: bash scripts/upgrade.sh --rollback"
        exit 1
    fi

# 步骤 7.5：二进制模式升级实现 (Host Binary Mode)
else
    # 架构与操作系统检测
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            log_error "不支持的 CPU 架构: $ARCH"
            exit 1
            ;;
    esac

    TARBALL_NAME="shopark-${TARGET_TAG}-${OS}-${ARCH}.tar.gz"
    TEMP_DIR=$(mktemp -d -t shopark-upgrade-XXXXXX 2>/dev/null || mktemp -d)

    log_info "正在下载对应系统架构的 Release 资产包: $TARBALL_NAME ..."

    DOWNLOAD_OK=false
    MIRROR_SOURCES=$(detect_mirror_priority)
    for src in $MIRROR_SOURCES; do
        if [ "$src" = "cdn" ]; then
            PLAIN_VER="${TARGET_TAG#v}"
            DOWNLOAD_URL="https://cdn.hoxi.dev/shopark/container/${PLAIN_VER}/shopark-${PLAIN_VER}-${OS}-${ARCH}.tar.gz"
        elif [ "$src" = "gitcode" ]; then
            DOWNLOAD_URL="https://gitcode.com/hoxiai/shopark/releases/download/${TARGET_TAG}/${TARBALL_NAME}"
        else
            DOWNLOAD_URL="https://github.com/hoxiai/shopark/releases/download/${TARGET_TAG}/${TARBALL_NAME}"
        fi

        log_info "正在从 $src 下载: $DOWNLOAD_URL ..."
        if curl -f -L --connect-timeout 10 --retry 1 --progress-bar -o "$TEMP_DIR/$TARBALL_NAME" "$DOWNLOAD_URL"; then
            DOWNLOAD_OK=true
            break
        fi
    done

    if [ "$DOWNLOAD_OK" != true ]; then
        log_error "无法下载目标版本的 Release 资产包，请确认该版本已在 GitCode 或 GitHub 发布附件。"
        exit 1
    fi

    # 解压至暂存目录
    log_info "正在解压校验资产包..."
    tar -xzf "$TEMP_DIR/$TARBALL_NAME" -C "$TEMP_DIR"

    # 原子替换执行文件与静态资源
    log_info "正在应用新版本代码与二进制..."
    if [ -f "$TEMP_DIR/shopark" ] || [ -f "$TEMP_DIR/shopark-${OS}-${ARCH}" ]; then
        NEW_BIN="$TEMP_DIR/shopark"
        [ -f "$NEW_BIN" ] || NEW_BIN="$TEMP_DIR/shopark-${OS}-${ARCH}"
        mv "$NEW_BIN" ./shopark
        chmod +x ./shopark
    else
        log_error "发行包缺少主程序；已停止升级。"
        exit 1
    fi

    PREPARE_COMMAND=(./shopark prepare)
    # 指定旧版本时只使用该归档配套的工具，不能误用上一版本遗留的二进制。
    if [ -f "$TEMP_DIR/shopark-prepare" ] || [ -f "$TEMP_DIR/shopark-prepare-${OS}-${ARCH}" ]; then
        NEW_PREP="$TEMP_DIR/shopark-prepare"
        [ -f "$NEW_PREP" ] || NEW_PREP="$TEMP_DIR/shopark-prepare-${OS}-${ARCH}"
        mv "$NEW_PREP" ./shopark-prepare
        chmod +x ./shopark-prepare
        PREPARE_COMMAND=(./shopark-prepare)
    fi

    # 保护性同步目录 (排除敏感与数据文件)
    for dir in plugins resource themes; do
        if [ -d "$TEMP_DIR/$dir" ]; then
            rsync -a --delete \
                --exclude="app" \
                --exclude="conf.yaml" \
                --exclude="shopark.lock" \
                "$TEMP_DIR/$dir/" "$dir/" 2>/dev/null || cp -rf "$TEMP_DIR/$dir/"* "$dir/"
        fi
    done

    # 执行数据库迁移
    log_info "正在执行数据库迁移..."
    if ! "${PREPARE_COMMAND[@]}" --config ./config/conf.yaml; then
        log_error "配置或应用注册表迁移失败；已停止升级，请检查日志或执行回滚。"
        exit 1
    fi
    if [ ! -f "plugins/shopark" ] || ! command -v php >/dev/null 2>&1; then
        log_error "缺少 PHP CLI 或 plugins/shopark；已停止升级。"
        exit 1
    fi
    if ! (cd plugins && php shopark db:sync); then
        log_error "PHP 表迁移失败；已停止升级，请检查日志或执行回滚。"
        exit 1
    fi

    # 必需迁移全部成功后才记录目标版本。
    echo "$TARGET_TAG" > .version

    # 尝试平滑重启服务
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active shopark >/dev/null 2>&1; then
        log_info "正在重启 systemd 服务 (systemctl restart shopark)..."
        systemctl restart shopark
        log_success "Shopark 系统服务重启成功！"
    else
        log_warn "未检测到 systemd 托管，请手动重启正在运行的 shopark 进程！"
    fi

    log_success "🎉 二进制与资产升级成功！当前版本: ${CYAN}${TARGET_TAG}${NC}"
fi
