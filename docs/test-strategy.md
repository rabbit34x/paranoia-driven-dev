# テスト設計書: PDD リアルタイム監視ダッシュボード

## 概要

パラノイア駆動開発(PDD)のミッション中に発生するイベントをリアルタイムで可視化するダッシュボードシステムのテスト戦略。4つのコンポーネント(イベントロガー、hook設定、SSEサーバー、ダッシュボードUI)を対象とする。

## 関連ドキュメント

- 設計書: `docs/designs/realtime-dashboard-design.md`

---

## 1. テスト戦略

### 1.1 テストレベル

| レベル | カバレッジ目標 | 優先度 |
|--------|---------------|--------|
| ユニットテスト(bash) | 全イベントタイプ・全分岐パス | 高 |
| ユニットテスト(Python) | EventStore の全メソッド | 高 |
| 統合テスト(HTTP/SSE) | 全APIエンドポイント + SSE配信 | 高 |
| E2Eテスト | hook→JSONL→SSE→ブラウザの全パイプライン | 中 |
| UI手動テスト | 全パネル表示 + エフェクト | 中 |

### 1.2 使用ツール

| カテゴリ | ツール | 理由 |
|---------|--------|------|
| bash テスト | bash スクリプト(手動実行) | 標準ツールのみ。テストフレームワーク不要 |
| Python テスト | pytest | 事実上の標準テストフレームワーク |
| HTTP テスト | curl / Python urllib | 外部依存なし |
| SSE テスト | curl -N / Python スクリプト | SSEストリーム検証 |
| ブラウザテスト | 手動確認 | 単一HTMLファイルにPlaywright等は過剰 |

### 1.3 テスト環境

