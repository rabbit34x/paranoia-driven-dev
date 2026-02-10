#!/usr/bin/env bash
# pdd-event-logger.sh - PDD イベントを JSONL に記録する Claude Code hook スクリプト
#
# 使用方法: echo '<stdin_json>' | bash pdd-event-logger.sh <hook_phase>
# hook_phase: post_tool_use | notification | subagent_start | subagent_stop

set -euo pipefail

# === 定数定義 ===
HOOK_PHASE="${1:-unknown}"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVENT_LOG="${PROJECT_ROOT}/workspace/.pdd-events.jsonl"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"

# === stdin 読み取り ===
# Claude Code hooks は stdin に JSON を渡す
STDIN_JSON="$(cat)"

# stdin が空の場合は何もせず終了
if [ -z "$STDIN_JSON" ]; then
  echo '{}'
  exit 0
fi

# === jq 存在チェック ===
if ! command -v jq &>/dev/null; then
  echo '{}'
  exit 0
fi

# === ツール名の抽出 ===
TOOL_NAME="$(echo "$STDIN_JSON" | jq -r '.tool_name // .tool // "unknown"' 2>/dev/null || echo "unknown")"

# === 無限ループ防止 ===
# pdd-event-logger.sh は JSONL ファイルへの追記に ">>" (append リダイレクト) を使用し、
# Claude Code のツール (Write/Edit) を経由しない。したがって Write/Edit の PostToolUse hook が
# JSONL 追記によって再発火することはなく、原理的に無限ループは発生しない。
# 以下のチェックは防御的プログラミングとして残すが、実際に発火するケースは想定されない。
FILE_PATH="$(echo "$STDIN_JSON" | jq -r '.tool_input.file_path // .tool_input.path // .input.file_path // .input.path // ""' 2>/dev/null || echo "")"
if [[ "$FILE_PATH" == *".pdd-events.jsonl"* ]]; then
  echo '{}'
  exit 0
fi

# === workspace/ 外のファイル変更は無視 ===
# file_change 系イベントで workspace/ 外のパスは記録しない
if [[ "$HOOK_PHASE" == "post_tool_use" ]]; then
  if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "MultiEdit" ]]; then
    if [[ -n "$FILE_PATH" && "$FILE_PATH" != *"workspace/"* ]]; then
      echo '{}'
      exit 0
    fi
  fi
fi

# === イベントログディレクトリ確保 ===
mkdir -p "$(dirname "$EVENT_LOG")"

# === subagent_start イベント処理 ===
if [[ "$HOOK_PHASE" == "subagent_start" ]]; then
  AGENT="$(echo "$STDIN_JSON" | jq -r '.agent_name // .name // .subagent_name // "unknown"' 2>/dev/null || echo "unknown")"
  SUMMARY="$(echo "$STDIN_JSON" | jq -r '.prompt // .description // .task // ""' 2>/dev/null | head -c 200 || echo "")"

  jq -n -c \
    --arg ts "$TIMESTAMP" \
    --arg type "agent_start" \
    --arg agent "$AGENT" \
    --arg summary "$SUMMARY" \
    '{timestamp: $ts, type: $type, agent: $agent, data: {tool_input_summary: $summary}}' \
    >> "$EVENT_LOG"

  echo '{}'
  exit 0
fi

# === subagent_stop イベント処理 ===
if [[ "$HOOK_PHASE" == "subagent_stop" ]]; then
  AGENT="$(echo "$STDIN_JSON" | jq -r '.agent_name // .name // .subagent_name // "unknown"' 2>/dev/null || echo "unknown")"
  REASON="$(echo "$STDIN_JSON" | jq -r '.reason // .status // "completed"' 2>/dev/null || echo "completed")"

  jq -n -c \
    --arg ts "$TIMESTAMP" \
    --arg type "agent_stop" \
    --arg agent "$AGENT" \
    --arg reason "$REASON" \
    '{timestamp: $ts, type: $type, agent: $agent, data: {reason: $reason}}' \
    >> "$EVENT_LOG"

  echo '{}'
  exit 0
fi

