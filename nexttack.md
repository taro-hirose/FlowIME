# FlowIME 次タスクと運用メモ

このドキュメントは、現状の仕様・既知の課題・改善タスク・配布手順を簡潔にまとめたものです。配布や微調整、デバッグの指針として利用してください。

## 現状仕様（要点）
- 判定は「左文字のみ」を使用（右側は使わない）。
- 早期抑制:
  - Auto Switch OFF → 何もしない
  - 直近のユーザー手動トグル（Cmd/Ctrl+Space、JIS 英数/かな、アプリのメニュー）→ 次の1打鍵は抑制（0.3s）
  - composing（AXMarkedTextRangeあり）→ 何もしない
  - 先頭/改行直後（prev が LF/CR）→ 何もしない
- 主要判定:
  - 左が ASCII 英字/数字 → EN を希望
  - 左が日本語（ひら/カナ/漢字） → JP を希望
  - それ以外 → 中立（何もしない）
- JP→EN 切替の追加条件（日本語連打の安定性優先）:
  - 現在 JP のとき、左が ASCII でも以下のどちらかが真なら EN 許可
    - 直近ナビゲーションあり（矢印/Home/End/Page/マウスクリック/改行など）within 0.3s
    - 直近タイプからの小休止が 0.2s 超
  - どちらも満たさない場合は romaji 中とみなし抑制（reason=jpTyping）
- 安定化（AX一時的不整合対策）:
  - 切替直前に ~7ms 待ち、左文字を再取得して位置/文字が一致した場合のみ切替（不一致なら reason=unstable）
- 事前切替・再注入:
  - 事前判定で必要なら IME を切替 → 本来のキーを合成注入（元イベントは consume）
  - OS/ユーザーからの即時逆切替に対しては 0.6s の短期 enforce をかける（20ms リチェック込み）
- 入力・ナビ検出:
  - キー: keyDown/keyUp
  - ナビ: 矢印/Home/End/Page、マウスダウン、Return/Enter/Escape
  - Backspace: JP セッションカウントを調整
- 手動切替検出:
  - Cmd/Ctrl+Space、JIS 英数(102)/かな(104)、アプリのメニュー → userToggle として記録
- ログ:
  - [decide] pos=… prev=… compose=… session=… space=… → EN/JP/nil reason=…
  - ⌨️ Key: 'x'（注入後の診断）、Input source changed (programmatic/user/system)

## 既知の課題 / 観測
- 稀に AX が巨大な pos（例: 5万台）や '\\0'、'▌' などを返すケースがある
  - 現状は session/newline/neutral で無害化されるが、必要なら「不正値のときは中立」に明示的フォールバックを追加可
- macOS の「書類ごとに入力ソースを自動切り替え」が ON だと競合・逆切替が多発
  - ユーザーに OFF を案内推奨
- Helper（Login Item）登録のエラー（Invalid argument）
  - 埋め込み Helper の CFBundleIdentifier と実行時に取得する ID の不一致/署名不整合で発生しがち
  - FlowIME.app/Contents/Library/LoginItems/FlowIMEHelper.app/Contents/Info.plist の一致要確認
- FSFindFolder failed -43 の警告（環境依存・無害）

## パラメータ（微調整ポイント）
- navigateWindow（didNavigateRecently）: 0.3s（クリック/矢印/改行後に EN 許可する窓）
- idleGapForEN（小休止判定）: 0.2s（連打と区別するための最小無入力時間）
- axRecheckDelay: ~7ms（二重取得の間隔）
- enforceDuration: 0.6s（逆切替への抵抗時間）
- throttleInterval: 0.2s（診断ログ用スロットル）
- navGraceWindow/decisionDefer: 0.05s（ナビ直後の微デファ）

## 直近の改善タスク
1) Helper（Login Item）登録の修正
- 埋め込みパス存在確認、Info.plist の CFBundleIdentifier とコード内の取得結果の一致
- Helper/本体ともに同じチームIDで署名（Developer ID）

2) 改行直後の挙動再検証
- Return/Enter/Escape をナビとして扱う変更済み。newline → 1打鍵は抑制、その後 EN 許可が期待通りか確認
- 必要なら navigateWindow を 0.35〜0.4s に微増

3) AX 異常値ガードの強化（任意）
- pos が極端/prev が '\\0'・制御記号のときは neutral に退避

4) ユーザー設定
- 「JP→EN 切替を許可する条件」を選べるトグルをメニューに追加（ナビ必須/ナビまたは小休止/常に）
- グローバルホットキーで AutoSwitch ON/OFF を切替（現在はメニューのみ）

5) ログ簡素化（任意）
- noisy な重複 [decide] を抑制。unstable の回数を集計して一行要約など

## 配布手順（署名/ノタライズ）
- スクリプト: `scripts/make_dmg.sh`
- 推奨実行例（ユニバーサル、署名+ノタライズ+ステープル）:
  ```
  IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  TEAM_ID="TEAMID" APPLE_ID="you@example.com" APP_PASSWORD="app-specific-password" \
  NOTARIZE=1 bash scripts/make_dmg.sh
  ```
- 必須設定:
  - FlowIME / FlowIMEHelper ともに Hardened Runtime 有効
  - Developer ID Application で署名（同一 TEAM）
- 検証:
  - `codesign --verify --deep --strict --verbose=2 build/Build/Products/Release/FlowIME.app`
  - `spctl -a -vvv build/Build/Products/Release/FlowIME.app`
  - `xcrun stapler validate FlowIME.dmg`
- 配布: ノタライズ済み DMG を配布（zip再圧縮は避ける）

## テスト計画（抜粋）
- 日本語連打: prevJP → 常に JP 維持、EN へは移行しない
- 英文手前へ矢印移動: navigateWindow 内にタイプ開始 → EN へ切替
- クリックで英文手前: click → すぐタイプ → EN へ切替
- 改行: newline 直後1キーは抑制、その後 EN 許可
- 手動トグル: Cmd/Ctrl+Space、JIS 英数/かな、メニュー → 次の1キーは抑制
- 逆切替耐性: 連続で EN/JP がぶつからない（enforce が有効）

## 既存ログ指針
- 望ましい切替:
  - JP→EN: `[decide] … prev="b" … → EN reason=prevEN`
  - EN→JP: `[decide] … prev="語" … → JP reason=prevJP`
- 抑制が働いた場合:
  - 改行/先頭: `reason=newline/head`
  - 手動: `reason=userToggle`
  - romaji 中: `reason=jpTyping`
  - AX 不安定: `reason=unstable`

---
連携・サポート
- OS の「書類ごとに入力ソースを自動切り替え」は OFF 推奨。
- まだ誤切替が出る場合、[decide] の1行と直前数行を共有してください（しきい値を微調整します）。
