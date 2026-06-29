#!/bin/bash
# =======================================================================
# 파일명: setup.sh
# 목적: B1-1 및 B1-2 요구사항(보안, 계정, 권한, ACL, 환경변수, cron, logrotate) 자동 구축
# 실행 방법: sudo ./setup.sh
# 실행 권한 부여: chmod +x setup.sh
#Target OS: Ubuntu 24.04 LTS (UTM 가상화 환경 환경 대응 완료)
# =======================================================================

# [안전 장치] set -e 명령어는 스크립트 실행 중 임의의 명령어가 실패(에러)하면
# 이후 과정을 실행하지 않고 즉시 안전하게 중단시키는 역할을 합니다.
set -e

echo "================================================================"
echo "[Infra Build] Starting integrated server environment setup and ACL binding for B1-1/B1-2."
echo "================================================================"

# [글로벌 변수 정의]
# 실제 서비스를 총괄 운영할 핵심 관리자 계정과 핵심 앱 경로를 지정합니다.
TARGET_USER="agent-admin"
AGENT_HOME="/home/${TARGET_USER}/agent-app"

# -----------------------------------------------------------------------
# 0. 시스템 타임존 최적화 (KST 한국 표준시 설정)
# -----------------------------------------------------------------------
# 서버의 시간대가 다르면 로그 파일의 타임스탬프가 꼬여 장애 원인 분석이 불가능해집니다.
# 시스템 전체의 시간대 설정을 대한민국 표준시(KST)로 강제 정렬합니다.
echo "[0/7] Changing system timezone to KST (Asia/Seoul)..."
timedatectl set-timezone Asia/Seoul


# -----------------------------------------------------------------------
# 1. 계정 및 그룹 체계 구성 (최소 권한 정책 반영)
# -----------------------------------------------------------------------
# 역할 분담(운영자, 개발자, 테스터)을 위해 전용 그룹과 사용자를 개설합니다.
echo "[1/7] Creating and configuring groups and user accounts..."

# getent 명령어로 해당 그룹이 이미 존재하는지 검사하고, 없을 때만 안전하게 생성합니다.
getent group agent-common >/dev/null || groupadd agent-common
getent group agent-core >/dev/null || groupadd agent-core

# [agent-dev] 개발 및 운영을 담당하며, 관제 스크립트(monitor.sh)의 소유자가 됩니다.
if ! id "agent-dev" &>/dev/null; then
    useradd -m -s /bin/bash agent-dev
    echo "User account 'agent-dev' has been created."
fi
# 개발자는 공통 그룹(common)과 핵심 관리 그룹(core)에 모두 배속되어 모든 자원을 봐야 합니다.
usermod -aG agent-common,agent-core agent-dev

# [agent-test] QA 및 테스트 담당자입니다. 보안 자원에는 접근할 수 없어야 합니다.
if ! id "agent-test" &>/dev/null; then
    useradd -m -s /bin/bash agent-test
    echo "User account 'agent-test' has been created."
fi
# 테스터는 오직 일반 공통 그룹(common)에만 포함시키고 핵심 권한(core)에서는 제외합니다.
usermod -aG agent-common agent-test

# 실제 미션을 수행하고 시스템을 기동하는 본체 계정(agent-admin)을 그룹들에 바인딩합니다.
usermod -aG agent-common,agent-core "${TARGET_USER}"


# -----------------------------------------------------------------------
# 2. SSH 보안 설정 (포트 20022 변경, Root 원격 로그인 차단, 암호 인증 활성화)
# -----------------------------------------------------------------------
# 해커들의 무차별 대입 공격을 방어하기 위해 표준 22번 포트를 20022로 변경하고,
# 최고 관리자(root) 권한으로 외부에서 바로 로그인하는 주소를 원천 차단합니다.
echo "[2/7] Optimizing SSH server security and applying password authentication policy..."

SSHD_CONFIG="/etc/ssh/sshd_config"
# 만약의 사태를 대비하여 원본 설정 파일을 백업(.bak)해 둡니다.
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

