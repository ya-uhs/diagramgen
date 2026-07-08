// Browser bundle entry for diagramgen.
//
// The prebuilt netlistsvg.bundle.js is stale (no dumpLayout / external
// layout support) and the published render(…, elkData) path drops the
// drawn SVG. This wrapper reaches into netlistsvg's internals so the app
// can build the ELK graph, annotate it (semantic partitions), run the
// layout itself and then draw — plus it bundles elkjs so no separate
// elk.bundled.js is needed.

const onml = require('onml');
const ELK = require('elkjs/lib/elk.bundled.js');
const { FlatModule } = require('netlistsvg/built/FlatModule');
const Skin = require('netlistsvg/built/Skin').default;
const { buildElkGraph } = require('netlistsvg/built/elkGraph');
const drawModule = require('netlistsvg/built/drawModule').default;

function createFlatModule(skinData, yosysNetlist) {
  Skin.skin = onml.p(skinData);
  const layoutProps = Skin.getProperties();
  const flatModule = new FlatModule(yosysNetlist);
  if (layoutProps.constants !== false) flatModule.addConstants();
  if (layoutProps.splitsAndJoins !== false) flatModule.addSplitsJoins();
  flatModule.createWires();
  return { flatModule, layoutProps };
}

// Build the pre-layout ELK graph. Returns everything needed to lay out
// and draw: mutate kgraph (e.g. per-node partitions), run ELK with
// layoutProps.layoutEngine (+ extras), then call draw(layouted).
function buildGraph(skinData, yosysNetlist) {
  const { flatModule, layoutProps } = createFlatModule(skinData, yosysNetlist);
  const kgraph = buildElkGraph(flatModule);
  return {
    kgraph,
    layoutProps,
    draw: (layoutedGraph) => drawModule(layoutedGraph, flatModule),
  };
}

// Classic one-shot render (internal ELK instance, default options).
async function render(skinData, yosysNetlist) {
  const g = buildGraph(skinData, yosysNetlist);
  const layouted = await new ELK().layout(g.kgraph, {
    layoutOptions: g.layoutProps.layoutEngine,
  });
  return g.draw(layouted);
}

module.exports = { render, buildGraph, ELK };
