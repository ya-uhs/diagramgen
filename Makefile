PYTHON := .venv/bin/python

RTL := $(wildcard rtl/*.sv)
SVGS := $(patsubst rtl/%.sv,build/%.svg,$(RTL))

all: $(SVGS)

build/%.json: rtl/%.sv src/diagramgen/*.py | build
	PYTHONPATH=src $(PYTHON) -m diagramgen.cli $< -o $@

build/%.svg: build/%.json
	node scripts/render.js $< $@

build:
	mkdir -p build

serve:
	PYTHONPATH=src $(PYTHON) -m diagramgen.server

# Build slang to WebAssembly (requires emscripten + ninja; artifacts are
# committed in wasm/dist so this only needs rerunning on slang/shim changes).
slang-wasm:
	emcmake cmake -S slang-src -B build-wasm -GNinja -DCMAKE_BUILD_TYPE=Release \
	  -DSLANG_INCLUDE_TOOLS=OFF -DSLANG_INCLUDE_TESTS=OFF \
	  -DSLANG_USE_MIMALLOC=OFF -DSLANG_USE_THREADS=OFF \
	  -DCMAKE_CXX_FLAGS="-fwasm-exceptions" -DCMAKE_C_FLAGS="-fwasm-exceptions" \
	  -DCMAKE_CXX_SCAN_FOR_MODULES=OFF
	ninja -C build-wasm
	mkdir -p wasm/dist
	em++ -std=c++20 -O2 wasm/shim.cpp -Islang-src/include -Ibuild-wasm/source \
	  -isystem slang-src/external -isystem build-wasm/_deps/fmt-src/include \
	  -DSLANG_BOOST_SINGLE_HEADER -fwasm-exceptions \
	  build-wasm/lib/libsvlang.a build-wasm/lib/libfmt.a \
	  -o wasm/dist/slang.mjs \
	  -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createSlangModule \
	  -sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=8388608 \
	  -sEXPORTED_FUNCTIONS=_diagramgen_compile,_malloc,_free \
	  -sEXPORTED_RUNTIME_METHODS=cwrap,stringToUTF8,lengthBytesUTF8,HEAPU8 \
	  -sENVIRONMENT=web,node

# Static site for GitHub Pages (docs/ is what gets published).
site:
	PYTHONPATH=src $(PYTHON) -c "from diagramgen.server import _stage_assets; _stage_assets()"
	rm -rf docs && cp -R web docs

clean:
	rm -rf build

.PHONY: all clean serve site slang-wasm
.SECONDARY:
