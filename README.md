# diagramgen

Verilog/SystemVerilog からブロック図(モジュール階層+ポート接続)を生成するツール。

**Web版(インストール不要): https://ya-uhs.github.io/diagramgen/**

## パイプライン

```
SystemVerilog --(フロントエンド)--> Yosys互換JSON --(netlistsvg/ELK)--> SVG
```

フロントエンドは2系統あり、中間フォーマット(Yosys JSON)で合流する:

| | フロントエンド | SV対応 | 用途 |
|---|---|---|---|
| ローカル | slang (pyslang) | 完全 | `make serve` / CLI |
| ブラウザ単体 | yosys-wasm ([YoWASP](https://yowasp.org/)) | 限定的(-sv) | GitHub Pages 版 |

Web UI は起動時にslangサーバーの有無を検出し、なければ自動で
yosys-wasm(ブラウザ内実行)へフォールバックする。SpinalHDL/Chisel などが
生成する Verilog-2001 は yosys フロントエンドで完全に扱える。

- **フロントエンド**: [slang](https://github.com/MikePopoloski/slang) の Python バインディング
  [pyslang](https://pypi.org/project/pyslang/)。合成は行わず、エラボレーション結果から
  インスタンス階層とポート接続だけを抽出する(Yosys 不要)。
- **中間フォーマット**: Yosys `write_json` 互換の JSON。netlistsvg / d3-hwschematic /
  DigitalJS などの既存ツールがそのまま読める。他の合成系・フロントエンドからの
  コンバータもこの形式に合わせればよい。
- **レイアウト/描画**: 当面は [netlistsvg](https://github.com/nturley/netlistsvg)
  (内部は elkjs = Eclipse Layout Kernel)。将来的に自作レイアウトエンジンへ差し替え予定。

## セットアップ

```sh
python3 -m venv .venv && .venv/bin/pip install pyslang
npm install
```

## 使い方

### Web UI(ブラウザでライブ編集)

```sh
make serve   # → http://127.0.0.1:8000/
```

左ペインで SystemVerilog を編集すると 0.5 秒デバウンスで自動再コンパイルし、
右ペインにブロック図を再描画する。ヘッダのドロップダウンで表示するモジュールを
切り替えられる。コンパイルエラーは行番号付きで左下に表示される。
サーバーは標準ライブラリのみ(slang の実行以外はブラウザ内で完結)。

- **複数ファイル/フォルダ**: 「ファイルを開く」「フォルダを開く」ボタン、
  またはエディタへのドラッグ&ドロップで RTL 一式(.v/.sv)を読み込める。
  ファイルはタブで切り替え、コンパイルは常に全ファイル一括。
- **色分け**: インスタンスの箱はモジュール型ごとに自動で色分けされる。
  色は型名のハッシュから決まるので、同じモジュールは編集・リロードを
  跨いで常に同じ色になる。
- **テーマ**: ヘッダの theme セレクタで Pastel / Classic / Blueprint を
  切り替えられる(選択は localStorage に保存)。テーマ定義は
  `web/index.html` の `THEMES` オブジェクトに集約されており、フォント・
  配線色・背景・パレット関数をここに足すだけで新テーマを追加できる。
  箱の形状自体を変えたい場合は netlistsvg のスキン
  (`web/vendor/default.svg`)を差し替える。

### CLI(SVG ファイル生成)

```sh
make                # rtl/*.sv すべてを build/*.svg に変換
open build/soc.svg  # 生成結果を見る
```

CLI はファイルの代わりにディレクトリも受け付ける(再帰的に .sv/.v を収集):

```sh
PYTHONPATH=src .venv/bin/python -m diagramgen.cli path/to/rtl_dir --top soc -o build/soc.json
```

個別に実行する場合:

```sh
PYTHONPATH=src .venv/bin/python -m diagramgen.cli rtl/soc.sv --top top -o build/soc.json
./node_modules/.bin/netlistsvg build/soc.json -o build/soc.svg
```

## 現状の制限(MVP)

- バスは 1 本のネットに集約(ビット単位の追跡はしない)
- ポート接続式の select / concat は信号全体に丸める
- interface ポート、インスタンス配列、generate ブロックは未対応
- `assign` によるネット間エイリアスは統合しない

## ロードマップ

1. ✅ slang → Yosys互換JSON → netlistsvg の最小チェーン
2. 階層の折り畳み/展開(モジュール単位の深さ制御 `--depth`)
3. ビットレベルのネット追跡(select/concat の正確な表現、バス分岐の描画)
4. レイアウトエンジンの自作(ポート制約付き Sugiyama + 直交ハイパーエッジ
   ルーティング)を独立ライブラリとして切り出し