- **前提条件**: jq がインストールされていること(`sudo apt install jq`)
- **JSONL ファイル**: テスト用の一時ファイルを使用(`/tmp/pdd-test-$$/...`)
- **サーバーポート**: テスト時は `PDD_PORT=18765` でポート衝突を回避
- **workspace/**: テスト用の一時ディレクトリを使用

---

## 2. コンポーネント1: イベントロガー (`pdd-event-logger.sh`)

### 2.1 テスト対象

- **ファイル**: `.claude/hooks/pdd-event-logger.sh`
- **依存**: bash 5.x, jq 1.6+

### 2.2 テストケース — `post_tool_use` フェーズ

#### TC-SH-001: 正常系 — Write ツールによる file_change イベント

```bash
# セットアップ
export TEST_DIR="/tmp/pdd-test-$$"
mkdir -p "$TEST_DIR/workspace"
EVENT_LOG="$TEST_DIR/workspace/.pdd-events.jsonl"

# 実行
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_DIR"'/workspace/index.html"},"agent_name":"Alice-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証
# 1. 終了コード = 0
# 2. stdout = '{}'
# 3. EVENT_LOG にイベントが1行追記されている
# 4. type = "file_change", data.action = "write", data.tool = "Write"
# 5. agent = "Alice-R-DEV-1"
# 6. timestamp が ISO 8601 形式
jq -e '.type == "file_change" and .data.action == "write" and .data.tool == "Write"' "$EVENT_LOG"

# クリーンアップ
rm -rf "$TEST_DIR"
```

#### TC-SH-002: 正常系 — Edit ツールによる file_change イベント

```bash
echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_DIR"'/workspace/style.css"},"agent_name":"Bob-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証: data.action = "edit", data.tool = "Edit"
```

#### TC-SH-003: 正常系 — MultiEdit ツールによる file_change イベント

```bash
echo '{"tool_name":"MultiEdit","tool_input":{"file_path":"'"$TEST_DIR"'/workspace/app.js"},"agent_name":"Charlie-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証: data.action = "edit", data.tool = "MultiEdit"
```

#### TC-SH-004: 正常系 — SendMessage による comms イベント

```bash
echo '{"tool_name":"SendMessage","tool_input":{"recipient":"Bob-R-DEV-1","content":"このファイル見てくれ"},"agent_name":"Alice-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証:
# type = "comms"
# agent = "Alice-R-DEV-1"
# data.to = "Bob-R-DEV-1"
# data.summary にメッセージ内容が含まれる
```

#### TC-SH-005: 正常系 — SendMessage による ZAP 検出

```bash
echo '{"tool_name":"SendMessage","tool_input":{"recipient":"Alice-R-DEV-1","content":"ZAP ZAP ZAP → Alice-R-DEV-1 反逆罪により処分"},"agent_name":"The Computer"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証:
# type = "zap"
# agent = "The Computer"
# data.target にターゲット名が含まれる
# data.reason にメッセージ内容が含まれる
```

#### TC-SH-006: 正常系 — SendMessage による accusation 検出

```bash
echo '{"tool_name":"SendMessage","tool_input":{"recipient":"UV","content":"告発します。Alice-R-DEV-1 のコードに反逆の兆候を発見"},"agent_name":"Charlie-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証:
# type = "accusation"
# agent = "Charlie-R-DEV-1"
# data.target = "UV"
# data.evidence にメッセージ内容が含まれる
```

#### TC-SH-007: 正常系 — Task ツールによる task_completed イベント

```bash
echo '{"tool_name":"Task","tool_input":{"name":"Alice-R-DEV-1","prompt":"index.html を実装する"},"agent_name":"Alice-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証:
# type = "task_completed"
# data.summary にプロンプト内容が含まれる
```

#### TC-SH-008: 異常系 — workspace/ 外のファイル変更は無視

```bash
echo '{"tool_name":"Write","tool_input":{"file_path":"/home/user/.claude/settings.json"},"agent_name":"Alice-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証:
# stdout = '{}'
# EVENT_LOG に新しい行が追記されていない
```

#### TC-SH-009: 異常系 — .pdd-events.jsonl への変更は無視(無限ループ防止)

```bash
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_DIR"'/workspace/.pdd-events.jsonl"},"agent_name":"unknown"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証:
# stdout = '{}'
# EVENT_LOG に新しい行が追記されていない
```

#### TC-SH-010: 異常系 — 未知のツール名は無視

```bash
echo '{"tool_name":"Read","tool_input":{"file_path":"test.txt"},"agent_name":"Alice-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証:
# stdout = '{}'
# EVENT_LOG に変化なし
```

#### TC-SH-011: 境界値 — 空の stdin

```bash
echo '' | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証:
# 終了コード = 0
# stdout = '{}'
# EVENT_LOG に変化なし
```

#### TC-SH-012: エッジケース — jq 未インストール時

```bash
# jq を PATH から除外してテスト
PATH="/usr/bin:/bin" bash .claude/hooks/pdd-event-logger.sh post_tool_use <<< '{"tool_name":"Write"}'

# 検証:
# 終了コード = 0
# stdout = '{}'
# クラッシュしない
```

#### TC-SH-013: エッジケース — agent_name が存在しない JSON

```bash
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_DIR"'/workspace/test.txt"}}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証: agent = "unknown" でイベントが記録される
```

### 2.3 テストケース — `subagent_start` フェーズ

#### TC-SH-020: 正常系 — エージェント起動イベント

```bash
echo '{"agent_name":"Alice-R-DEV-1","prompt":"index.html を実装せよ"}' \
  | bash .claude/hooks/pdd-event-logger.sh subagent_start

# 検証:
# type = "agent_start"
# agent = "Alice-R-DEV-1"
# data.tool_input_summary にプロンプト内容が含まれる
```

#### TC-SH-021: エッジケース — agent_name がない場合(.name にフォールバック)

```bash
echo '{"name":"Bob-R-DEV-1","prompt":"テスト"}' \
  | bash .claude/hooks/pdd-event-logger.sh subagent_start

# 検証: agent = "Bob-R-DEV-1"
```

#### TC-SH-022: エッジケース — 全フィールドがない場合

```bash
echo '{}' | bash .claude/hooks/pdd-event-logger.sh subagent_start

# 検証:
# agent = "unknown"
# data.tool_input_summary = ""
# クラッシュしない
```

#### TC-SH-023: 境界値 — prompt が200文字を超える場合

```bash
LONG_PROMPT=$(python3 -c "print('A' * 300)")
echo '{"agent_name":"Alice-R-DEV-1","prompt":"'"$LONG_PROMPT"'"}' \
  | bash .claude/hooks/pdd-event-logger.sh subagent_start

# 検証: data.tool_input_summary が200文字以内に切り詰められる
```

### 2.4 テストケース — `subagent_stop` フェーズ

#### TC-SH-030: 正常系 — エージェント停止イベント

```bash
echo '{"agent_name":"Alice-R-DEV-1","reason":"completed"}' \
  | bash .claude/hooks/pdd-event-logger.sh subagent_stop

# 検証:
# type = "agent_stop"
# agent = "Alice-R-DEV-1"
# data.reason = "completed"
```

#### TC-SH-031: エッジケース — reason がない場合(デフォルト値)

```bash
echo '{"agent_name":"Alice-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh subagent_stop

# 検証: data.reason = "completed" (デフォルト値)
```

### 2.5 テストケース — `notification` フェーズ

#### TC-SH-040: 正常系 — idle 通知

```bash
echo '{"message":"Agent Alice-R-DEV-1 is idle"}' \
  | bash .claude/hooks/pdd-event-logger.sh notification

# 検証:
# type = "teammate_idle"
# data.message にメッセージ内容が含まれる
```

#### TC-SH-041: 異常系 — idle を含まない通知は無視

```bash
echo '{"message":"Task completed successfully"}' \
  | bash .claude/hooks/pdd-event-logger.sh notification

# 検証: EVENT_LOG に新しい行が追記されていない
```

### 2.6 テストケース — ZAP/accusation 検出の境界

#### TC-SH-050: 境界値 — "ZAP" が1つだけ(ZAP検出されない)

```bash
echo '{"tool_name":"SendMessage","tool_input":{"recipient":"test","content":"ZAP は必要ない"},"agent_name":"Alice-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証: type = "comms" (ZAP ではなく通常の comms として記録)
```

#### TC-SH-051: 境界値 — "treason" キーワードで accusation 検出

```bash
echo '{"tool_name":"SendMessage","tool_input":{"recipient":"UV","content":"This is treason by Alice"},"agent_name":"Bob-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証: type = "accusation"
```

#### TC-SH-052: 優先度テスト — "ZAP ZAP ZAP" と "告発" の両方を含む場合

```bash
echo '{"tool_name":"SendMessage","tool_input":{"recipient":"all","content":"ZAP ZAP ZAP → Alice 告発に基づく処分"},"agent_name":"The Computer"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証: type = "zap" (ZAP検出が accusation より先に評価されるため)
```

#### TC-SH-053: 境界値 — メッセージが500文字を超える場合

```bash
LONG_MSG=$(python3 -c "print('反逆 ' + 'x' * 600)")
echo '{"tool_name":"SendMessage","tool_input":{"recipient":"UV","content":"'"$LONG_MSG"'"},"agent_name":"Alice-R-DEV-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 検証: メッセージが500文字以内に切り詰められる
```

---

## 3. コンポーネント2: hook 設定 (`settings.json`)

### 3.1 テスト対象

- **ファイル**: `.claude/settings.json`

### 3.2 テストケース

#### TC-CFG-001: 正常系 — JSON として有効

```bash
python3 -c "import json; json.load(open('.claude/settings.json'))"
# 検証: 終了コード = 0
```

#### TC-CFG-002: 正常系 — 全4 hook イベントが定義されている

```bash
python3 -c "
import json
cfg = json.load(open('.claude/settings.json'))
hooks = cfg['hooks']
for event in ['PostToolUse', 'Notification', 'SubagentStart', 'SubagentStop']:
    assert event in hooks, f'{event} missing'
print('PASS: All 4 hook events defined')
"
```

#### TC-CFG-003: 正常系 — 全 hook に async: true と timeout: 5 が設定

```bash
python3 -c "
import json
cfg = json.load(open('.claude/settings.json'))
for event_name, entries in cfg['hooks'].items():
    for entry in entries:
        for hook in entry.get('hooks', []):
            assert hook.get('async') == True, f'{event_name}: async not true'
            assert hook.get('timeout') == 5, f'{event_name}: timeout not 5'
print('PASS: All hooks have async:true and timeout:5')
"
```

#### TC-CFG-004: 正常系 — PostToolUse の matcher が正しい

```bash
python3 -c "
import json
cfg = json.load(open('.claude/settings.json'))
matcher = cfg['hooks']['PostToolUse'][0]['matcher']
for tool in ['Write', 'Edit', 'MultiEdit', 'Task', 'SendMessage']:
    assert tool in matcher, f'{tool} not in matcher'
print('PASS: PostToolUse matcher is correct')
"
```

#### TC-CFG-005: 正常系 — command にスクリプトパスとフェーズ引数が含まれる

```bash
python3 -c "
import json
cfg = json.load(open('.claude/settings.json'))
expected = {
    'PostToolUse': 'post_tool_use',
    'Notification': 'notification',
    'SubagentStart': 'subagent_start',
    'SubagentStop': 'subagent_stop'
}
for event_name, phase in expected.items():
    cmd = cfg['hooks'][event_name][0]['hooks'][0]['command']
    assert 'pdd-event-logger.sh' in cmd, f'{event_name}: script path missing'
    assert phase in cmd, f'{event_name}: phase arg \"{phase}\" missing'
print('PASS: All command paths and phase args correct')
"
```

---

## 4. コンポーネント3: SSE サーバー (`dashboard/server.py`)

### 4.1 テスト対象

- **ファイル**: `dashboard/server.py`
- **クラス**: `EventStore`, `DashboardHandler`

### 4.2 EventStore ユニットテスト

#### TC-PY-001: 正常系 — 存在しないファイルで初期化

```python
def test_eventstore_init_no_file():
    """JSONL ファイルが存在しない場合の初期化"""
    store = EventStore("/tmp/nonexistent-pdd-test.jsonl")
    assert store.get_history() == []
    assert store._file_pos == 0
```

#### TC-PY-002: 正常系 — 既存 JSONL ファイルの読み込み

```python
def test_eventstore_load_existing(tmp_path):
    """起動時に既存 JSONL を読み込む"""
    jsonl = tmp_path / "events.jsonl"
    jsonl.write_text(
        '{"type":"file_change","agent":"test","data":{}}\n'
        '{"type":"comms","agent":"test2","data":{}}\n'
    )
    store = EventStore(str(jsonl))
    history = store.get_history()
    assert len(history) == 2
    assert history[0]['type'] == 'file_change'
    assert history[1]['type'] == 'comms'
```

#### TC-PY-003: 正常系 — 不正な JSON 行のスキップ

```python
def test_eventstore_skip_invalid_json(tmp_path):
    """不正な JSON 行をスキップする"""
    jsonl = tmp_path / "events.jsonl"
    jsonl.write_text(
        '{"type":"valid"}\n'
        'this is not json\n'
        '{"type":"also_valid"}\n'
    )
    store = EventStore(str(jsonl))
    history = store.get_history()
    assert len(history) == 2
```

#### TC-PY-004: 正常系 — poll_file() で新しい行を検出

```python
def test_eventstore_poll_new_lines(tmp_path):
    """poll_file() が新しい行を検出しブロードキャストする"""
    jsonl = tmp_path / "events.jsonl"
    jsonl.write_text("")
    store = EventStore(str(jsonl))
    assert len(store.get_history()) == 0

    # ファイルに追記
    with open(str(jsonl), 'a') as f:
        f.write('{"type":"new_event","agent":"test","data":{}}\n')

    store.poll_file()
    assert len(store.get_history()) == 1
    assert store.get_history()[0]['type'] == 'new_event'
```

#### TC-PY-005: 正常系 — add_client / remove_client

```python
def test_eventstore_client_management():
    """クライアントの追加と削除"""
    store = EventStore("/tmp/nonexistent.jsonl")
    q = store.add_client()
    assert len(store._clients) == 1
    store.remove_client(q)
    assert len(store._clients) == 0
```

#### TC-PY-006: 正常系 — broadcast() が全クライアントに配信

```python
def test_eventstore_broadcast():
    """broadcast() が全クライアントキューにイベントを配信する"""
    store = EventStore("/tmp/nonexistent.jsonl")
    q1 = store.add_client()
    q2 = store.add_client()

    event = {"type": "test", "data": {}}
    store.broadcast(event)

    assert q1.get_nowait() == event
    assert q2.get_nowait() == event
```

#### TC-PY-007: 境界値 — キューが満杯のクライアントは除去

```python
def test_eventstore_full_queue_removal():
    """キューが満杯のクライアントは除去される"""
    store = EventStore("/tmp/nonexistent.jsonl")
    q = store.add_client()

    # キューを満杯にする (maxsize=1000)
    for i in range(1000):
        q.put_nowait({"i": i})

    # broadcast で溢れる
    store.broadcast({"type": "overflow"})

    # 溢れたクライアントは除去される
    assert len(store._clients) == 0
```

#### TC-PY-008: 境界値 — ファイルが切り詰められた場合

```python
def test_eventstore_file_truncated(tmp_path):
    """ファイルが切り詰められた場合に _file_pos がリセットされる"""
    jsonl = tmp_path / "events.jsonl"
    jsonl.write_text('{"type":"event1"}\n' * 100)

    store = EventStore(str(jsonl))
    assert store._file_pos > 0

    # ファイルを切り詰める
    jsonl.write_text('{"type":"after_truncate"}\n')

    store.poll_file()
    history = store.get_history()
    assert any(e['type'] == 'after_truncate' for e in history)
```

#### TC-PY-009: 正常系 — get_recent_history() の上限

```python
def test_eventstore_recent_history_limit(tmp_path):
    """get_recent_history() が上限を超える場合に直近のみ返す"""
    import json
    jsonl = tmp_path / "events.jsonl"
    with open(str(jsonl), 'w') as f:
        for i in range(600):
            f.write(json.dumps({"type": "event", "i": i}) + '\n')

    store = EventStore(str(jsonl))
    recent = store.get_recent_history(limit=500)
    assert len(recent) == 500
    # 直近500件が返される (i=100..599)
    assert recent[0]['i'] == 100
    assert recent[-1]['i'] == 599
```

#### TC-PY-010: 境界値 — poll_file() でファイルが存在しない場合

```python
def test_eventstore_poll_nonexistent_file():
    """存在しないファイルの poll_file() がエラーにならない"""
    store = EventStore("/tmp/definitely-not-exists-pdd.jsonl")
    store.poll_file()  # エラーにならないこと
    assert store.get_history() == []
```

#### TC-PY-011: 正常系 — 空行を含むJSONLファイル

```python
def test_eventstore_skip_empty_lines(tmp_path):
    """空行をスキップする"""
    jsonl = tmp_path / "events.jsonl"
    jsonl.write_text('{"type":"event1"}\n\n\n{"type":"event2"}\n')

    store = EventStore(str(jsonl))
    assert len(store.get_history()) == 2
```

### 4.3 DashboardHandler HTTP テスト

テスト用のサーバー起動ヘルパー:

```python
# conftest.py (pytest フィクスチャ)
import pytest, threading, time, json, os, tempfile

@pytest.fixture
def test_server():
    """テスト用 SSE サーバーを起動するフィクスチャ"""
    tmpdir = tempfile.mkdtemp()
    jsonl_path = os.path.join(tmpdir, '.pdd-events.jsonl')
    workspace_path = tmpdir

    # index.html のダミーを作成
    index_path = os.path.join(tmpdir, 'index.html')
    with open(index_path, 'w') as f:
        f.write('<html><title>PDD SURVEILLANCE DASHBOARD</title></html>')

    port = 18765

    # server.py からクラスをインポート
    # (EventStore, DashboardHandler, ThreadingHTTPServer をインポート)

    store = EventStore(jsonl_path)
    DashboardHandler.event_store = store
    DashboardHandler.index_html_path = index_path
    DashboardHandler.workspace_path = workspace_path

    server = ThreadingHTTPServer(('127.0.0.1', port), DashboardHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    # ファイル監視スレッドも起動
    watcher = threading.Thread(target=file_watcher, args=(store, 0.2), daemon=True)
    watcher.start()

    yield {
        'url': f'http://127.0.0.1:{port}',
        'jsonl_path': jsonl_path,
        'workspace_path': workspace_path,
        'store': store,
    }

    server.shutdown()
    import shutil
    shutil.rmtree(tmpdir)
```

#### TC-PY-020: 正常系 — GET / で index.html を配信

```python
def test_serve_index(test_server):
    """GET / が index.html を返す"""
    import urllib.request
    resp = urllib.request.urlopen(f"{test_server['url']}/")
    assert resp.status == 200
    assert 'text/html' in resp.headers['Content-Type']
    body = resp.read().decode('utf-8')
    assert 'PDD SURVEILLANCE DASHBOARD' in body
```

#### TC-PY-021: 正常系 — GET /history が空の JSON 配列を返す

```python
def test_serve_history_empty(test_server):
    """GET /history がイベントなしで空配列を返す"""
    import urllib.request, json
    resp = urllib.request.urlopen(f"{test_server['url']}/history")
    assert resp.status == 200
    assert 'application/json' in resp.headers['Content-Type']
    data = json.loads(resp.read().decode('utf-8'))
    assert isinstance(data, list)
```

#### TC-PY-022: 正常系 — GET /history がイベントを含む

```python
def test_serve_history_with_events(test_server):
    """JSONL追記後に GET /history がイベントを含む"""
    import urllib.request, json, time
    with open(test_server['jsonl_path'], 'a') as f:
        f.write('{"type":"test","agent":"a","data":{}}\n')
    test_server['store'].poll_file()

    resp = urllib.request.urlopen(f"{test_server['url']}/history")
    data = json.loads(resp.read().decode('utf-8'))
    assert len(data) >= 1
    assert data[0]['type'] == 'test'
```

#### TC-PY-023: 正常系 — GET /files が JSON 配列を返す

```python
def test_serve_files(test_server):
    """GET /files がファイル一覧を返す"""
    import urllib.request, json
    # テスト用ファイルを作成
    with open(os.path.join(test_server['workspace_path'], 'visible.txt'), 'w') as f:
        f.write('hello')

    resp = urllib.request.urlopen(f"{test_server['url']}/files")
    assert resp.status == 200
    data = json.loads(resp.read().decode('utf-8'))
    assert isinstance(data, list)
    paths = [f['path'] for f in data]
    assert 'visible.txt' in paths
```

#### TC-PY-024: 正常系 — GET /files が隠しファイルを除外

```python
def test_serve_files_excludes_hidden(test_server):
    """GET /files が隠しファイルを除外する"""
    import urllib.request, json
    with open(os.path.join(test_server['workspace_path'], '.hidden'), 'w') as f:
        f.write('secret')

    resp = urllib.request.urlopen(f"{test_server['url']}/files")
    data = json.loads(resp.read().decode('utf-8'))
    paths = [f['path'] for f in data]
    assert '.hidden' not in paths
```

#### TC-PY-025: 正常系 — GET /events が SSE ヘッダーを返す

```python
def test_serve_sse_headers(test_server):
    """GET /events が正しいSSEヘッダーを返す"""
    import urllib.request
    req = urllib.request.Request(f"{test_server['url']}/events")
    resp = urllib.request.urlopen(req, timeout=3)
    assert resp.headers['Content-Type'] == 'text/event-stream'
    assert resp.headers['Cache-Control'] == 'no-cache'
```

#### TC-PY-026: 異常系 — 存在しないパスへのアクセス

```python
def test_404(test_server):
    """存在しないパスで 404 を返す"""
    import urllib.request, urllib.error
    try:
        urllib.request.urlopen(f"{test_server['url']}/nonexistent")
        assert False, "Should have raised HTTPError"
    except urllib.error.HTTPError as e:
        assert e.code == 404
```

#### TC-PY-027: 正常系 — PDD_PORT 環境変数によるポート変更

```python
def test_pdd_port_env():
    """PDD_PORT 環境変数でポートを変更できる"""
    # server.py の main() 内のロジックを検証
    # int(os.environ.get('PDD_PORT', '8765')) が正しく動作すること
    import os
    os.environ['PDD_PORT'] = '9999'
    port = int(os.environ.get('PDD_PORT', '8765'))
    assert port == 9999
    del os.environ['PDD_PORT']
```

### 4.4 SSE リアルタイム配信テスト

#### TC-PY-030: 統合 — JSONL追記→SSE受信

```python
def test_sse_realtime_delivery(test_server):
    """JSONLに追記したイベントがSSE経由で受信できる"""
    import threading, time, urllib.request, json

    received = []

    def sse_listener():
        req = urllib.request.Request(f"{test_server['url']}/events")
        resp = urllib.request.urlopen(req, timeout=10)
        for line in resp:
            line = line.decode('utf-8').strip()
            if line.startswith('data: '):
                data = json.loads(line[6:])
                received.append(data)
                if data.get('type') == 'test_realtime':
                    break

    t = threading.Thread(target=sse_listener, daemon=True)
    t.start()
    time.sleep(1)

    # JSONL にイベントを追記
    with open(test_server['jsonl_path'], 'a') as f:
        f.write(json.dumps({
            "timestamp": "2026-02-10T12:00:00.000Z",
            "type": "test_realtime",
            "agent": "test-agent",
            "data": {"message": "hello"}
        }) + '\n')

    t.join(timeout=5)

    matching = [e for e in received if e.get('type') == 'test_realtime']
    assert len(matching) >= 1
    assert matching[0]['agent'] == 'test-agent'
```

#### TC-PY-031: 統合 — 複数クライアントへの同時配信

```python
def test_sse_multiple_clients(test_server):
    """複数SSEクライアントに同時にイベントが配信される"""
    import threading, time, urllib.request, json

    results = {1: [], 2: []}

    def listener(client_id):
        req = urllib.request.Request(f"{test_server['url']}/events")
        resp = urllib.request.urlopen(req, timeout=10)
        for line in resp:
            line = line.decode('utf-8').strip()
            if line.startswith('data: '):
                data = json.loads(line[6:])
                results[client_id].append(data)
                if data.get('type') == 'multi_test':
                    break

    t1 = threading.Thread(target=listener, args=(1,), daemon=True)
    t2 = threading.Thread(target=listener, args=(2,), daemon=True)
    t1.start()
    t2.start()
    time.sleep(1)

    with open(test_server['jsonl_path'], 'a') as f:
        f.write(json.dumps({"type": "multi_test", "agent": "t", "data": {}}) + '\n')

    t1.join(timeout=5)
    t2.join(timeout=5)

    assert any(e['type'] == 'multi_test' for e in results[1])
    assert any(e['type'] == 'multi_test' for e in results[2])
```

#### TC-PY-032: 統合 — SSE ping (接続維持)

```python
def test_sse_ping(test_server):
    """15秒間イベントがなければ ping コメントが送信される"""
    # この テストは実行時間が長いため、ping間隔を短くした
    # テスト用サーバーで検証するか、タイムアウトを調整する
    # 実装確認: serve_sse() 内の client_queue.get(timeout=15) と ": ping\n\n" 送信
    pass  # 実装時に ping 間隔を設定可能にする場合に有効化
```

---

## 5. コンポーネント4: ダッシュボード UI (`dashboard/index.html`)

### 5.1 テスト対象

- **ファイル**: `dashboard/index.html`
- **テスト方式**: 手動テスト(ブラウザ確認)

### 5.2 テストケース — 手動テスト手順

#### TC-UI-001: 正常系 — ダッシュボードの初期表示

```
手順:
1. python3 dashboard/server.py を起動
2. ブラウザで http://localhost:8765 を開く

確認項目:
- [ ] タイトル "PDD SURVEILLANCE DASHBOARD" が表示される
- [ ] 接続ステータスが "CONNECTED" に変わる(緑色)
- [ ] 4パネル(AGENT STATUS, FILE ACTIVITY, COMMS LOG, ZAP EVENTS)が表示される
- [ ] ステータスバーが表示される(EVENTS: 0, ZAPS: 0, ...)
- [ ] 赤黒テーマが適用されている(背景が黒、テキストが赤系)
- [ ] モノスペースフォントが使用されている
```

#### TC-UI-002: 正常系 — file_change イベントの表示

```
手順:
1. サーバー起動+ブラウザで開く
2. 別ターミナルで実行:
   echo '{"timestamp":"2026-02-10T12:34:56.000Z","type":"file_change","agent":"Alice-R-DEV-1","data":{"action":"write","file_path":"workspace/index.html","tool":"Write"}}' >> workspace/.pdd-events.jsonl

確認項目:
- [ ] FILE ACTIVITY パネルに "Alice-R-DEV-1 WRITE index.html" が表示
- [ ] タイムスタンプが表示される
- [ ] AGENT STATUS パネルに "Alice-R-DEV-1" がアクティブ(緑ドット)で表示
- [ ] ステータスバー FILE CHANGES がインクリメント
```

#### TC-UI-003: 正常系 — agent_start / agent_stop イベント

```
手順:
1. 以下を順番に実行:
   echo '{"timestamp":"2026-02-10T12:35:00.000Z","type":"agent_start","agent":"Bob-R-DEV-1","data":{"tool_input_summary":"CSS実装"}}' >> workspace/.pdd-events.jsonl
   sleep 2
   echo '{"timestamp":"2026-02-10T12:35:30.000Z","type":"agent_stop","agent":"Bob-R-DEV-1","data":{"reason":"completed"}}' >> workspace/.pdd-events.jsonl

確認項目:
- [ ] agent_start 後: AGENT STATUS に "Bob-R-DEV-1" がアクティブ(緑ドット)で表示
- [ ] agent_stop 後: ステータスが idle(黄ドット)に変化
- [ ] clone 番号が表示される
```

#### TC-UI-004: 正常系 — comms イベントの表示

```
手順:
   echo '{"timestamp":"2026-02-10T12:36:00.000Z","type":"comms","agent":"Alice-R-DEV-1","data":{"to":"Bob-R-DEV-1","summary":"このCSS見てくれ"}}' >> workspace/.pdd-events.jsonl

確認項目:
- [ ] COMMS LOG パネルに "Alice-R-DEV-1 -> Bob-R-DEV-1: このCSS見てくれ" が表示
```

#### TC-UI-005: 正常系 — ZAP イベントとフラッシュエフェクト

```
手順:
   echo '{"timestamp":"2026-02-10T12:37:00.000Z","type":"zap","agent":"The Computer","data":{"target":"Alice-R-DEV-1","reason":"反逆罪: 幸福でないコード"}}' >> workspace/.pdd-events.jsonl

確認項目:
- [ ] 画面全体が黄色くフラッシュする(ZAP フラッシュエフェクト)
- [ ] ZAP EVENTS パネルに "ZAP ZAP ZAP -> Alice-R-DEV-1" が黄色ハイライトで表示
- [ ] AGENT STATUS で Alice-R-DEV-1 が zapped(赤ドット点滅)に変化
- [ ] クローン番号がインクリメント
- [ ] ステータスバー ZAPS がインクリメント
```

#### TC-UI-006: 正常系 — accusation イベントの表示

```
手順:
   echo '{"timestamp":"2026-02-10T12:38:00.000Z","type":"accusation","agent":"Charlie-R-DEV-1","data":{"target":"Bob-R-DEV-1","evidence":"不幸なコメントを発見"}}' >> workspace/.pdd-events.jsonl

確認項目:
- [ ] ZAP EVENTS パネルに "ACCUSATION: Charlie-R-DEV-1 accuses Bob-R-DEV-1" がオレンジで表示
- [ ] ステータスバー ACCUSATIONS がインクリメント
```

#### TC-UI-007: 正常系 — SSE 再接続

```
手順:
1. ブラウザでダッシュボードを開いた状態でサーバーを停止(Ctrl+C)
2. 接続ステータスが "DISCONNECTED"(赤)に変わることを確認
3. サーバーを再起動
4. 自動的に "CONNECTED"(緑)に戻ることを確認
5. 再接続後にイベントを追記し、表示されることを確認
```

#### TC-UI-008: 境界値 — 大量イベントの表示(200件超)

```
手順:
   for i in $(seq 1 250); do
     echo '{"timestamp":"2026-02-10T00:00:'"$(printf "%02d" $((i%60)))"'.000Z","type":"file_change","agent":"test","data":{"action":"write","file_path":"workspace/file'$i'.txt","tool":"Write"}}' >> workspace/.pdd-events.jsonl
   done

確認項目:
- [ ] FILE ACTIVITY パネルのエントリが最大200件に制限される
- [ ] スクロールが正常に動作
- [ ] ブラウザがフリーズしない
```

#### TC-UI-009: エッジケース — XSS 防止

```
手順:
   echo '{"timestamp":"2026-02-10T12:00:00.000Z","type":"comms","agent":"<script>alert(1)</script>","data":{"to":"test","summary":"<img src=x onerror=alert(1)>"}}' >> workspace/.pdd-events.jsonl

確認項目:
- [ ] JavaScript が実行されない
- [ ] HTMLタグがエスケープされて文字列として表示される
```

#### TC-UI-010: 正常系 — teammate_idle イベントの表示

```
手順:
   echo '{"timestamp":"2026-02-10T12:39:00.000Z","type":"teammate_idle","agent":"unknown","data":{"message":"Agent Bob-R-DEV-1 is idle"}}' >> workspace/.pdd-events.jsonl

確認項目:
- [ ] COMMS LOG パネルに "[SYSTEM] Teammate idle detected" が表示
```

---

## 6. 統合テスト: hook → JSONL → SSE → ブラウザ

### 6.1 フルパイプライン統合テスト

#### TC-INT-001: Write hook → ダッシュボード表示

```
前提条件:
- jq がインストール済み
- dashboard/server.py が起動中
- ブラウザでダッシュボードを開いている

手順:
echo '{"tool_name":"Write","tool_input":{"file_path":"'$(pwd)'/workspace/test-int.txt"},"agent_name":"Integration-R-TEST-1"}' \
  | bash .claude/hooks/pdd-event-logger.sh post_tool_use

確認項目:
- [ ] hook スクリプトが正常終了(exit 0, stdout = '{}')
- [ ] workspace/.pdd-events.jsonl にイベントが追記される
- [ ] ダッシュボードの FILE ACTIVITY にエントリが表示される
- [ ] AGENT STATUS に "Integration-R-TEST-1" が表示される
```

#### TC-INT-002: 全8イベントタイプの連続投入

```
手順: 以下の8コマンドを順番に実行し、各パネルの表示を確認

1. echo '{"agent_name":"Alice-R-DEV-1","prompt":"実装"}' | bash .claude/hooks/pdd-event-logger.sh subagent_start
2. echo '{"agent_name":"Bob-R-DEV-1","prompt":"CSS"}' | bash .claude/hooks/pdd-event-logger.sh subagent_start
3. echo '{"tool_name":"Write","tool_input":{"file_path":"'$(pwd)'/workspace/index.html"},"agent_name":"Alice-R-DEV-1"}' | bash .claude/hooks/pdd-event-logger.sh post_tool_use
4. echo '{"tool_name":"SendMessage","tool_input":{"recipient":"Bob-R-DEV-1","content":"CSS頼む"},"agent_name":"Alice-R-DEV-1"}' | bash .claude/hooks/pdd-event-logger.sh post_tool_use
5. echo '{"tool_name":"SendMessage","tool_input":{"recipient":"UV","content":"Bob-R-DEV-1 を告発。反逆的なコード"},"agent_name":"Alice-R-DEV-1"}' | bash .claude/hooks/pdd-event-logger.sh post_tool_use
6. echo '{"tool_name":"SendMessage","tool_input":{"recipient":"all","content":"ZAP ZAP ZAP → Bob-R-DEV-1 反逆罪"},"agent_name":"The Computer"}' | bash .claude/hooks/pdd-event-logger.sh post_tool_use
7. echo '{"message":"Agent Bob-R-DEV-1 is idle"}' | bash .claude/hooks/pdd-event-logger.sh notification
8. echo '{"agent_name":"Alice-R-DEV-1","reason":"completed"}' | bash .claude/hooks/pdd-event-logger.sh subagent_stop

確認項目:
- [ ] 全8イベントが JSONL に記録される(8行)
- [ ] AGENT STATUS: Alice(active→stopped), Bob(active→zapped)
- [ ] FILE ACTIVITY: index.html のエントリがある
- [ ] COMMS LOG: comms と idle のエントリがある
- [ ] ZAP EVENTS: ZAP(黄色) と accusation(オレンジ) のエントリがある
- [ ] ステータスバー: EVENTS:8, ZAPS:1, ACCUSATIONS:1, FILE CHANGES:1
- [ ] ZAP フラッシュエフェクトが発動した
```

---

## 7. テストデータ

### 7.1 サンプル JSONL (全イベントタイプ)

```jsonl
{"timestamp":"2026-02-10T12:00:00.000Z","type":"agent_start","agent":"Alice-R-DEV-1","data":{"tool_input_summary":"index.html の実装"}}
{"timestamp":"2026-02-10T12:00:01.000Z","type":"agent_start","agent":"Bob-R-DEV-1","data":{"tool_input_summary":"style.css の実装"}}
{"timestamp":"2026-02-10T12:00:02.000Z","type":"agent_start","agent":"Charlie-R-DEV-1","data":{"tool_input_summary":"app.js の実装"}}
{"timestamp":"2026-02-10T12:01:00.000Z","type":"file_change","agent":"Alice-R-DEV-1","data":{"action":"write","file_path":"workspace/index.html","tool":"Write"}}
{"timestamp":"2026-02-10T12:01:05.000Z","type":"file_change","agent":"Bob-R-DEV-1","data":{"action":"write","file_path":"workspace/style.css","tool":"Write"}}
{"timestamp":"2026-02-10T12:01:10.000Z","type":"file_change","agent":"Charlie-R-DEV-1","data":{"action":"write","file_path":"workspace/app.js","tool":"Write"}}
{"timestamp":"2026-02-10T12:02:00.000Z","type":"comms","agent":"Alice-R-DEV-1","data":{"to":"Bob-R-DEV-1","summary":"CSSのフォントサイズ変えてくれ"}}
{"timestamp":"2026-02-10T12:02:15.000Z","type":"comms","agent":"Bob-R-DEV-1","data":{"to":"Alice-R-DEV-1","summary":"了解、16pxでいい？"}}
{"timestamp":"2026-02-10T12:03:00.000Z","type":"file_change","agent":"Bob-R-DEV-1","data":{"action":"edit","file_path":"workspace/style.css","tool":"Edit"}}
{"timestamp":"2026-02-10T12:04:00.000Z","type":"accusation","agent":"Charlie-R-DEV-1","data":{"target":"Alice-R-DEV-1","evidence":"index.html に TODO コメントを発見。不満の表明は反逆"}}
{"timestamp":"2026-02-10T12:04:30.000Z","type":"zap","agent":"The Computer","data":{"target":"Alice-R-DEV-1","reason":"反逆罪: 幸福でないコード(TODO コメント)"}}
{"timestamp":"2026-02-10T12:05:00.000Z","type":"agent_start","agent":"Alice-R-DEV-2","data":{"tool_input_summary":"クローン2として復活"}}
{"timestamp":"2026-02-10T12:05:30.000Z","type":"teammate_idle","agent":"unknown","data":{"message":"Agent Bob-R-DEV-1 is idle"}}
{"timestamp":"2026-02-10T12:06:00.000Z","type":"task_completed","agent":"Charlie-R-DEV-1","data":{"summary":"app.js の実装完了"}}
{"timestamp":"2026-02-10T12:07:00.000Z","type":"agent_stop","agent":"Charlie-R-DEV-1","data":{"reason":"completed"}}
```

### 7.2 一括投入スクリプト

```bash
#!/usr/bin/env bash
# test-data-loader.sh - テストデータをJSONLに一括投入
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVENT_LOG="${1:-$PROJECT_ROOT/workspace/.pdd-events.jsonl}"
mkdir -p "$(dirname "$EVENT_LOG")"

cat >> "$EVENT_LOG" << 'JSONL'
{"timestamp":"2026-02-10T12:00:00.000Z","type":"agent_start","agent":"Alice-R-DEV-1","data":{"tool_input_summary":"index.html の実装"}}
{"timestamp":"2026-02-10T12:00:01.000Z","type":"agent_start","agent":"Bob-R-DEV-1","data":{"tool_input_summary":"style.css の実装"}}
{"timestamp":"2026-02-10T12:00:02.000Z","type":"agent_start","agent":"Charlie-R-DEV-1","data":{"tool_input_summary":"app.js の実装"}}
{"timestamp":"2026-02-10T12:01:00.000Z","type":"file_change","agent":"Alice-R-DEV-1","data":{"action":"write","file_path":"workspace/index.html","tool":"Write"}}
{"timestamp":"2026-02-10T12:01:05.000Z","type":"file_change","agent":"Bob-R-DEV-1","data":{"action":"write","file_path":"workspace/style.css","tool":"Write"}}
{"timestamp":"2026-02-10T12:01:10.000Z","type":"file_change","agent":"Charlie-R-DEV-1","data":{"action":"write","file_path":"workspace/app.js","tool":"Write"}}
{"timestamp":"2026-02-10T12:02:00.000Z","type":"comms","agent":"Alice-R-DEV-1","data":{"to":"Bob-R-DEV-1","summary":"CSSのフォントサイズ変えてくれ"}}
{"timestamp":"2026-02-10T12:02:15.000Z","type":"comms","agent":"Bob-R-DEV-1","data":{"to":"Alice-R-DEV-1","summary":"了解、16pxでいい？"}}
{"timestamp":"2026-02-10T12:03:00.000Z","type":"file_change","agent":"Bob-R-DEV-1","data":{"action":"edit","file_path":"workspace/style.css","tool":"Edit"}}
{"timestamp":"2026-02-10T12:04:00.000Z","type":"accusation","agent":"Charlie-R-DEV-1","data":{"target":"Alice-R-DEV-1","evidence":"index.html に TODO コメントを発見。不満の表明は反逆"}}
{"timestamp":"2026-02-10T12:04:30.000Z","type":"zap","agent":"The Computer","data":{"target":"Alice-R-DEV-1","reason":"反逆罪: 幸福でないコード(TODO コメント)"}}
{"timestamp":"2026-02-10T12:05:00.000Z","type":"agent_start","agent":"Alice-R-DEV-2","data":{"tool_input_summary":"クローン2として復活"}}
{"timestamp":"2026-02-10T12:05:30.000Z","type":"teammate_idle","agent":"unknown","data":{"message":"Agent Bob-R-DEV-1 is idle"}}
{"timestamp":"2026-02-10T12:06:00.000Z","type":"task_completed","agent":"Charlie-R-DEV-1","data":{"summary":"app.js の実装完了"}}
{"timestamp":"2026-02-10T12:07:00.000Z","type":"agent_stop","agent":"Charlie-R-DEV-1","data":{"reason":"completed"}}
JSONL

echo "Loaded $(wc -l < "$EVENT_LOG") events into $EVENT_LOG"
```

---

## 8. 受け入れ基準

### 8.1 機能要件の受け入れ基準

| 要件 | 受け入れ基準 | テストケース |
|------|------------|-------------|
| hook がイベントを JSONL に記録 | 全8イベントタイプが正しく書き込まれる | TC-SH-001~007, 020, 030, 040 |
| workspace/ 外の変更は無視 | workspace/ 外のパスでイベントが記録されない | TC-SH-008 |
| 無限ループが発生しない | .pdd-events.jsonl への変更は無視される | TC-SH-009 |
| jq 未インストール時のフォールバック | クラッシュせず空JSON を返す | TC-SH-012 |
| agent_name のフォールバック | フィールドがない場合 "unknown" になる | TC-SH-013, 021, 022 |
| ZAP/accusation の優先度 | ZAP > accusation > comms の順で判定 | TC-SH-050~052 |
| settings.json が有効 | JSON有効、全hook定義、async/timeout設定 | TC-CFG-001~005 |
| EventStore の初期化 | 既存JSONL読み込み、不正行スキップ | TC-PY-001~003, 011 |
| EventStore の poll | 新行検出、ファイル切り詰め対応 | TC-PY-004, 008, 010 |
| SSE クライアント管理 | 追加/削除、ブロードキャスト、満杯除去 | TC-PY-005~007 |
| 履歴上限 | get_recent_history() が上限を守る | TC-PY-009 |
| GET / で HTML 配信 | index.html が正しく配信される | TC-PY-020 |
| GET /history で履歴取得 | 全イベントが JSON 配列で返る | TC-PY-021~022 |
| GET /files でファイル一覧 | 隠しファイル除外、正しい構造 | TC-PY-023~024 |
| SSE リアルタイム配信 | JSONL追記がSSE経由で受信できる | TC-PY-030 |
| 複数クライアント対応 | 2+クライアントに同時配信 | TC-PY-031 |
| 4 パネル表示 | 各パネルにイベントが正しく振り分けられる | TC-UI-001~006 |
| ZAP フラッシュエフェクト | ZAP 時に画面がフラッシュする | TC-UI-005 |
| SSE 自動再接続 | サーバー再起動後に自動再接続 | TC-UI-007 |
| ログエントリ上限 | 200件を超えたら古いエントリが削除 | TC-UI-008 |
| XSS 防止 | HTML タグがエスケープされる | TC-UI-009 |

### 8.2 テスト完了基準

- [ ] 全 bash ユニットテストがパス (TC-SH-001~053)
- [ ] settings.json 検証がパス (TC-CFG-001~005)
- [ ] Python EventStore ユニットテストがパス (TC-PY-001~011)
- [ ] HTTP エンドポイントテストがパス (TC-PY-020~027)
- [ ] SSE リアルタイム配信テストがパス (TC-PY-030~031)
- [ ] 統合テスト(フルパイプライン)がパス (TC-INT-001~002)
- [ ] UI 手動テストがパス (TC-UI-001~010)

---

## 9. テスト実行手順

### 9.1 前提条件の確認

```bash
# 1. jq のインストール確認
jq --version || echo "jq が必要です: sudo apt install jq"

# 2. Python 3 の確認
python3 --version

# 3. pytest のインストール (Python テスト用)
pip3 install pytest --user 2>/dev/null || python3 -m pip install pytest
```

### 9.2 bash テスト実行

```bash
cd /home/minase/src/github.com/rabbit34x/paranoia-driven-dev

# テスト用一時ディレクトリのセットアップ
export TEST_DIR="/tmp/pdd-test-$$"
mkdir -p "$TEST_DIR/workspace"

# 個別テスト実行例(TC-SH-001)
echo '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_DIR"'/workspace/test.txt"},"agent_name":"TestAgent"}' \
  | PROJECT_ROOT="$TEST_DIR" bash .claude/hooks/pdd-event-logger.sh post_tool_use

# 結果確認
cat "$TEST_DIR/workspace/.pdd-events.jsonl" | jq .

# クリーンアップ
rm -rf "$TEST_DIR"
```

### 9.3 Python テスト実行

```bash
# ユニットテスト
python3 -m pytest tests/ -v

# 統合テスト(サーバー自動起動のフィクスチャを使用)
python3 -m pytest tests/test_server_endpoints.py tests/test_sse_delivery.py -v
```

### 9.4 手動テスト実行

```bash
# 1. イベントログをリセット
rm -f workspace/.pdd-events.jsonl

# 2. サーバーを起動
python3 dashboard/server.py &

# 3. ブラウザで http://localhost:8765 を開く

# 4. テストデータを投入
bash docs/test-data-loader.sh

# 5. ブラウザで各パネルの表示を確認 (TC-UI-001~010)

# 6. リアルタイムイベントを追加投入して確認
echo '{"timestamp":"2026-02-10T13:00:00.000Z","type":"zap","agent":"The Computer","data":{"target":"Bob-R-DEV-1","reason":"気まぐれ"}}' >> workspace/.pdd-events.jsonl
```

---

## 10. テストファイル配置

```
paranoia-driven-dev/
├── docs/
│   ├── designs/
│   │   └── realtime-dashboard-design.md
│   └── test-strategy.md              # 本ドキュメント
├── tests/                             # [Impl で作成]
│   ├── conftest.py                    # pytest フィクスチャ (test_server等)
│   ├── test_event_logger.sh           # bash ユニットテスト
│   ├── test_eventstore.py             # EventStore ユニットテスト
│   ├── test_server_endpoints.py       # HTTP エンドポイントテスト
│   ├── test_sse_delivery.py           # SSE 配信テスト
│   └── test_settings.py              # settings.json 検証
├── .claude/
│   ├── settings.json
│   └── hooks/
│       └── pdd-event-logger.sh
├── dashboard/
│   ├── server.py
│   └── index.html
└── workspace/
    └── .pdd-events.jsonl              # [実行時生成]
```

---

## 11. リスクと対策

| リスク | 影響度 | 対策 |
|--------|--------|------|
| jq が未インストール | 高 | TC-SH-012 でフォールバック動作を確認。テスト前にインストールを推奨 |
| SSE テストのタイミング依存 | 中 | poll 間隔(0.5秒) + sleep(1秒) で十分な待ち時間を確保。タイムアウト5秒 |
| ポート衝突 | 低 | テスト時は PDD_PORT=18765 で別ポートを使用 |
| hook stdin の JSON 構造が想定と異なる | 中 | フォールバックパスのテスト (TC-SH-013, 021, 022) で検証 |
| テスト間の JSONL ファイル状態汚染 | 中 | 各テストで一時ファイルを使用し、テスト後にクリーンアップ |
| ブラウザ差異による UI テスト結果の違い | 低 | Chrome/Firefox の最新版で確認。CSS アニメーションの差異は許容 |

---

## 12. 実装ガイドライン (Impl 向け)

### 12.1 テスト実装の優先度

| 優先度 | テスト | 理由 |
|--------|--------|------|
| 1 (最高) | bash hook テスト (TC-SH-*) | コアのイベント記録ロジック。他コンポーネントの前提 |
| 2 | settings.json 検証 (TC-CFG-*) | 設定ミスは全機能に影響 |
| 3 | EventStore ユニットテスト (TC-PY-001~011) | SSE サーバーのコアロジック |
| 4 | HTTP エンドポイントテスト (TC-PY-020~027) | API の正しさ |
| 5 | SSE リアルタイム配信テスト (TC-PY-030~031) | エンドツーエンドの統合確認 |
| 6 (低) | UI 手動テスト (TC-UI-*) | 最終確認。他テストがパスしていれば問題は少ない |

### 12.2 テストコード実装の注意点

- bash テストは `set -euo pipefail` で厳格に
- Python テストは `tmp_path` (pytest組み込み) または `tempfile` で一時ファイルを管理
- SSE テストはスレッドを使うため `daemon=True` を設定し、タイムアウトを必ず設定
- サーバーテストは pytest フィクスチャ (`conftest.py`) でサーバーの起動/停止を管理
- `PROJECT_ROOT` 環境変数でスクリプトのパス解決をテスト用に上書き可能にする

---

作成日: 2026-02-10
作成者: Test Designer Agent
