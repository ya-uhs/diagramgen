# diagramgen

Verilog/SystemVerilog からブロック図(モジュール階層+ポート接続)を生成するツール。

**Web版(インストール不要): https://ya-uhs.github.io/diagramgen/**

## パイプライン

```
SystemVerilog --(フロントエンド)--> Yosys互換JSON --(netlistsvg/ELK)--> SVG
```

フロントエンドは3系統あり、中間フォーマット(Yosys JSON)で合流する:

| | フロントエンド | SV対応 | 用途 |
|---|---|---|---|
| ローカル | slang (pyslang) | 完全 | `make serve` / CLI |
| ブラウザ単体 | **slang-wasm**(自前ビルド、3.3MB) | 完全 | GitHub Pages 版 |
| ブラウザ単体 | yosys-wasm ([YoWASP](https://yowasp.org/)) | 限定的(-sv) | FSM抽出 / フォールバック |

Web UI は slangサーバー → slang-wasm → yosys-wasm の順に自動検出する。
slang-wasm は slang v11 を Emscripten でビルドし、`wasm/shim.cpp`
(netlist.py と同じ抽出ロジックのC++版)を組み込んだもの。ビルド手順は
`make slang-wasm`(要 emscripten/ninja、`slang-src/` に slang v11 を
クローンしておく)。成果物は `wasm/dist/` にコミット済みなので通常は
再ビルド不要。FSMビューは合成パスが必要なため引き続き yosys-wasm を使う。

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
- **テーマ**: ヘッダの theme セレクタで Pastel / Datasheet / Blueprint /
  Classic を切り替えられる(選択は localStorage に保存)。テーマ定義は
  `web/index.html` の `THEMES` に集約されており、フォント・配線色・背景・
  パレット・スキンをここに足すだけで新テーマを追加できる。箱やポート
  マーカーの形状はスキン(`web/skin.svg`、netlistsvg形式)で定義。
- **信号ラベル**: ネットの最長セグメント上にカプセル型ラベルを自動配置
  (セル・他ラベルとの衝突回避付き)。色は「設定」ダイアログで
  正規表現→色を自由に設定でき(localStorage保存)、凡例も自動生成。
  「非表示ルール適用」トグルで非表示フラグ付きルールにマッチする配線
  (デフォルトはclk/rst)を図から除ける。
- **意味順配置**: 「意味順配置」ON(デフォルト)で、ブロックが
  アーキテクチャ上の意味順(CPU→バス/インターコネクト→周辺)に並ぶ。
  仕組みはポート方向の多数決 — マスターはスレーブへ多くのネット
  (addr/wdata/we)を駆動し戻りは少ない(rdata)ので、駆動数の差から
  マスター→スレーブの向きを決め、irq のような逆行配線で生じる循環は
  弱い辺から切ってDAG化し、レイヤを ELK のパーティション制約として
  与えている(LLM等の推論は不使用、決定的)。
- **操作**: ホイールでズーム、ドラッグでパン、Fitで全体表示。配線に
  ホバーするとネット全体がハイライトされ名前がツールチップ表示される。
  モジュールの箱をダブルクリックするとその階層に潜れる(←戻るで復帰)。
  ツールバーから SVG / PNG でダウンロード。エディタ内容は自動保存され、
  リロードしても消えない(設定→「サンプルに戻す」でリセット)。
  コンパイルエラーの `file:line:col` はクリックでその行にジャンプ。
- **SVインターフェース**(slangフロントエンド): interfaceポート接続は
  1本のネットに集約され、図では太いバス1本+インスタンス名ラベルとして
  描かれる(データシート図の「バス1本=1ラベル」に相当)。
- **FSMビュー**: view セレクタを FSM にすると、yosys の
  `fsm_detect`/`fsm_extract`(ブラウザ内 wasm 実行)で状態機械を抽出し、
  状態遷移図を描画する。遷移ラベルには実際の信号名付き条件
  (`we=1` など)が付き、リセット状態は赤枠で強調。
  「非表示ルール適用」ON でリセット遷移の弧を取り除き、条件から
  rst 項を剥がした本質的な遷移だけを表示する。
  ヒューリスティックに検出されない FSM は状態レジスタに
  `(* fsm_encoding = "auto" *)` を付けると確実に検出される。

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
