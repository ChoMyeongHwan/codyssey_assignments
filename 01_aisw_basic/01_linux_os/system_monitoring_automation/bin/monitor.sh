#!/bin/bash

# monitor.sh
# 목적:
# 1. agent-app 프로세스 정상 여부 확인
# 2. TCP 15034 LISTEN 상태 확인
# 3. UFW 활성 여부 점검
# 4. CPU / MEM / DISK 사용량 수집
# 5. 임계값 초과 시 경고 출력
# 6. 결과를 monitor.log에 저장

# 로그 저장 경로
LOG_FILE="/var/log/agent-app/monitor.log"

# 현재 시간을 로그 포맷에 맞게 저장
# $(...) : 내부 명령 실행 결과를 변수에 저장
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# 검사 대상 프로세스명
PROCESS_NAME="agent-app"

# 검사 대상 포트
PORT="15034"


# ==================================================
# STEP1. 프로세스 Health Check
# ==================================================

# pgrep
# 실행 중인 프로세스 검색
#
# -x
# 정확한 이름 일치
#
# -o
# 가장 오래 실행된 프로세스 선택
PID=$(pgrep -xo "$PROCESS_NAME")

# -z
# 문자열 길이가 0이면 true
#
# PID 없으면 앱 미실행 상태
if [ -z "$PID" ]; then
    echo "[ERROR] process '$PROCESS_NAME' is not running"
    exit 1
fi


# ==================================================
# STEP2. TCP LISTEN 상태 확인
# ==================================================

# ss
# -t : TCP
# -u : UDP
# -l : LISTEN
# -n : 숫자로 출력
#
# grep -q
# 출력하지 않고 존재 여부만 확인
#
# ! :
# 조건 결과 반전
if ! ss -tuln | grep -q ":$PORT"; then
    echo "[ERROR] TCP $PORT is not LISTEN"
    exit 1
fi


# ==================================================
# STEP3. 방화벽(UFW) 상태 확인
# ==================================================

# 방화벽 비활성은 서비스 장애는 아니므로
# WARNING만 출력하고 종료하지 않음
if ! sudo ufw status | grep -q "Status: active"; then
    echo "[WARNING] UFW is inactive"
fi


# ==================================================
# STEP4. 시스템 자원 수집
# ==================================================

# CPU 사용률
#
# top -bn1
# -b : 배치모드
# -n1 : 한 번만 실행
#
# idle(%id) 제외해서 사용률 계산
CPU=$(top -bn1 | awk '/Cpu\(s\)/ {printf "%.1f", 100 - $8}')

# 메모리 사용률
#
# free
# 메모리 정보 출력
#
# 사용량/전체용량 계산
MEM=$(free | awk '/Mem:/ {printf "%.1f", $3/$2 * 100}')

# 루트(/) 디스크 사용률
#
# df /
# 파일시스템 사용량 확인
DISK_USED=$(df / | awk '
NR==2 {
gsub("%","",$5)
print $5
}')


# ==================================================
# STEP5. 임계값 경고
# ==================================================

# Bash 숫자 비교는 소수 비교가 어려워
# 4.2 → 4 형태로 변환

CPU_INT=${CPU%.*}
MEM_INT=${MEM%.*}

# CPU 20% 초과
if [ "$CPU_INT" -gt 20 ]; then
    echo "[WARNING] CPU threshold exceeded (${CPU}% > 20%)"
fi

# MEM 10% 초과
if [ "$MEM_INT" -gt 10 ]; then
    echo "[WARNING] MEM threshold exceeded (${MEM}% > 10%)"
fi

# DISK 80% 초과
if [ "$DISK_USED" -gt 80 ]; then
    echo "[WARNING] DISK threshold exceeded (${DISK_USED}% > 80%)"
fi


# ==================================================
# STEP6. 로그 저장
# ==================================================

# >>
# 기존 내용 유지 + 맨 뒤에 추가

echo \
"[$TIMESTAMP] PID:${PID} CPU:${CPU}% MEM:${MEM}% DISK_USED:${DISK_USED}%" \
>> "$LOG_FILE"


# ==================================================
# STEP7. 실행 결과 출력
# ==================================================

echo "====== SYSTEM MONITOR RESULT ======"

echo "[HEALTH CHECK]"

echo "Checking process '$PROCESS_NAME'... [OK] (PID: $PID)"

echo "Checking port $PORT... [OK]"

echo "[RESOURCE MONITORING]"

echo "CPU Usage : ${CPU}%"

echo "MEM Usage : ${MEM}%"

echo "DISK Used : ${DISK_USED}%"

echo "[INFO] Log appended: $LOG_FILE"