# sed -i 명령어로 설정 파일 내의 텍스트 패턴을 찾아 실시간으로 치환합니다.
# 주석 기호(#)가 있든 없든 매칭하여 지정한 보안 규격 값으로 수정합니다.
sed -i 's/^#\?Port .*/Port 20022/' "$SSHD_CONFIG"
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' "$SSHD_CONFIG"

# 실습 편의성을 위해 패스워드 기반의 인증 방식을 확실하게 허용(yes)으로 기입합니다.
if grep -q "^#\?PasswordAuthentication" "$SSHD_CONFIG"; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
else
    echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
fi

# Ubuntu 24.04 버전은 시스템이 켜질 때 ssh 서비스가 늘 대기하는 게 아니라,
# 포트 신호가 올 때만 반응하는 'ssh.socket' 제어권이 기본 활성화되어 있습니다.
# 이 상태에서는 sshd_config 파일 내부 포트를 고쳐도 반영되지 않으므로,
# 소켓 방식을 강제로 내리고(disable) 전통적인 독립형 ssh 서비스 모드로 리스타트합니다.
systemctl stop ssh.socket || true
systemctl disable ssh.socket || true
systemctl enable ssh
systemctl restart ssh


# -----------------------------------------------------------------------
# 3. 네트워크 방화벽(UFW) 정책 구성 (인바운드 규칙 제한)
# -----------------------------------------------------------------------
# 필요한 구멍(포트)만 열고 나머지는 전부 닫아 거대한 벽을 세우는 보안 작업입니다.
echo "[3/7] Enabling UFW firewall rules and opening required ports..."

# 기존에 꼬여있을지 모르는 규칙들을 완전히 초기화(--force reset)합니다.
ufw --force reset
# 외부에서 안으로 들어오는 모든 접근(incoming)의 기본 기본값을 거부(deny)로 차단합니다.
ufw default deny incoming  

# 과제 명세서가 요구한 SSH 보안 통로(20022)와 실행 어플리케이션 통로(15034)만 콕 집어서 개방합니다.
ufw allow 20022/tcp comment 'Secure SSH Port'
ufw allow 15034/tcp comment 'Application Port'
# 방화벽 서비스를 묻지 않고 즉시 활성화(--force enable)합니다.
ufw --force enable


# -----------------------------------------------------------------------
# 4. 디렉토리 구조 수립 및 소유권/권한(ACL 구조 필수 반영) 설정
# -----------------------------------------------------------------------
# 다중 사용자 환경에서 서로의 파일을 훔쳐보거나 훼손하지 못하도록 통제구역을 설계합니다.
echo "[4/7] Building AGENT directory tree and applying advanced ACL access control..."

# 리눅스 일반 기본 권한(chmod)만으로는 한 디렉토리에 여러 그룹을 다르게 배치하기 어렵습니다.
# 확장 권한 관리를 지탱하는 POSIX 'acl' 패키지가 없다면 조용히 설치합니다.
if ! command -v setfacl &>/dev/null; then
    apt-get update -qq && apt-get install -y acl -qq
fi

# 에이전트 구동에 필요한 내부 방들을 일괄 생성합니다.
mkdir -p "$AGENT_HOME/upload_files" "$AGENT_HOME/api_keys" "$AGENT_HOME/bin"
mkdir -p "/var/log/agent-app"

# [인증 키 파일 더블 바인딩] -> 순서 변경
# B1-1과 B1-2의 요구 규격 파일명이 서로 미세하게 다른 점을 상쇄하기 위해 두 버전 모두 생성해 둡니다.
echo "agent_api_key_test" > "$AGENT_HOME/api_keys/secret.key"
echo "agent_api_key_test" > "$AGENT_HOME/api_keys/t_secret.key"

# 1차적으로 모든 방의 기본 소유권자와 메인 그룹을 시스템 총괄 유저(agent-admin)로 지정합니다.
chown -R "${TARGET_USER}:${TARGET_USER}" "$AGENT_HOME"
chown -R "${TARGET_USER}:${TARGET_USER}" "/var/log/agent-app"
# 루트 공간인 AGENT_HOME 자체는 타인이 함부로 조작할 수 없게 일반 모드를 750으로 잠급니다.
chmod 750 "$AGENT_HOME"

# --------------------------------------------------------------
# [고급 권한 - 공유 디렉토리 설정]
# upload_files: 개발자, 테스터, 관리자가 모두 파일을 주고받는 공용 보관소입니다.
# --------------------------------------------------------------
setfacl -b "$AGENT_HOME/upload_files" # 기존에 묻어있던 청소용 권한 초기화
# agent-common 그룹에 속한 멤버라면 누구나 읽고/쓰고/진입(rwx)할 수 있게 부여합니다.
setfacl -m g:agent-common:rwx "$AGENT_HOME/upload_files"
# 디렉토리 내부에서 '앞으로 생성될 미래의 파일/폴더'도 이 그룹 권한을 자동 상속받도록 디폴트(-d) ACL을 설정합니다.
setfacl -d -m g:agent-common:rwx "$AGENT_HOME/upload_files"
chmod 770 "$AGENT_HOME/upload_files"

# --------------------------------------------------------------
# [고급 권한 - 보안 디렉토리 설정]
# api_keys 및 /var/log/agent-app: 핵심 인가 데이터와 비밀 키가 숨겨진 통제 구역입니다.
# --------------------------------------------------------------
# [api_keys 방 설정]
setfacl -b "$AGENT_HOME/api_keys"
# 오직 핵심 그룹(agent-core) 인원만 rwx 권한을 주어 접근 통제 장치를 마련합니다.
setfacl -m g:agent-core:rwx "$AGENT_HOME/api_keys"
setfacl -d -m g:agent-core:rwx "$AGENT_HOME/api_keys"
setfacl -m o::- "$AGENT_HOME/api_keys" # 그 외 외부인(other)은 아예 보지도 못하게 격리합니다.
chmod 770 "$AGENT_HOME/api_keys"

# [/var/log/agent-app 로그 방 설정]
setfacl -b "/var/log/agent-app"
# 로그 역시 조작이나 유출을 막기 위해 핵심 그룹(agent-core) 소속 엔지니어만 핸들링하도록 잠급니다.
setfacl -m g:agent-core:rwx "/var/log/agent-app"
setfacl -d -m g:agent-core:rwx "/var/log/agent-app"
chmod 770 "/var/log/agent-app"

# [+추가] 마지막으로 키 파일들의 상세 그룹 권한을 확정합니다.
chown -R "${TARGET_USER}:agent-core" "$AGENT_HOME/api_keys"

# 소유자와 그룹 멤버만 읽고 수정할 수 있도록 파일을 안전하게 잠급니다 (rw-rw----)
chmod 660 "$AGENT_HOME/api_keys/"*


# -----------------------------------------------------------------------
# 5. 리눅스 표준 logrotate 시스템 등록
# -----------------------------------------------------------------------
# 관제 로그가 무한히 증식하여 하드디스크를 100% 채워버리면 OS 전체가 마비됩니다.
# 리눅스 표준 백그라운드 관리 툴인 logrotate에 정책 규칙을 밀어 넣습니다.
echo "[5/7] Establishing monitoring log file size management policy (logrotate)..."

LOGROTATE_CONF="/etc/logrotate.d/agent-app"
cat << 'EOF' > "$LOGROTATE_CONF"
/var/log/agent-app/monitor.log {
    su agent-admin agent-core
    size 10M    # 로그 용량이 10메가바이트에 도달하는 순간 로테이션을 시작합니다.
    rotate 10   # 오래된 로그는 순서대로 밀어내며 최대 10개 파일까지만 역사로 남깁니다.
    compress    # 하드 공간 절약을 위해 보관 주기가 지난 로그는 gzip(.gz)으로 압축합니다.
    missingok   # 해당 로그 파일이 당장 존재하지 않더라도 에러를 뿜으며 멈추지 않고 넘어갑니다.
    notifempty  # 파일 내용이 텅 비어있을 때는 굳이 로테이션을 돌려 아까운 파일 번호를 낭비하지 않습니다.
    create 640 agent-admin agent-core # 새로 시작할 로그 파일은 640 권한과 해당 소유 구조로 자동 생성합니다.
}
EOF
chmod 0644 "$LOGROTATE_CONF"


