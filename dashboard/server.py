#!/usr/bin/env python3
# dashboard/server.py - PDD リアルタイム監視ダッシュボード SSE サーバー

import json
import os
import queue
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

# SSE クライアントキューのサイズ上限
CLIENT_QUEUE_MAXSIZE = 1000

# SSE 接続時の初期送信イベント上限
INITIAL_HISTORY_LIMIT = 500

# SA-M003 fix: インメモリイベント数上限 (メモリリーク防止)
MAX_EVENTS_IN_MEMORY = 10000


class EventStore:
    """JSONL ファイルを監視し、SSE クライアントにブロードキャストする"""

    def __init__(self, jsonl_path: str):
        self.jsonl_path = jsonl_path
        self._events: list = []  # 全イベントのインメモリキャッシュ
        self._clients: list = []  # SSE クライアント用キュー
        self._lock = threading.Lock()  # スレッドセーフ
        self._file_pos: int = 0  # ファイル読み取り位置 (バイト数)

        # 起動時に既存イベントを読み込み
        self._load_existing()

    def _load_existing(self):
        """起動時に既存の JSONL ファイルを読み込む"""
        if not os.path.exists(self.jsonl_path):
            return
        with open(self.jsonl_path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        event = json.loads(line)
                        self._events.append(event)
                    except json.JSONDecodeError:
                        pass  # 不正な行はスキップ
            self._file_pos = f.tell()

    def add_client(self):
        """新規 SSE クライアントを登録し、キューを返す"""
        q = queue.Queue(maxsize=CLIENT_QUEUE_MAXSIZE)
        with self._lock:
            self._clients.append(q)
        return q

    def remove_client(self, q):
        """切断クライアントを削除"""
        with self._lock:
            if q in self._clients:
                self._clients.remove(q)

    def broadcast(self, event: dict):
        """全クライアントにイベントを配信"""
        with self._lock:
            self._events.append(event)
            # SA-M003 fix: インメモリイベント数上限を適用 (古いイベントから削除)
            if len(self._events) > MAX_EVENTS_IN_MEMORY:
                self._events = self._events[-MAX_EVENTS_IN_MEMORY:]
            dead_clients = []
            for q in self._clients:
                try:
                    q.put_nowait(event)
                except queue.Full:
                    dead_clients.append(q)
            for q in dead_clients:
                self._clients.remove(q)

    def poll_file(self):
        """JSONL ファイルの新しい行を読み取り、ブロードキャスト"""
        if not os.path.exists(self.jsonl_path):
            return

        try:
            file_size = os.path.getsize(self.jsonl_path)
        except OSError:
            return

        # ファイルが切り詰められた場合 (ファイルサイズが減少)
        if file_size < self._file_pos:
            self._file_pos = 0

        if file_size <= self._file_pos:
            return

        with open(self.jsonl_path, 'r', encoding='utf-8') as f:
            f.seek(self._file_pos)
            for line in f:
                line = line.strip()
                if line:
                    try:
                        event = json.loads(line)
                        self.broadcast(event)
                    except json.JSONDecodeError:
                        pass
            self._file_pos = f.tell()

    def get_history(self) -> list:
        """全イベント履歴を返す"""
        with self._lock:
            return list(self._events)

    def get_recent_history(self, limit: int = INITIAL_HISTORY_LIMIT) -> list:
        """直近のイベント履歴を返す(SSE 初期送信用)"""
        with self._lock:
            if len(self._events) <= limit:
                return list(self._events)
            return list(self._events[-limit:])


class DashboardHandler(BaseHTTPRequestHandler):
    """ダッシュボード HTTP/SSE ハンドラー"""

    # クラス変数 (main() で設定)
    event_store = None
    index_html_path = ""
    workspace_path = ""

    def log_message(self, format, *args):
        """ログ出力を抑制 (不要なリクエストログを出さない)"""
        pass  # 必要に応じて有効化

    def do_GET(self):
        """GET リクエストのルーティング"""
        if self.path == '/':
            self.serve_index()
        elif self.path == '/events':
            self.serve_sse()
        elif self.path == '/history':
            self.serve_history()
        elif self.path == '/files':
            self.serve_files()
        else:
            self.send_error(404)

    def serve_index(self):
        """index.html を配信"""
        try:
            with open(self.index_html_path, 'r', encoding='utf-8') as f:
                content = f.read()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(content.encode('utf-8'))
        except FileNotFoundError:
            self.send_error(404, 'index.html not found')

    def serve_sse(self):
        """SSE ストリームを開始"""
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'keep-alive')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

        # CR-M001 fix: 履歴を先に取得してからクライアントを登録
        # これにより get_recent_history() と add_client() の間に発生するイベントの重複を防ぐ
        history_events = self.event_store.get_recent_history()
        client_queue = self.event_store.add_client()

        try:
            # 接続直後に直近の履歴イベントを送信(上限: INITIAL_HISTORY_LIMIT 件)
            for event in history_events:
                data = json.dumps(event, ensure_ascii=False)
                self.wfile.write(f"data: {data}\n\n".encode('utf-8'))
                self.wfile.flush()

            # 以降はリアルタイムイベントを配信
            while True:
                try:
                    event = client_queue.get(timeout=15)  # 15秒タイムアウト
                    data = json.dumps(event, ensure_ascii=False)
                    self.wfile.write(f"data: {data}\n\n".encode('utf-8'))
                    self.wfile.flush()
                except queue.Empty:
                    # タイムアウト -> ping 送信 (接続維持)
                    self.wfile.write(f": ping\n\n".encode('utf-8'))
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # クライアント切断
        finally:
            self.event_store.remove_client(client_queue)

    def serve_history(self):
        """過去イベントを JSON 配列で返却"""
        events = self.event_store.get_history()
        body = json.dumps(events, ensure_ascii=False)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(body.encode('utf-8'))

    def serve_files(self):
        """workspace/ ディレクトリのファイル一覧を JSON 配列で返却"""
        files = []
        if os.path.isdir(self.workspace_path):
            # CR-M004 fix: シンボリックリンクを追跡しない (セキュリティ強化)
            for root, dirs, filenames in os.walk(self.workspace_path, followlinks=False):
                # 隠しディレクトリはスキップ
                dirs[:] = [d for d in dirs if not d.startswith('.')]
                for fname in filenames:
                    # 隠しファイルはスキップ (.pdd-events.jsonl 等)
                    if fname.startswith('.'):
                        continue
                    full_path = os.path.join(root, fname)
                    rel_path = os.path.relpath(full_path, self.workspace_path)
                    try:
                        stat = os.stat(full_path)
                        files.append({
                            "path": rel_path,
                            "size": stat.st_size,
                            "modified": stat.st_mtime
                        })
                    except OSError:
                        pass
        body = json.dumps(files, ensure_ascii=False)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(body.encode('utf-8'))


