# 리눅스 프로세스 및 시스템 리소스 트러블슈팅

본 저장소는 Ubuntu 24.04 환경에서 서버 인프라를 안전하게 자동 구축하고, 운영 중 발생하는 3대 중대 장애(메모리 누수, CPU 과점유, 교착 상태)를 실시간으로 모니터링하여 문제를 해결한 엔지니어링 기록입니다. 특히, 실제 서비스 운영 환경을 가정하여 장애를 분석하고, GitHub Issue 형식의 기술 리포트를 작성하는 데 중점을 두었습니다.

## 📦 시스템 환경 (System Architecture)
*   **호스트 머신**: macOS (Intel iMac 환경)
*   **가상화 플랫폼**: UTM Emulator (Ubuntu 24.04 LTS)
*   **접속 환경**: iTerm2를 통한 SSH 원격 접속 (보안 포트: 20022)
*   **핵심 스크립트**:
    *   `setup.sh`: 서버의 보안 정책, 계정 그룹 체계, 고급 ACL 권한 설정, logrotate 통합 구축을 자동화하는 스크립트입니다. 이는 안정적인 서비스 운영을 위한 초기 인프라 설정을 담당합니다.
    *   `monitor.sh`: 프로세스 헬스체크 및 자원(CPU, MEM, DISK) 사용량 수집을 자동화하는 스크립트입니다. 실시간 모니터링을 통해 잠재적 장애 징후를 탐지하는 데 활용됩니다.

---

## 🚀 빠른 시작 (Quick Start)

### 1. 인프라 통합 구축 스크립트 실행
서버의 보안 정책과 디렉토리 권한 규칙을 일괄 자동 적용하여 안전한 운영 환경을 구축합니다.
```bash
chmod +x setup.sh
sudo ./setup.sh
```

### 2. 실시간 대화형 자원 관제 실행
크론탭(cron)의 1분 주기를 넘어, iTerm2 우측 터미널에서 2초 간격으로 실시간 상태를 모니터링하여 즉각적인 장애 탐지를 가능하게 합니다.
```bash
while true; do /home/agent-admin/agent-app/bin/monitor.sh; sleep 2; done
```

---

## 🧠 핵심 검증 기술 개념 및 선수 지식

- **메모리 누수(Memory Leak) & OOM**: 프로세스가 동적으로 할당한 힙(Heap) 메모리를 해제하지 않아 점유율이 계속 올라가는 현상입니다. 시스템 붕괴를 막기 위해 OS나 애플리케이션 자체 보호 엔진(`MemoryGuard`)이 프로세스를 강제 종료(Kill)하게 됩니다.  

- **CPU 과점유(CPU Spike) & Watchdog**: 무한 루프나 과도한 연산으로 인해 하나의 프로세스가 CPU 자원을 독점하면 전체 시스템이 응답 불가 상태가 됩니다. 이를 감시하는 `Watchdog` 스레드가 임계치를 넘긴 프로세스에 `SIGTERM` 등의 시그널을 보내 안전하게 종료시킵니다.  

- **교착상태(Deadlock)**: 두 개 이상의 스레드가 서로가 가진 자원(Lock)을 놓지 않은 채 상대방의 자원이 해제되기만을 무한히 기다리는 병목 현상입니다. 프로세스가 죽지는 않았지만(PID는 존재) 아무 일도 하지 못하는 '먹통(Hang)' 상태가 됩니다.  

---

## 📊 3대 서버 장애 시뮬레이션 결과 요약
환경 변수를 조정하여 의도적으로 장애를 유도하고, 시스템 보호 정책의 동작을 검증했습니다. 각 장애 유형별 트리거 설정값, 탐지된 핵심 시스템 로그, 그리고 조치 내용을 아래 표에 요약하였습니다.

| 장애 유형 | 트리거 설정값 (환경 변수) | 탐지된 핵심 시스템 로그 | 조치 내용 (Workaround) |
| :--- | :--- | :--- | :--- |
| [**메모리 누수 (OOM)**](https://github.com/ChoMyeongHwan/codyssey_assignments/issues/1) | `MEMORY_LIMIT=200` (MB) | `[MemoryGuard] Self-terminating process` | 가용 메모리 상향 (512MB) |
| [**CPU 과점유**](https://github.com/ChoMyeongHwan/codyssey_assignments/issues/2) | `CPU_MAX_OCCUPY=80` (%) | `WATCHDOG: INITIATING EMERGENCY ABORT` | 허용 임계치 완화 (20%) |
| [**교착 상태 (Deadlock)**](https://github.com/ChoMyeongHwan/codyssey_assignments/issues/3) | `MULTI_THREAD_ENABLE=true` | `[Thread-A] WAITING... BLOCKED` | 단일 스레드 모드 전환 (`false`) |

---

## 📝 GitHub Issue 리포트 구조 (필수)
본 과제에서 요구하는 각 장애 유형별 GitHub Issue 리포트는 다음 구조를 따라야 합니다. 이는 현업 엔지니어의 장애 분석 보고서와 동일한 형식으로, 문제 해결 과정을 명확하게 전달하는 데 목적이 있습니다.

### 1. Description (현상 설명)
*   어떤 현상이 발생했는가?
*   언제, 어떤 조건에서 발생했는가?

### 2. Evidence & Logs (증거 자료)
*   `monitor.sh` 관제 로그 데이터 (수치/그래프/스크린샷)
*   프로그램 실행 로그 핵심 구간 발췌
*   시스템 도구(ps, top 등) 출력 결과

### 3. Root Cause Analysis (원인 분석)
*   수집된 증거를 바탕으로 한 기술적 원인 분석
*   관련 OS 동작 원리 설명

### 4. Workaround & Verification (조치 및 검증)
*   어떤 환경변수를 어떻게 조정했는가?
*   Before & After 비교 결과 (수치 또는 스크린샷)
*   추가 개선 제안 (선택 사항)

---

## ⚙️ 사전 준비 및 실행 조건
본 프로젝트를 실행하기 위한 필수 환경 변수 및 조건은 다음과 같습니다.

| 항목 | 조건 |
| :--- | :--- |
| **실행 계정** | `root`가 아닌 일반 사용자 |
| **`AGENT_HOME`** | 필수 환경변수 설정 |
| **`AGENT_PORT`** | `15034` (고정) |
| **`AGENT_UPLOAD_DIR`** | `$AGENT_HOME/upload_files` (디렉토리 존재 필수) |
| **`AGENT_KEY_PATH`** | `$AGENT_HOME/api_keys` (디렉토리 존재 필수) |
| **`AGENT_LOG_DIR`** | 디렉토리 존재 및 쓰기 권한 필수 |
| **`MEMORY_LIMIT`** | `50` ~ `512` 범위의 정수 (MB) |
| **`CPU_MAX_OCCUPY`** | `10` ~ `100` 범위의 정수 (%) |
| **`MULTI_THREAD_ENABLE`** | `true` 또는 `false` (1/0, yes/no 불가) |
| **`secret.key` 파일** | `$AGENT_HOME/api_keys/secret.key`에 `agent_api_key_test` 내용으로 존재 |
| **네트워크** | `0.0.0.0:15034` 바인딩 가능 |