# === post_tool_use イベント処理 ===
if [[ "$HOOK_PHASE" == "post_tool_use" ]]; then
  case "$TOOL_NAME" in
    Write|Edit|MultiEdit)
      # file_change イベント
      ACTION="write"
      if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "MultiEdit" ]]; then
        ACTION="edit"
      fi
      # file_path からファイル名を抽出 (PROJECT_ROOT からの相対パスに変換)
      REL_PATH="$(echo "$FILE_PATH" | sed "s|${PROJECT_ROOT}/||" 2>/dev/null || echo "$FILE_PATH")"
      # agent 名の推定: stdin JSON から session/agent 情報があれば利用、なければ unknown
      AGENT="$(echo "$STDIN_JSON" | jq -r '.agent_name // .session.agent_name // "unknown"' 2>/dev/null || echo "unknown")"

      jq -n -c \
        --arg ts "$TIMESTAMP" \
        --arg type "file_change" \
        --arg agent "$AGENT" \
        --arg action "$ACTION" \
        --arg file_path "$REL_PATH" \
        --arg tool "$TOOL_NAME" \
        '{timestamp: $ts, type: $type, agent: $agent, data: {action: $action, file_path: $file_path, tool: $tool}}' \
        >> "$EVENT_LOG"
      ;;

    Task)
      # Task ツールの PostToolUse: タスク完了として記録
      # 注: agent_start は SubagentStart hook で記録されるため、ここでは task_completed を記録する
      AGENT="$(echo "$STDIN_JSON" | jq -r '.tool_input.name // .tool_input.agent_name // .agent_name // "unknown"' 2>/dev/null || echo "unknown")"
      SUMMARY="$(echo "$STDIN_JSON" | jq -r '.tool_input.prompt // .tool_input.description // ""' 2>/dev/null | head -c 200 || echo "")"

      jq -n -c \
        --arg ts "$TIMESTAMP" \
        --arg type "task_completed" \
        --arg agent "$AGENT" \
        --arg summary "$SUMMARY" \
        '{timestamp: $ts, type: $type, agent: $agent, data: {summary: $summary}}' \
        >> "$EVENT_LOG"
      ;;

    SendMessage)
      # SendMessage: comms, zap, accusation の判定
      AGENT="$(echo "$STDIN_JSON" | jq -r '.agent_name // .session.agent_name // "unknown"' 2>/dev/null || echo "unknown")"
      TO="$(echo "$STDIN_JSON" | jq -r '.tool_input.to // .tool_input.recipient // "unknown"' 2>/dev/null || echo "unknown")"
      MSG="$(echo "$STDIN_JSON" | jq -r '.tool_input.message // .tool_input.content // .tool_input.text // ""' 2>/dev/null | head -c 500 || echo "")"

      # ZAP 検出: メッセージ内に "ZAP" が含まれるか
      if echo "$MSG" | grep -qi "ZAP ZAP ZAP"; then
        # zap イベント
        # CR-M003 fix: grep -oP は macOS 非互換なので sed に書き換え
        TARGET="$(echo "$MSG" | sed -n 's/.*ZAP ZAP ZAP[[:space:]]*→\?[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1 || echo "unknown")"
        if [ -z "$TARGET" ]; then
          TARGET="unknown"
        fi
        REASON="$(echo "$MSG" | head -c 200)"
        jq -n -c \
          --arg ts "$TIMESTAMP" \
          --arg type "zap" \
          --arg agent "$AGENT" \
          --arg target "$TARGET" \
          --arg reason "$REASON" \
          '{timestamp: $ts, type: $type, agent: $agent, data: {target: $target, reason: $reason}}' \
          >> "$EVENT_LOG"
      elif echo "$MSG" | grep -qiE "告発|反逆|treason|accus"; then
        # accusation イベント
        TARGET="$TO"
        EVIDENCE="$(echo "$MSG" | head -c 300)"
        jq -n -c \
          --arg ts "$TIMESTAMP" \
          --arg type "accusation" \
          --arg agent "$AGENT" \
          --arg target "$TARGET" \
          --arg evidence "$EVIDENCE" \
          '{timestamp: $ts, type: $type, agent: $agent, data: {target: $target, evidence: $evidence}}' \
          >> "$EVENT_LOG"
      else
        # 通常の comms イベント
        SUMMARY="$(echo "$MSG" | head -c 200)"
        jq -n -c \
          --arg ts "$TIMESTAMP" \
          --arg type "comms" \
          --arg agent "$AGENT" \
          --arg to "$TO" \
          --arg summary "$SUMMARY" \
          '{timestamp: $ts, type: $type, agent: $agent, data: {to: $to, summary: $summary}}' \
          >> "$EVENT_LOG"
      fi
      ;;

    *)
      # その他のツールは無視
      ;;
  esac
fi

# === notification イベント処理 ===
if [[ "$HOOK_PHASE" == "notification" ]]; then
  MSG="$(echo "$STDIN_JSON" | jq -r '.message // .notification // .text // ""' 2>/dev/null | head -c 300 || echo "")"

  if echo "$MSG" | grep -qi "idle"; then
    jq -n -c \
      --arg ts "$TIMESTAMP" \
      --arg type "teammate_idle" \
      --arg message "$MSG" \
      '{timestamp: $ts, type: "teammate_idle", agent: "unknown", data: {message: $message}}' \
      >> "$EVENT_LOG"
  fi
fi

# === hook 正常終了 ===
# Claude Code hooks は stdout に JSON を期待する
# 空オブジェクトを返すことで「変更なし」を示す
echo '{}'
exit 0