def file_watcher(store: EventStore, interval: float = 0.5):
    """JSONL ファイルを定期的にポーリングするワーカースレッド"""
    while True:
        store.poll_file()
        time.sleep(interval)


def main():
    # パス解決
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    jsonl_path = os.path.join(project_root, 'workspace', '.pdd-events.jsonl')
    index_path = os.path.join(script_dir, 'index.html')
    workspace_path = os.path.join(project_root, 'workspace')

    # ポート・ホスト設定
    # SA-M001 fix: セキュリティ強化 - デフォルトを 127.0.0.1 に変更、環境変数で選択可能
    port = int(os.environ.get('PDD_PORT', '8765'))
    host = os.environ.get('PDD_HOST', '127.0.0.1')

    # EventStore 初期化
    store = EventStore(jsonl_path)

    # ハンドラーにクラス変数を設定
    DashboardHandler.event_store = store
    DashboardHandler.index_html_path = index_path
    DashboardHandler.workspace_path = workspace_path

    # ファイル監視スレッド起動
    watcher = threading.Thread(target=file_watcher, args=(store, 0.5), daemon=True)
    watcher.start()

    # HTTP サーバー起動
    server = ThreadingHTTPServer((host, port), DashboardHandler)
    print(f"PDD Dashboard: http://{host}:{port}")
    print(f"Watching: {jsonl_path}")
    print(f"Host: {host} (use PDD_HOST=0.0.0.0 to allow external connections)")
    print("Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
