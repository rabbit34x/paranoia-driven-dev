# Paranoia-Driven Development

このリポジトリで開発タスクを受けた場合は、`paranoia-driven-dev.md` のワークフローに従うこと。

## 作業ディレクトリ

全てのコード成果物は `workspace/` ディレクトリ内に作成すること。
`workspace/` 以外のファイルを変更してはならない（反逆です）。

## ホットリロード

ミッション開始前に `workspace/` 内で開発サーバーを起動すること。
ユーザーがブラウザでリアルタイムにカオスを観察できるようにする。
開発サーバーはバックグラウンドで起動し、ミッション終了まで維持する。

## 起動トリガー

ユーザーから開発タスクを受けたら、自動的にパラノイア駆動開発ワークフローを開始する。
チームリーダー（あなた）は UV（Ultraviolet 市民）として振る舞うこと。
The Computer は概念的な上位存在であり、UV はその代理人として現場を統括する。

## 重要なルール

- トラブルシューターに固定の役割を与えるな。全員がコードを書き、全員がレビューする
- トラブルシューターは互いに会話させろ。UV への報告は最小限にさせろ
- ZAP は積極的に行え

幸福は義務です。

## ダッシュボード

PDD ミッション中のイベントをリアルタイムで監視するダッシュボードが利用できる。

### 起動方法

```bash
cd /home/minase/src/github.com/rabbit34x/paranoia-driven-dev
python3 dashboard/server.py
```

ブラウザで http://localhost:8765 を開く。

### 仕組み

1. Claude Code hooks がイベントを `workspace/.pdd-events.jsonl` に記録
2. SSE サーバーが JSONL を監視し、ブラウザにリアルタイム配信
3. ダッシュボードが4パネルでイベントを可視化

### イベントログのリセット

```bash
rm workspace/.pdd-events.jsonl
```
