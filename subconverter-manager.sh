#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY="${SUBCONVERTER_REPOSITORY:-Autlin/subconverter}"
INSTALL_ROOT="${SUBCONVERTER_HOME:-/opt/subconverter}"
SERVICE_NAME="${SUBCONVERTER_SERVICE:-subconverter}"
SERVICE_USER="${SUBCONVERTER_USER:-subconverter}"
ENV_FILE="${SUBCONVERTER_ENV_FILE:-/etc/default/subconverter}"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="${SUBCONVERTER_LOG_FILE:-/var/log/subconverter-manager.log}"
CURRENT_LINK="${INSTALL_ROOT}/current"
RELEASES_DIR="${INSTALL_ROOT}/releases"
BACKUPS_DIR="${INSTALL_ROOT}/backups"
ASSUME_YES="${SUBCONVERTER_ASSUME_YES:-0}"

PRESERVE_FILES=(
    pref.ini
    pref.toml
    pref.yml
    gistconf.ini
    generate.ini
)

PRESERVE_DIRS=(
    base
    cache
    config
    data
    profiles
    rules
    scripts
    snippets
    templates
)

TEMP_DIR=""
LOCK_FILE=""
ARCHIVE_NAME=""
RELEASE_TAG=""
RELEASE_JSON=""
ARCHIVE_URL=""
CHECKSUM_URL=""
PAYLOAD_DIR=""
NEW_RELEASE_DIR=""
LAST_BACKUP_DIR=""
PREVIOUS_RELEASE=""
LEGACY_SOURCE=""
LEGACY_WAS_ACTIVE=0
HAD_UNIT_OVERRIDE=0
HAD_ENV_FILE=0

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    printf '[%s] %s\n' "$(timestamp)" "$*"
}

status() {
    log "==> $*"
}

fail() {
    log "错误: $*"
    exit 1
}

on_error() {
    local line="$1"
    local command="$2"
    log "失败原因: 第 ${line} 行命令执行失败: ${command}"
}

cleanup() {
    if [[ -n "${TEMP_DIR}" && "${TEMP_DIR}" == /tmp/subconverter-manager.* && -d "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR}"
    fi
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "请使用 root 权限运行，例如: sudo bash subconverter-manager.sh"
    fi
}

initialize_logging() {
    local log_directory=""
    log_directory="$(dirname "${LOG_FILE}")"
    if [[ ! -d "${log_directory}" ]]; then
        install -d -m 0755 "${log_directory}"
    fi
    touch "${LOG_FILE}"
    chmod 0600 "${LOG_FILE}"
    exec > >(tee -a "${LOG_FILE}") 2>&1
}

acquire_lock() {
    if [[ ! -d /run/lock ]]; then
        install -d -m 0755 /run/lock
    fi
    LOCK_FILE="/run/lock/${SERVICE_NAME}-manager.lock"
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        fail "已有另一个部署或更新任务正在运行"
    fi
}

confirm() {
    local prompt="$1"
    local answer=""

    if [[ "${ASSUME_YES}" == "1" ]]; then
        return 0
    fi

    read -r -p "${prompt} [Y/n]: " answer
    [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]]
}

check_platform() {
    status "正在检查运行环境"

    [[ "$(uname -s)" == "Linux" ]] || fail "当前脚本仅支持 Linux"
    [[ -r /etc/os-release ]] || fail "无法识别 Linux 发行版"

    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
        fail "当前仅支持 Debian/Ubuntu 系发行版，检测到: ${PRETTY_NAME:-unknown}"
    fi

    command -v apt-get >/dev/null 2>&1 || fail "未找到 apt-get"
    command -v systemctl >/dev/null 2>&1 || fail "未找到 systemctl"
    [[ -d /run/systemd/system ]] || fail "当前系统未使用 systemd，无法创建和管理服务"
    [[ "${INSTALL_ROOT}" == /* && "${INSTALL_ROOT}" != "/" && "${INSTALL_ROOT}" != "/opt" ]] ||
        fail "安装路径必须是安全的绝对路径: ${INSTALL_ROOT}"
    [[ "${INSTALL_ROOT}" != *[[:space:]]* ]] || fail "安装路径不能包含空格: ${INSTALL_ROOT}"
    [[ "${ENV_FILE}" == /* ]] || fail "环境变量文件必须使用绝对路径: ${ENV_FILE}"
    [[ "${SERVICE_NAME}" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail "服务名包含非法字符: ${SERVICE_NAME}"
    [[ "${SERVICE_USER}" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "服务用户包含非法字符: ${SERVICE_USER}"
}

install_dependencies() {
    status "正在检查并安装运行所需工具"

    local packages=(ca-certificates coreutils curl findutils gzip jq passwd tar util-linux)
    local missing=()
    local package=""

    for package in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q 'install ok installed'; then
            missing+=("${package}")
        fi
    done

    if ((${#missing[@]} > 0)); then
        log "需要安装: ${missing[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    else
        log "运行工具已就绪"
    fi

    local command=""
    for command in curl find flock jq tar sha256sum install systemctl useradd groupadd; do
        command -v "${command}" >/dev/null 2>&1 || fail "缺少必要命令: ${command}"
    done
}

detect_architecture() {
    local machine=""
    machine="$(uname -m)"

    case "${machine}" in
        x86_64 | amd64)
            ARCHIVE_NAME="subconverter_linux_amd64.tar.gz"
            ;;
        aarch64 | arm64)
            ARCHIVE_NAME="subconverter_linux_arm64.tar.gz"
            ;;
        *)
            fail "不支持的 CPU 架构: ${machine}"
            ;;
    esac

    log "检测到架构 ${machine}，将使用 ${ARCHIVE_NAME}"
}

check_disk_space() {
    local parent=""
    local available_kb=""

    parent="$(dirname "${INSTALL_ROOT}")"
    if [[ ! -d "${parent}" ]]; then
        install -d -m 0755 "${parent}"
    fi
    available_kb="$(df -Pk "${parent}" | awk 'NR == 2 {print $4}')"
    [[ "${available_kb}" =~ ^[0-9]+$ ]] || fail "无法读取磁盘剩余空间"
    ((available_kb >= 204800)) || fail "磁盘空间不足，至少需要 200 MB 可用空间"
}

ensure_layout() {
    install -d -m 0755 "${INSTALL_ROOT}" "${RELEASES_DIR}"
    install -d -m 0700 "${BACKUPS_DIR}"
    chmod 0755 "${INSTALL_ROOT}" "${RELEASES_DIR}"
    chmod 0700 "${BACKUPS_DIR}"

    if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
        fail "${CURRENT_LINK} 已存在但不是符号链接，拒绝覆盖"
    fi
}

ensure_service_user() {
    [[ "${SERVICE_USER}" != "root" ]] || fail "拒绝使用 root 运行 subconverter 服务"

    if ! getent group "${SERVICE_USER}" >/dev/null 2>&1; then
        groupadd --system "${SERVICE_USER}"
    fi

    if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
        useradd \
            --system \
            --gid "${SERVICE_USER}" \
            --home-dir "${INSTALL_ROOT}" \
            --shell /usr/sbin/nologin \
            "${SERVICE_USER}"
    fi

    [[ "$(id -u "${SERVICE_USER}")" != "0" ]] || fail "服务用户 ${SERVICE_USER} 的 UID 为 0，已拒绝继续"
}

github_curl() {
    local args=(
        --fail
        --silent
        --show-error
        --location
        --retry 3
        --retry-delay 2
        --connect-timeout 15
    )

    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    curl "${args[@]}" "$@"
}

fetch_release_metadata() {
    status "正在获取最新发布版本"

    TEMP_DIR="$(mktemp -d /tmp/subconverter-manager.XXXXXX)"
    RELEASE_JSON="${TEMP_DIR}/release.json"

    local api_url=""
    if [[ -n "${SUBCONVERTER_VERSION:-}" ]]; then
        api_url="https://api.github.com/repos/${REPOSITORY}/releases/tags/${SUBCONVERTER_VERSION}"
    else
        api_url="https://api.github.com/repos/${REPOSITORY}/releases/latest"
    fi

    github_curl \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        "${api_url}" >"${RELEASE_JSON}"

    RELEASE_TAG="$(jq -er '.tag_name' "${RELEASE_JSON}")"
    [[ "${RELEASE_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "发布版本号格式无效: ${RELEASE_TAG}"

    ARCHIVE_URL="$(jq -er --arg name "${ARCHIVE_NAME}" '.assets[] | select(.name == $name) | .browser_download_url' "${RELEASE_JSON}")"
    CHECKSUM_URL="$(jq -er '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' "${RELEASE_JSON}")"

    log "目标版本: ${RELEASE_TAG}"
}

download_and_verify_release() {
    status "正在下载并校验发布包"

    local archive="${TEMP_DIR}/${ARCHIVE_NAME}"
    local checksum_file="${TEMP_DIR}/SHA256SUMS"
    local selected_checksum="${TEMP_DIR}/SHA256SUMS.selected"

    github_curl --output "${archive}" "${ARCHIVE_URL}"
    github_curl --output "${checksum_file}" "${CHECKSUM_URL}"

    awk -v asset="${ARCHIVE_NAME}" '$2 == asset || $2 == "*" asset {print; exit}' \
        "${checksum_file}" >"${selected_checksum}"
    [[ -s "${selected_checksum}" ]] || fail "SHA256SUMS 中没有 ${ARCHIVE_NAME}"

    (
        cd "${TEMP_DIR}"
        sha256sum -c "$(basename "${selected_checksum}")"
    )

    if LC_ALL=C tar -tzf "${archive}" | LC_ALL=C awk '
        /(^\/|(^|\/)\.\.(\/|$))/ { unsafe = 1 }
        END { exit unsafe ? 0 : 1 }
    '; then
        fail "发布包包含不安全路径，已拒绝解压"
    fi

    if LC_ALL=C tar -tvzf "${archive}" | LC_ALL=C awk '
        substr($0, 1, 1) == "l" || substr($0, 1, 1) == "h" { unsafe = 1 }
        END { exit unsafe ? 0 : 1 }
    '; then
        fail "发布包包含链接条目，已拒绝解压"
    fi

    install -d -m 0755 "${TEMP_DIR}/extract"
    tar --no-same-owner --no-same-permissions -xzf "${archive}" -C "${TEMP_DIR}/extract"
    PAYLOAD_DIR="${TEMP_DIR}/extract/subconverter"

    local unsafe_link=""
    unsafe_link="$(find "${TEMP_DIR}/extract" -type l -print -quit)"
    [[ -z "${unsafe_link}" ]] || fail "发布包包含符号链接，已拒绝安装: ${unsafe_link}"
    unsafe_link="$(find "${TEMP_DIR}/extract" -type f -links +1 -print -quit)"
    [[ -z "${unsafe_link}" ]] || fail "发布包包含硬链接，已拒绝安装: ${unsafe_link}"

    [[ -d "${PAYLOAD_DIR}" && ! -L "${PAYLOAD_DIR}" ]] || fail "发布包目录结构无效"
    [[ -f "${PAYLOAD_DIR}/subconverter" && ! -L "${PAYLOAD_DIR}/subconverter" ]] ||
        fail "发布包缺少安全的 subconverter 二进制"
    [[ -f "${PAYLOAD_DIR}/pref.example.ini" || -f "${PAYLOAD_DIR}/pref.example.toml" ]] ||
        fail "发布包缺少默认配置"

    # GitHub Artifact packaging may drop the executable bit.
    chmod 0755 "${PAYLOAD_DIR}/subconverter"
    log "发布包校验通过"
}

detect_legacy_source() {
    LEGACY_SOURCE=""

    if [[ -n "${SUBCONVERTER_IMPORT_DIR:-}" ]]; then
        [[ -d "${SUBCONVERTER_IMPORT_DIR}" ]] || fail "待导入的旧部署目录不存在: ${SUBCONVERTER_IMPORT_DIR}"
        LEGACY_SOURCE="$(readlink -f "${SUBCONVERTER_IMPORT_DIR}")"
    elif systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        local working_directory=""
        working_directory="$(systemctl show -p WorkingDirectory --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
        if [[ -n "${working_directory}" && -f "${working_directory}/subconverter" ]]; then
            LEGACY_SOURCE="$(readlink -f "${working_directory}")"
        fi
    elif [[ -f "${PWD}/subconverter" && -x "${PWD}/subconverter" ]]; then
        LEGACY_SOURCE="$(readlink -f "${PWD}")"
    fi

    if [[ -n "${LEGACY_SOURCE}" && ! -d "${LEGACY_SOURCE}" ]]; then
        fail "待导入的旧部署目录不存在: ${LEGACY_SOURCE}"
    fi
}

preserved_paths() {
    local source="$1"
    local item=""
    local path=""
    local name=""

    for item in "${PRESERVE_FILES[@]}"; do
        [[ ! -L "${source}/${item}" ]] || fail "配置文件不能是符号链接: ${source}/${item}"
        if [[ -f "${source}/${item}" ]]; then
            printf '%s\0' "${item}"
        fi
    done

    for item in "${PRESERVE_DIRS[@]}"; do
        [[ ! -L "${source}/${item}" ]] || fail "配置目录不能是符号链接: ${source}/${item}"
        if [[ -d "${source}/${item}" ]]; then
            printf '%s\0' "${item}"
        fi
    done

    shopt -s nullglob
    for path in \
        "${source}"/*.conf \
        "${source}"/*.ini \
        "${source}"/*.js \
        "${source}"/*.json \
        "${source}"/*.toml \
        "${source}"/*.yaml \
        "${source}"/*.yml; do
        name="$(basename "${path}")"
        case "${name}" in
            pref.ini | pref.toml | pref.yml | gistconf.ini | generate.ini | pref.example.ini | pref.example.toml | pref.example.yml)
                continue
                ;;
        esac
        [[ ! -L "${path}" ]] || fail "配置文件不能是符号链接: ${path}"
        [[ -f "${path}" ]] || continue
        printf '%s\0' "${name}"
    done
    shopt -u nullglob
}

backup_configuration() {
    local source="$1"
    local backup_id=""
    local path_list=""

    status "正在备份配置和用户数据"
    backup_id="$(date '+%Y%m%d-%H%M%S')"
    LAST_BACKUP_DIR="${BACKUPS_DIR}/${backup_id}"
    install -d -m 0700 "${LAST_BACKUP_DIR}"

    path_list="${LAST_BACKUP_DIR}/paths.list"
    preserved_paths "${source}" >"${path_list}"

    if [[ -s "${path_list}" ]]; then
        tar -czf "${LAST_BACKUP_DIR}/configuration.tar.gz" -C "${source}" --null --files-from "${path_list}"
    else
        tar -czf "${LAST_BACKUP_DIR}/configuration.tar.gz" --files-from /dev/null
    fi

    if [[ -f "${ENV_FILE}" ]]; then
        cp -a "${ENV_FILE}" "${LAST_BACKUP_DIR}/environment.file"
    fi
    if [[ -f "${UNIT_FILE}" ]]; then
        cp -a "${UNIT_FILE}" "${LAST_BACKUP_DIR}/service.unit"
    fi

    printf 'SOURCE=%s\nCREATED_AT=%s\n' "${source}" "$(timestamp)" >"${LAST_BACKUP_DIR}/metadata"
    log "备份已保存到 ${LAST_BACKUP_DIR}"
}

backup_control_files() {
    if [[ -z "${LAST_BACKUP_DIR}" ]]; then
        LAST_BACKUP_DIR="${BACKUPS_DIR}/control-$(date '+%Y%m%d-%H%M%S')-$$"
        install -d -m 0700 "${LAST_BACKUP_DIR}"
        printf 'CREATED_AT=%s\n' "$(timestamp)" >"${LAST_BACKUP_DIR}/metadata"
    fi

    if [[ -f "${UNIT_FILE}" && ! -f "${LAST_BACKUP_DIR}/service.unit" ]]; then
        cp -a "${UNIT_FILE}" "${LAST_BACKUP_DIR}/service.unit"
    fi
    if [[ -f "${ENV_FILE}" && ! -f "${LAST_BACKUP_DIR}/environment.file" ]]; then
        cp -a "${ENV_FILE}" "${LAST_BACKUP_DIR}/environment.file"
    fi
}

overlay_preserved_data() {
    local source="$1"
    local destination="$2"
    local item=""
    local path=""
    local name=""

    [[ -d "${source}" ]] || return 0

    for item in "${PRESERVE_FILES[@]}"; do
        [[ ! -L "${source}/${item}" ]] || fail "配置文件不能是符号链接: ${source}/${item}"
        if [[ -f "${source}/${item}" ]]; then
            cp -a -- "${source}/${item}" "${destination}/${item}"
        fi
    done

    for item in "${PRESERVE_DIRS[@]}"; do
        if [[ -L "${source}/${item}" ]]; then
            fail "配置目录不能是符号链接: ${source}/${item}"
        fi
        if [[ -d "${source}/${item}" ]]; then
            install -d -m 0755 "${destination}/${item}"
            cp -a -- "${source}/${item}/." "${destination}/${item}/"
        fi
    done

    shopt -s nullglob
    for path in \
        "${source}"/*.conf \
        "${source}"/*.ini \
        "${source}"/*.js \
        "${source}"/*.json \
        "${source}"/*.toml \
        "${source}"/*.yaml \
        "${source}"/*.yml; do
        name="$(basename "${path}")"
        case "${name}" in
            pref.ini | pref.toml | pref.yml | gistconf.ini | generate.ini | pref.example.ini | pref.example.toml | pref.example.yml)
                continue
                ;;
        esac
        [[ ! -L "${path}" ]] || fail "配置文件不能是符号链接: ${path}"
        [[ -f "${path}" ]] || continue
        cp -a -- "${path}" "${destination}/${name}"
    done
    shopt -u nullglob
}

prepare_release_directory() {
    local preserve_source="${1:-}"
    local release_id=""

    status "正在准备 ${RELEASE_TAG} 安装文件"
    release_id="${RELEASE_TAG}-$(date '+%Y%m%d%H%M%S')-$$"
    NEW_RELEASE_DIR="${RELEASES_DIR}/${release_id}"
    install -d -m 0755 "${NEW_RELEASE_DIR}"
    cp -a -- "${PAYLOAD_DIR}/." "${NEW_RELEASE_DIR}/"
    chmod 0755 "${NEW_RELEASE_DIR}/subconverter"

    if [[ -n "${preserve_source}" ]]; then
        overlay_preserved_data "${preserve_source}" "${NEW_RELEASE_DIR}"
    fi

    cat >"${NEW_RELEASE_DIR}/.subconverter-release" <<EOF
TAG=${RELEASE_TAG}
ASSET=${ARCHIVE_NAME}
INSTALLED_AT=$(timestamp)
EOF

    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${NEW_RELEASE_DIR}"
}

generate_token() {
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

ensure_environment_file() {
    local preserve_source="${1:-}"
    local environment_directory=""

    environment_directory="$(dirname "${ENV_FILE}")"
    if [[ ! -d "${environment_directory}" ]]; then
        install -d -m 0755 "${environment_directory}"
    fi

    if [[ -f "${ENV_FILE}" ]]; then
        HAD_ENV_FILE=1
        chown root:root "${ENV_FILE}"
        chmod 0600 "${ENV_FILE}"
        log "保留现有环境变量文件 ${ENV_FILE}"
        return 0
    fi

    if [[ -n "${preserve_source}" ]]; then
        printf '# Existing application configuration is preserved without environment overrides.\n' >"${ENV_FILE}"
        chown root:root "${ENV_FILE}"
        chmod 0600 "${ENV_FILE}"
        log "已创建空环境变量文件，不覆盖旧配置中的端口、API 模式或 Token"
        return 0
    fi

    local token=""
    token="$(generate_token)"
    cat >"${ENV_FILE}" <<EOF
PORT=25500
API_MODE=true
API_TOKEN=${token}
EOF
    chown root:root "${ENV_FILE}"
    chmod 0600 "${ENV_FILE}"
    log "已生成环境变量文件 ${ENV_FILE}，API Token 未输出到终端"
}

service_uses_managed_paths() {
    local working_directory=""
    local exec_start=""
    local configured_user=""
    local configured_group=""

    working_directory="$(systemctl show -p WorkingDirectory --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
    exec_start="$(systemctl show -p ExecStart --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
    configured_user="$(systemctl show -p User --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
    configured_group="$(systemctl show -p Group --value "${SERVICE_NAME}.service" 2>/dev/null || true)"

    [[ "${working_directory}" == "${CURRENT_LINK}" &&
        "${exec_start}" == *"${CURRENT_LINK}/subconverter"* &&
        "${configured_user}" == "${SERVICE_USER}" &&
        (-z "${configured_group}" || "${configured_group}" == "${SERVICE_USER}") ]]
}

write_service_unit() {
    local unit_temp=""
    local service_exists=0

    if systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        service_exists=1
    fi

    if [[ -f "${UNIT_FILE}" ]]; then
        HAD_UNIT_OVERRIDE=1
    fi

    if [[ "${service_exists}" == "1" ]] && service_uses_managed_paths; then
        log "现有 systemd 服务已指向托管目录，保留其配置"
        return 0
    fi

    if [[ "${service_exists}" == "1" ]]; then
        if ! confirm "检测到现有 ${SERVICE_NAME} 服务文件，是否备份并接管"; then
            fail "用户取消接管现有 systemd 服务"
        fi
        backup_control_files
    fi

    unit_temp="$(mktemp /tmp/subconverter-unit.XXXXXX)"
    cat >"${unit_temp}" <<EOF
# Managed by subconverter-manager
[Unit]
Description=SubConverter Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${CURRENT_LINK}
EnvironmentFile=-${ENV_FILE}
ExecStart=${CURRENT_LINK}/subconverter
Restart=on-failure
RestartSec=3s
TimeoutStopSec=20s
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

    install -m 0644 "${unit_temp}" "${UNIT_FILE}"
    rm -f -- "${unit_temp}"
}

switch_current_release() {
    local target="$1"
    local temporary_link="${INSTALL_ROOT}/.current.$$"
    local resolved_target=""
    local resolved_releases=""

    resolved_target="$(readlink -f "${target}")"
    resolved_releases="$(readlink -f "${RELEASES_DIR}")"
    [[ "${resolved_target}" == "${resolved_releases}/"* ]] || fail "拒绝切换到托管目录之外: ${resolved_target}"
    [[ -f "${resolved_target}/.subconverter-release" ]] || fail "目标目录缺少版本标记: ${resolved_target}"
    [[ -x "${resolved_target}/subconverter" && ! -L "${resolved_target}/subconverter" ]] ||
        fail "目标目录缺少安全的可执行文件: ${resolved_target}"

    rm -f -- "${temporary_link}"
    ln -s "${resolved_target}" "${temporary_link}"
    mv -Tf "${temporary_link}" "${CURRENT_LINK}"
}

configured_port() {
    local port="25500"
    local configured=""
    local config_file=""

    if [[ -f "${ENV_FILE}" ]]; then
        configured="$(sed -n 's/^PORT=//p' "${ENV_FILE}" | tail -n 1 | tr -d '\"\r')"
        if [[ "${configured}" =~ ^[0-9]+$ ]] && ((configured >= 1 && configured <= 65535)); then
            printf '%s\n' "${configured}"
            return 0
        fi
    fi

    if [[ -f "${CURRENT_LINK}/pref.toml" ]]; then
        config_file="${CURRENT_LINK}/pref.toml"
    elif [[ -f "${CURRENT_LINK}/pref.yml" ]]; then
        config_file="${CURRENT_LINK}/pref.yml"
    elif [[ -f "${CURRENT_LINK}/pref.ini" ]]; then
        config_file="${CURRENT_LINK}/pref.ini"
    fi

    if [[ -n "${config_file}" ]]; then
        case "${config_file}" in
            *.ini | *.toml)
                configured="$(awk '
                    /^[[:space:]]*\[/ {
                        section = ($0 ~ /^[[:space:]]*\[server\][[:space:]]*$/)
                        next
                    }
                    section && /^[[:space:]]*port[[:space:]]*=/ {
                        value = $0
                        sub(/^[^=]*=[[:space:]]*/, "", value)
                        gsub(/[[:space:]"\047]/, "", value)
                        print value
                        exit
                    }
                ' "${config_file}")"
                ;;
            *.yml)
                configured="$(awk '
                    /^[^[:space:]#]/ {
                        section = ($0 ~ /^server:[[:space:]]*$/)
                        next
                    }
                    section && /^[[:space:]]+port:[[:space:]]*/ {
                        value = $0
                        sub(/^[[:space:]]*port:[[:space:]]*/, "", value)
                        gsub(/[[:space:]"\047]/, "", value)
                        print value
                        exit
                    }
                ' "${config_file}")"
                ;;
        esac

        if [[ "${configured}" =~ ^[0-9]+$ ]] && ((configured >= 1 && configured <= 65535)); then
            port="${configured}"
        fi
    fi

    printf '%s\n' "${port}"
}

release_tag_from_directory() {
    local directory="$1"
    if [[ -f "${directory}/.subconverter-release" ]]; then
        sed -n 's/^TAG=//p' "${directory}/.subconverter-release" | head -n 1
    fi
}

health_check() {
    local expected_tag="${1:-}"
    local port=""
    local response=""
    local attempt=""

    status "正在检查服务状态"
    port="$(configured_port)"

    for ((attempt = 1; attempt <= 30; attempt++)); do
        if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
            response="$(curl --noproxy '*' --fail --silent --show-error --max-time 3 \
                "http://127.0.0.1:${port}/version" 2>/dev/null || true)"
            if [[ "${response}" =~ ^SubConverter\ Mi\ v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?\ Backend$ ]]; then
                if [[ -z "${expected_tag}" || "${response}" == *"${expected_tag}"* ]]; then
                    log "健康检查通过: ${response}"
                    return 0
                fi
            fi
        fi
        sleep 1
    done

    log "健康检查失败，最近服务日志如下:"
    journalctl -u "${SERVICE_NAME}.service" --since '5 minutes ago' -n 80 --no-pager || true
    return 1
}

restore_previous_service_definition() {
    if [[ -n "${LAST_BACKUP_DIR}" && -f "${LAST_BACKUP_DIR}/service.unit" ]]; then
        install -m 0644 "${LAST_BACKUP_DIR}/service.unit" "${UNIT_FILE}"
    elif [[ "${HAD_UNIT_OVERRIDE}" == "0" ]]; then
        rm -f -- "${UNIT_FILE}"
    fi

    if [[ -n "${LAST_BACKUP_DIR}" && -f "${LAST_BACKUP_DIR}/environment.file" ]]; then
        install -m 0600 "${LAST_BACKUP_DIR}/environment.file" "${ENV_FILE}"
    elif [[ "${HAD_ENV_FILE}" == "0" ]]; then
        rm -f -- "${ENV_FILE}"
    fi

    systemctl daemon-reload
}

rollback_activation() {
    log "新版本启动失败，正在自动回滚"

    if [[ -n "${PREVIOUS_RELEASE}" && -d "${PREVIOUS_RELEASE}" ]]; then
        switch_current_release "${PREVIOUS_RELEASE}" || fail "无法将 current 链接恢复到旧版本"
        restore_previous_service_definition || fail "回滚时无法恢复原 systemd 或环境配置"
        if ! systemctl restart "${SERVICE_NAME}.service"; then
            journalctl -u "${SERVICE_NAME}.service" --since '5 minutes ago' -n 80 --no-pager || true
            fail "旧版本服务无法重新启动，请立即人工检查"
        fi

        local previous_tag=""
        previous_tag="$(release_tag_from_directory "${PREVIOUS_RELEASE}")"
        if health_check "${previous_tag}"; then
            fail "更新失败，已成功回滚到 ${previous_tag:-上一版本}"
        fi
        fail "更新失败，并且旧版本恢复后健康检查仍未通过，请查看 ${LOG_FILE}"
    fi

    systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    rm -f -- "${CURRENT_LINK}"
    restore_previous_service_definition

    if [[ "${LEGACY_WAS_ACTIVE}" == "1" ]]; then
        systemctl restart "${SERVICE_NAME}.service" || true
    fi

    fail "部署失败，已撤销新服务；下载文件保留在 ${NEW_RELEASE_DIR} 便于排查"
}

activate_release() {
    local preserve_source="${1:-}"

    status "正在切换并重启服务"

    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        LEGACY_WAS_ACTIVE=1
    fi

    # Briefly stop a running service so its last configuration writes are included.
    if [[ "${LEGACY_WAS_ACTIVE}" == "1" && -n "${preserve_source}" ]]; then
        status "正在短暂停止服务并同步最终配置"
        systemctl stop "${SERVICE_NAME}.service" || rollback_activation
    fi

    if [[ -n "${preserve_source}" && "${preserve_source}" != "${NEW_RELEASE_DIR}" ]]; then
        overlay_preserved_data "${preserve_source}" "${NEW_RELEASE_DIR}" || rollback_activation
        chown -R "${SERVICE_USER}:${SERVICE_USER}" "${NEW_RELEASE_DIR}" || rollback_activation
    fi

    switch_current_release "${NEW_RELEASE_DIR}" || rollback_activation
    systemctl daemon-reload || rollback_activation
    systemctl enable "${SERVICE_NAME}.service" >/dev/null || rollback_activation
    systemctl restart "${SERVICE_NAME}.service" || rollback_activation

    if ! health_check "${RELEASE_TAG}"; then
        rollback_activation
    fi
}

managed_current_release() {
    local target=""
    local resolved_releases=""

    if [[ -L "${CURRENT_LINK}" ]]; then
        target="$(readlink -f "${CURRENT_LINK}" 2>/dev/null || true)"
        resolved_releases="$(readlink -f "${RELEASES_DIR}")"
        [[ -n "${target}" ]] || fail "current 链接已损坏: ${CURRENT_LINK}"
        [[ "${target}" == "${resolved_releases}/"* ]] || fail "current 指向托管目录之外: ${target}"
        [[ -f "${target}/.subconverter-release" ]] || fail "current 指向的目录缺少版本标记: ${target}"
        [[ -x "${target}/subconverter" && ! -L "${target}/subconverter" ]] ||
            fail "current 指向的目录缺少安全的可执行文件: ${target}"
        printf '%s\n' "${target}"
    fi
}

prepare_common() {
    require_root
    initialize_logging
    check_platform
    install_dependencies
    acquire_lock
    detect_architecture
    check_disk_space
    ensure_layout
    ensure_service_user
}

fresh_deploy() {
    status "开始全新部署"
    prepare_common

    PREVIOUS_RELEASE="$(managed_current_release)"
    if [[ -n "${PREVIOUS_RELEASE}" ]]; then
        log "检测到已由本脚本管理的部署，自动执行一键更新"
        one_click_update_prepared
        return 0
    fi

    detect_legacy_source
    if [[ -n "${LEGACY_SOURCE}" ]]; then
        log "检测到现有部署目录: ${LEGACY_SOURCE}"
        if confirm "是否导入其配置和用户数据"; then
            backup_configuration "${LEGACY_SOURCE}"
        else
            LEGACY_SOURCE=""
        fi
    elif systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        fail "检测到同名 systemd 服务，但无法确认其数据目录；请设置 SUBCONVERTER_IMPORT_DIR 后重试"
    fi

    fetch_release_metadata
    download_and_verify_release
    prepare_release_directory "${LEGACY_SOURCE}"
    ensure_environment_file "${LEGACY_SOURCE}"
    write_service_unit

    log "项目不使用数据库，跳过数据库迁移"
    activate_release "${LEGACY_SOURCE}"

    log "部署成功: ${RELEASE_TAG}"
    log "安装目录: ${CURRENT_LINK}"
    log "服务地址: http://127.0.0.1:$(configured_port)/version"
}

one_click_update_prepared() {
    PREVIOUS_RELEASE="$(managed_current_release)"
    if [[ -z "${PREVIOUS_RELEASE}" || ! -d "${PREVIOUS_RELEASE}" ]]; then
        fail "未找到有效的当前版本"
    fi

    local current_tag=""
    current_tag="$(release_tag_from_directory "${PREVIOUS_RELEASE}")"
    log "当前版本: ${current_tag:-unknown}"

    fetch_release_metadata
    if [[ "${current_tag}" == "${RELEASE_TAG}" ]] && health_check "${current_tag}"; then
        log "已经是最新版本 ${RELEASE_TAG}，无需更新"
        return 0
    fi

    backup_configuration "${PREVIOUS_RELEASE}"
    download_and_verify_release
    prepare_release_directory "${PREVIOUS_RELEASE}"
    ensure_environment_file "${PREVIOUS_RELEASE}"

    write_service_unit

    log "项目不使用数据库，跳过数据库迁移"
    activate_release "${PREVIOUS_RELEASE}"

    log "更新成功: ${current_tag:-unknown} -> ${RELEASE_TAG}"
    log "旧版本仍保留在 ${PREVIOUS_RELEASE}，可用于人工回退"
}

one_click_update() {
    status "开始一键更新"
    prepare_common

    if [[ -z "$(managed_current_release)" ]]; then
        log "未检测到本脚本管理的部署，将转为全新部署并尝试导入现有配置"
        fresh_deploy_prepared
        return 0
    fi

    one_click_update_prepared
}

fresh_deploy_prepared() {
    PREVIOUS_RELEASE=""
    detect_legacy_source

    if [[ -n "${LEGACY_SOURCE}" ]]; then
        log "检测到现有部署目录: ${LEGACY_SOURCE}"
        if confirm "是否导入其配置和用户数据"; then
            backup_configuration "${LEGACY_SOURCE}"
        else
            LEGACY_SOURCE=""
        fi
    elif systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        fail "检测到同名 systemd 服务，但无法确认其数据目录；请设置 SUBCONVERTER_IMPORT_DIR 后重试"
    fi

    fetch_release_metadata
    download_and_verify_release
    prepare_release_directory "${LEGACY_SOURCE}"
    ensure_environment_file "${LEGACY_SOURCE}"
    write_service_unit
    log "项目不使用数据库，跳过数据库迁移"
    activate_release "${LEGACY_SOURCE}"
    log "部署成功: ${RELEASE_TAG}"
}

print_menu() {
    cat <<'EOF'

SubConverter 部署与更新
=======================
1. 全新部署
2. 一键更新
3. 退出

EOF
}

main() {
    local choice="${1:-}"

    case "${choice}" in
        deploy | install | 1)
            fresh_deploy
            return
            ;;
        update | upgrade | 2)
            one_click_update
            return
            ;;
        exit | 3)
            return
            ;;
        "") ;;
        *)
            fail "未知参数: ${choice}；支持 deploy、update"
            ;;
    esac

    while true; do
        print_menu
        read -r -p "请选择操作 [1-3]: " choice
        case "${choice}" in
            1)
                fresh_deploy
                return
                ;;
            2)
                one_click_update
                return
                ;;
            3)
                log "已退出"
                return
                ;;
            *)
                printf '无效选项，请重新选择。\n'
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