# -----------------------------------------------------------------------
# 6. monitor.sh 정책 바인딩 및 자동화 블로커 해결
# -----------------------------------------------------------------------
# 실제 관제를 책임질 쉘 스크립트 파일의 권한을 엄격하게 단속합니다.
echo "[6/7] Applying specific permissions for the monitoring script and automation bypass..."

# 만약 사용자가 이미 수동으로 monitor.sh를 만들어 두었다면 명세서 스펙대로 옷을 갈아입힙니다.
if [ -f "$AGENT_HOME/bin/monitor.sh" ]; then
    # 소유권자는 작성자인 agent-dev, 소속 그룹은 core여야 합니다.
    chown agent-dev:agent-core "$AGENT_HOME/bin/monitor.sh"
    # 권한은 750 (소유자 rwx, 그룹 rx, 외부인 없음) 구조여야 합니다.
    chmod 750 "$AGENT_HOME/bin/monitor.sh"
    echo "Changed existing bin/monitor.sh file permissions to 750 (Owner: agent-dev)."
fi

# [비밀번호 면제 규칙]
# 크론탭 스케줄러가 매분 백그라운드에서 관제 스크립트를 실행할 때,
# 내부 코드 중 ufw 상태 점검 같은 명령어는 관리자 권한(sudo)을 달라고 요청하게 됩니다.
# 이때 비밀번호 입력 창이 뜨면 백그라운드 구동 시스템은 즉시 정체(블로킹)되어 먹통이 됩니다.
# agent-admin 사용자가 오직 ufw 명령어만은 비밀번호 검사 없이 프리패스로 실행하도록 면제부를 등록합니다.
SUDOERS_FILE="/etc/sudoers.d/agent_monitoring"
echo "${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/sbin/ufw" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"


# -----------------------------------------------------------------------
# 7. 영구 환경 변수 주입 및 crontab 스케줄러 등록
# -----------------------------------------------------------------------
# 애플리케이션의 메모리 방어선(MemoryGuard), CPU 임계치(Watchdog), 스레드 생존 조건들이
# 시스템 내부에 변수로 깊숙이 주입되도록 설계하는 단계입니다.
echo "[7/7] Injecting environment variables and registering crontab scheduler..."

BASHRC="/home/${TARGET_USER}/.bashrc"
# 동일한 환경 변수 블록이 중복 기입되어 꼬이지 않도록 식별 문구(AGENT_ENVIRONMENT_VARIABLES)로 검사합니다.
if ! grep -q "AGENT_ENVIRONMENT_VARIABLES" "$BASHRC"; then
    cat << 'EOF' >> "$BASHRC"

# ==========================================
# AGENT ENVIRONMENT VARIABLES (B1-1 / B1-2)
# ==========================================
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
export MEMORY_LIMIT=256            # B1-2 메모리 누수 임계 보호 기준선 (MB 단위)
export CPU_MAX_OCCUPY=50           # B1-2 CPU 과점유 방지 기준선 (% 단위)
export MULTI_THREAD_ENABLE=true    # B1-2 데드락 추적/회피용 멀티스레딩 스위치
EOF
fi

# [크론탭 스케줄 스왑 주입]
# * * * * * 패턴은 "매해, 매월, 매일, 매시, 매분마다 쉼 없이 구동하라"는 리눅스 공인 명령어입니다.
# -l 옵션으로 기존 스케줄을 백업하되 monitor.sh가 들어간 줄이 있다면 중복 등록 방지를 위해 청소한 뒤,
# 새 규칙을 엮어 크론탭 엔진에 밀어 넣습니다.
# 여기서 '-bin/bash -l -c'는 로그인을 새로 한 것과 똑같이 .bashrc의 환경변수를 그대로 복사해 오라는 완벽 방어형 문법입니다.
CRON_JOB="* * * * * /bin/bash -l -c '$AGENT_HOME/bin/monitor.sh'"
(crontab -u "${TARGET_USER}" -l 2>/dev/null | grep -v "monitor.sh" ; echo "$CRON_JOB") | crontab -u "${TARGET_USER}" -

echo "================================================================"
echo "🎉 [Success] All infrastructure, ACL permissions, and monitoring environments are fully established!"
echo "💡 Please reconnect to the terminal or run 'source ~/.bashrc' to apply changes."
echo "================================================================"
