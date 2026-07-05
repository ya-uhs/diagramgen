PYTHON := .venv/bin/python
NETLISTSVG := ./node_modules/.bin/netlistsvg

RTL := $(wildcard rtl/*.sv)
SVGS := $(patsubst rtl/%.sv,build/%.svg,$(RTL))

all: $(SVGS)

build/%.json: rtl/%.sv src/diagramgen/*.py | build
	PYTHONPATH=src $(PYTHON) -m diagramgen.cli $< -o $@

build/%.svg: build/%.json
	$(NETLISTSVG) $< -o $@

build:
	mkdir -p build

serve:
	PYTHONPATH=src $(PYTHON) -m diagramgen.server

# Static site for GitHub Pages (docs/ is what gets published).
site:
	PYTHONPATH=src $(PYTHON) -c "from diagramgen.server import _stage_assets; _stage_assets()"
	rm -rf docs && cp -R web docs

clean:
	rm -rf build

.PHONY: all clean serve site
.SECONDARY:
