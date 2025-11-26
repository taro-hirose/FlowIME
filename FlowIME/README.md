# FlowIME

macOSで文字入力時に、カーソル前の文字を見て自動的にIME（日本語/英語）を切り替えるメニューバーアプリ

## 概要

FlowIMEは、日本語と英語を混在して入力する際のIME切り替えの手間を削減するmacOSアプリケーションです。アルファベットキーを入力する際に、カーソル前の文字の種類を判定し、適切なIME状態に自動切り替えします。

## 主な機能

- **自動IME切り替え**: カーソル前の文字が日本語なら日本語IMEに、英語なら英語モードに自動切り替え
- **インテリジェントな判定**: 空白・改行・文頭では切り替えを行わず、ユーザーの現在のIME状態を維持
- **手動切り替えの尊重**: ユーザーが手動でIMEを切り替えた後は、一定期間自動判定をスキップ
- **高速入力対応**: 連続入力中は判定をスキップし、パフォーマンスを最適化

## システム構成

### ファイル構成

```
FlowIME/
├── KeyboardMonitor.swift      # キーボード入力検知
├── AccessibilityManager.swift # テキスト情報取得
├── IMEController.swift        # IME切り替え
└── FlowIMEApp.swift          # メインロジック
```

### 1. KeyboardMonitor.swift（キーボード入力検知）

- `CGEventTap`でシステム全体のキーボード入力を監視
- アルファベットキー（a-z）の入力を検知
- ショートカット（Command+◯、Option+◯など）は無視
- **Throttle機構:**
  - 最初のキー入力 → すぐに判定実行
  - その後1秒間は判定をスキップ（連続入力中は判定しない）
  - IME切り替えから1秒以内も判定をスキップ（ユーザーの手動切り替えを尊重）

### 2. AccessibilityManager.swift（テキスト情報取得）

- macOS Accessibility APIを使用
- フォーカスされているテキストフィールドから情報を取得
- **主な機能:**
  - `getFocusedElement()` - 現在フォーカス中のUI要素
  - `getDetailedInfo()` - テキスト内容、カーソル位置、カーソル前の文字

### 3. IMEController.swift（IME切り替え）

- Carbon Input Source APIを使用
- **主な機能:**
  - `switchToInputMode()` - 日本語/英語に切り替え
  - `startMonitoringInputSourceChanges()` - IME変更を監視
  - `lastInputSourceChangeTime` - 最後のIME切り替え時刻を記録（手動切り替えの検知用）

### 4. FlowIMEApp.swift（メインロジック）

- メニューバーアプリとして動作
- キーボード入力時の判定ロジックを実行

## 動作フロー

```
1. ユーザーがアルファベットキーを押す
   ↓
2. KeyboardMonitor が検知
   ↓
3. Throttle チェック:
   - 前回の判定から1秒以内？ → スキップ
   - IME切り替えから1秒以内？ → スキップ
   ↓
4. AccessibilityManager でカーソル前の文字を取得
   ↓
5. 文字の種類で判定:
   - 日本語（ひらがな/カタカナ/漢字） → 日本語IME ON
   - 英語（a-z, A-Z） → 英語モード（IME OFF）
   - 数字（0-9） → 英語モード
   - 空白・改行・記号 → 何もしない（現在のIME状態を維持）
   - 文頭（カーソル位置0） → 何もしない
   ↓
6. IMEController で切り替え実行
   ↓
7. 1秒間のクールダウン開始
```

## 判定ルール

| カーソル前の文字 | 動作 |
|---|---|
| 日本語（あ、ア、漢） | 日本語IME ON |
| 英語（a-z, A-Z） | 英語モード（IME OFF） |
| 数字（0-9） | 英語モード |
| 空白・改行・記号 | **何もしない** |
| 文頭（何もない） | **何もしない** |

## Throttle（判定スキップ）の仕組み

### 2つのクールダウン

1. **判定後のクールダウン**
   - 判定実行後1秒間は次の判定をスキップ
   - 高速タイピング中に毎回判定しないための最適化

2. **IME切り替え後のクールダウン**
   - ユーザーが手動でIMEを切り替えた後1秒間は判定をスキップ
   - ユーザーの意図した切り替えを自動判定で上書きしない

## インストール

### 必要要件

- macOS 10.15以降
- Xcode（開発時）
- アクセシビリティ権限

### ビルド方法

1. Xcodeでプロジェクトを開く
```bash
open FlowIME.xcodeproj
```

2. プロジェクトをビルド（⌘+B）

3. アプリを実行（⌘+R）

### 権限設定

初回起動時に、アクセシビリティ権限のリクエストダイアログが表示されます。

**手動で設定する場合:**
1. システム環境設定 > セキュリティとプライバシー > プライバシー > アクセシビリティ
2. 🔒をクリックして変更を許可
3. FlowIME.appを追加してチェックを入れる

**重要:** App Sandboxは無効化されています（`FlowIME.entitlements`参照）。Accessibility APIの使用に必要です。

## 使い方

1. アプリを起動すると、メニューバーに 🔄 アイコンが表示されます
2. 任意のテキストフィールドで文字を入力します
3. アルファベットキーを入力すると、自動的にIMEが切り替わります

### デバッグログ

コンソールに以下のような詳細ログが出力されます：
- `⌨️ Alphabet key pressed (code: XX), checking now` - キー入力検知
- `⏭️ Alphabet key pressed (code: XX), skipped` - 判定スキップ
- `🇯🇵 Type: Japanese → Switching to Japanese IME` - 日本語IMEに切り替え
- `🔤 Type: English → Switching to English input` - 英語モードに切り替え
- `🔣 Type: Symbol/Whitespace/Newline → No change` - 何もしない

## 技術仕様

### 使用API

- **CGEventTap**: キーボードイベントの監視
- **Accessibility API**: テキストフィールドの情報取得
- **Carbon Input Source API**: IME切り替え
- **DistributedNotificationCenter**: IME変更通知の監視

### 対応入力ソース

- 日本語: `com.apple.inputmethod.Kotoeri`（ことえり）
- 英語: `com.apple.keylayout.ABC` または `com.apple.keylayout.US`

### パフォーマンス最適化

- ポーリング方式を廃止し、イベント駆動型に変更
- Throttle機構により、不要な判定をスキップ
- 既に同じIME状態の場合は切り替えをスキップ

## トラブルシューティング

### アプリが動作しない

1. アクセシビリティ権限が付与されているか確認
2. コンソールログで `❌ Failed to create event tap` が出ていないか確認
3. アプリを再起動

### IMEが切り替わらない

1. 対応する入力ソースがインストールされているか確認（日本語、英語）
2. コンソールログで `⚠️ Japanese IME not found` などのエラーを確認
3. システム環境設定 > キーボード > 入力ソース で日本語と英語が追加されているか確認

### 判定が遅い/早すぎる

`KeyboardMonitor.swift`の`throttleInterval`を調整してください（デフォルト: 1.0秒）

```swift
private let throttleInterval: TimeInterval = 1.0  // ここを変更
```

## ライセンス

このプロジェクトは個人用途で作成されました。

## 開発履歴

- フェーズ1: Accessibility APIによるテキスト/カーソル検知
- フェーズ2: フォーカス検知とポーリング実装
- フェーズ3: IME切り替え機能の実装
- フェーズ4: イベント駆動型への移行（キーボード入力トリガー）
- フェーズ5: Throttle機構と手動切り替え検知の実装

## 今後の改善案

- [ ] App Store配布対応
- [ ] 設定画面の追加（Throttle時間の調整、判定ルールのカスタマイズ）
- [ ] 他の入力ソース対応（Google日本語入力など）
- [ ] ホットキーでの一時無効化機能
- [ ] アプリ別の有効/無効設定
