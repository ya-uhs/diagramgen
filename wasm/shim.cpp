// diagramgen slang-wasm shim: SystemVerilog sources in, Yosys-JSON-compatible
// netlist out. C++ port of src/diagramgen/netlist.py against the slang API.
//
// ABI (kept trivial to avoid a JSON parser on the input side):
//   input:  "\x01<name>\x02<content>\x01<name>\x02<content>..."
//   output: netlist JSON, or {"error": "<rendered diagnostics>"}
// The returned pointer stays valid until the next call.

#include <functional>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "slang/ast/Compilation.h"
#include "slang/ast/expressions/AssignmentExpressions.h"
#include "slang/ast/expressions/ConversionExpression.h"
#include "slang/ast/expressions/MiscExpressions.h"
#include "slang/ast/expressions/OperatorExpressions.h"
#include "slang/ast/expressions/SelectExpressions.h"
#include "slang/ast/symbols/BlockSymbols.h"
#include "slang/ast/symbols/CompilationUnitSymbols.h"
#include "slang/ast/symbols/InstanceSymbols.h"
#include "slang/ast/symbols/PortSymbols.h"
#include "slang/diagnostics/DiagnosticEngine.h"
#include "slang/diagnostics/TextDiagnosticClient.h"
#include "slang/syntax/SyntaxTree.h"
#include "slang/text/SourceManager.h"

using namespace slang;
using namespace slang::ast;
using namespace slang::syntax;

namespace {

std::string jsonEscape(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof buf, "\\u%04x", c);
                    out += buf;
                }
                else {
                    out += c;
                }
        }
    }
    return out;
}

struct ModuleNets {
    std::map<std::string, int> ids;
    int next = 2;
    std::string pathPrefix; // hierarchical path of the module instance + "."

    int idFor(const std::string& name) {
        auto [it, inserted] = ids.emplace(name, next);
        if (inserted)
            next++;
        return it->second;
    }

    int fresh(const std::string& hint) {
        return idFor("$" + hint + "$" + std::to_string(next));
    }

    // Module-relative hierarchical name; disambiguates same-named nets in
    // different generate blocks.
    std::string localName(const Symbol& sym) {
        std::string path = sym.getHierarchicalPath();
        if (path.rfind(pathPrefix, 0) == 0)
            return path.substr(pathPrefix.size());
        return std::string(sym.name);
    }
};

const char* directionOf(ArgumentDirection dir) {
    switch (dir) {
        case ArgumentDirection::In: return "input";
        case ArgumentDirection::Out: return "output";
        default: return "inout";
    }
}

// Walk scope members, descending into generate blocks/arrays and instance
// arrays; the callback receives (genPrefix, member).
void walkMembers(const Scope& scope, const std::string& genPrefix,
                 const std::function<void(const std::string&, const Symbol&)>& f) {
    for (auto& member : scope.members()) {
        if (member.kind == SymbolKind::GenerateBlock) {
            auto& blk = member.as<GenerateBlockSymbol>();
            if (blk.isUninstantiated)
                continue;
            std::string name = blk.name.empty()
                                   ? "genblk" + std::to_string(blk.constructIndex)
                                   : std::string(blk.name);
            walkMembers(blk, genPrefix + name + ".", f);
        }
        else if (member.kind == SymbolKind::GenerateBlockArray) {
            auto& arr = member.as<GenerateBlockArraySymbol>();
            for (auto& sub : arr.members()) {
                if (sub.kind != SymbolKind::GenerateBlock)
                    continue;
                auto& blk = sub.as<GenerateBlockSymbol>();
                if (blk.isUninstantiated)
                    continue;
                std::string name = std::string(arr.name) + "[" +
                                   std::to_string(blk.constructIndex) + "]";
                walkMembers(blk, genPrefix + name + ".", f);
            }
        }
        else if (member.kind == SymbolKind::InstanceArray) {
            auto& arr = member.as<InstanceArraySymbol>();
            int i = 0;
            for (auto& el : arr.members()) {
                if (el.kind == SymbolKind::Instance) {
                    f(genPrefix + std::string(arr.name) + "[" +
                          std::to_string(i) + "].",
                      el);
                }
                i++;
            }
        }
        else {
            f(genPrefix, member);
        }
    }
}

// Bit tokens: numeric net ids rendered bare, constants rendered quoted.
void resolveExpr(const Expression& expr, ModuleNets& nets, std::vector<std::string>& tokens) {
    switch (expr.kind) {
        case ExpressionKind::Assignment:
            resolveExpr(expr.as<AssignmentExpression>().left(), nets, tokens);
            return;
        case ExpressionKind::Conversion:
            resolveExpr(expr.as<ConversionExpression>().operand(), nets, tokens);
            return;
        case ExpressionKind::NamedValue:
        case ExpressionKind::HierarchicalValue: {
            auto& sym = expr.as<ValueExpressionBase>().symbol;
            tokens.push_back(std::to_string(nets.idFor(nets.localName(sym))));
            return;
        }
        case ExpressionKind::ElementSelect:
            resolveExpr(expr.as<ElementSelectExpression>().value(), nets, tokens);
            return;
        case ExpressionKind::RangeSelect:
            resolveExpr(expr.as<RangeSelectExpression>().value(), nets, tokens);
            return;
        case ExpressionKind::MemberAccess:
            resolveExpr(expr.as<MemberAccessExpression>().value(), nets, tokens);
            return;
        case ExpressionKind::Concatenation:
            for (auto op : expr.as<ConcatenationExpression>().operands())
                resolveExpr(*op, nets, tokens);
            return;
        case ExpressionKind::EmptyArgument:
            return;
        default: {
            auto constant = expr.getConstant();
            if (constant && constant->isInteger()) {
                tokens.push_back(*constant->integer().getRawPtr() ? "\"1\"" : "\"0\"");
                return;
            }
            tokens.push_back(std::to_string(nets.fresh("expr")));
        }
    }
}

std::string extractModule(const InstanceBodySymbol& body, const std::string& instPath) {
    ModuleNets nets;
    nets.pathPrefix = instPath + ".";
    std::ostringstream ports, cells;
    bool firstPort = true, firstCell = true;

    walkMembers(body, "", [&](const std::string& genPrefix, const Symbol& member) {
        if (member.kind == SymbolKind::Port) {
            auto& port = member.as<PortSymbol>();
            if (port.isNullPort || !port.internalSymbol)
                return;
            if (!firstPort)
                ports << ",";
            firstPort = false;
            ports << "\"" << jsonEscape(port.name) << "\":{\"direction\":\""
                  << directionOf(port.direction) << "\",\"bits\":["
                  << nets.idFor(std::string(port.internalSymbol->name)) << "]}";
        }
        else if (member.kind == SymbolKind::InterfacePort) {
            if (!firstPort)
                ports << ",";
            firstPort = false;
            ports << "\"" << jsonEscape(member.name)
                  << "\":{\"direction\":\"inout\",\"bits\":["
                  << nets.idFor(std::string(member.name)) << "]}";
        }
        else if (member.kind == SymbolKind::Instance) {
            auto& inst = member.as<InstanceSymbol>();
            if (inst.getDefinition().definitionKind != DefinitionKind::Module) {
                nets.idFor(nets.localName(inst));
                return;
            }
            std::ostringstream conns, dirs;
            bool firstConn = true;
            for (auto conn : inst.getPortConnections()) {
                std::string pname(conn->port.name);
                std::string dir;
                std::vector<std::string> tokens;
                if (conn->port.kind == SymbolKind::InterfacePort) {
                    auto iface = conn->getIfaceConn();
                    if (!iface.first)
                        continue;
                    dir = "inout";
                    tokens.push_back(
                        std::to_string(nets.idFor(nets.localName(*iface.first))));
                }
                else if (conn->port.kind == SymbolKind::Port) {
                    dir = directionOf(conn->port.as<PortSymbol>().direction);
                    if (auto expr = conn->getExpression())
                        resolveExpr(*expr, nets, tokens);
                    if (tokens.empty()) {
                        tokens.push_back(std::to_string(nets.fresh(
                            "unconn_" + std::string(inst.name) + "_" + pname)));
                    }
                }
                else {
                    continue;
                }
                if (!firstConn) {
                    conns << ",";
                    dirs << ",";
                }
                firstConn = false;
                dirs << "\"" << jsonEscape(pname) << "\":\"" << dir << "\"";
                conns << "\"" << jsonEscape(pname) << "\":[";
                for (size_t i = 0; i < tokens.size(); i++) {
                    if (i)
                        conns << ",";
                    conns << tokens[i];
                }
                conns << "]";
            }
            std::string cellName = inst.name.empty()
                                       ? (genPrefix.empty()
                                              ? std::string("unnamed")
                                              : genPrefix.substr(0, genPrefix.size() - 1))
                                       : genPrefix + std::string(inst.name);
            if (!firstCell)
                cells << ",";
            firstCell = false;
            cells << "\"" << jsonEscape(cellName) << "\":{\"type\":\""
                  << jsonEscape(inst.getDefinition().name)
                  << "\",\"port_directions\":{" << dirs.str() << "},\"connections\":{"
                  << conns.str() << "}}";
        }
    });

    std::ostringstream netnames;
    bool firstNet = true;
    for (auto& [name, id] : nets.ids) {
        if (!firstNet)
            netnames << ",";
        firstNet = false;
        netnames << "\"" << jsonEscape(name) << "\":{\"bits\":[" << id
                 << "],\"hide_name\":" << (name[0] == '$' ? 1 : 0) << "}";
    }

    std::ostringstream out;
    out << "{\"ports\":{" << ports.str() << "},\"cells\":{" << cells.str()
        << "},\"netnames\":{" << netnames.str() << "}}";
    return out.str();
}

void visitInstance(const InstanceSymbol& inst, bool isTop,
                   std::map<std::string, std::string>& modules,
                   std::vector<std::string>& order) {
    std::string name(inst.getDefinition().name);
    if (modules.count(name))
        return;
    std::string body = extractModule(inst.body, inst.getHierarchicalPath());
    if (isTop) {
        body.insert(1, "\"attributes\":{\"top\":1},");
    }
    modules.emplace(name, std::move(body));
    order.push_back(name);
    walkMembers(inst.body, "", [&](const std::string&, const Symbol& member) {
        if (member.kind == SymbolKind::Instance &&
            member.as<InstanceSymbol>().getDefinition().definitionKind ==
                DefinitionKind::Module) {
            visitInstance(member.as<InstanceSymbol>(), false, modules, order);
        }
    });
}

std::string resultBuffer;

} // namespace

extern "C" {

const char* diagramgen_compile(const char* input) {
    try {
        SourceManager sourceManager;
        Compilation compilation;

        std::string_view rest(input);
        while (!rest.empty() && rest[0] == '\x01') {
            rest.remove_prefix(1);
            size_t sep = rest.find('\x02');
            if (sep == std::string_view::npos)
                break;
            std::string_view name = rest.substr(0, sep);
            rest.remove_prefix(sep + 1);
            size_t end = rest.find('\x01');
            std::string_view content =
                end == std::string_view::npos ? rest : rest.substr(0, end);
            rest.remove_prefix(content.size());
            compilation.addSyntaxTree(
                SyntaxTree::fromText(content, sourceManager, name, name));
        }

        Diagnostics errors;
        for (auto& diag : compilation.getAllDiagnostics()) {
            if (diag.isError())
                errors.push_back(diag);
        }
        if (!errors.empty()) {
            DiagnosticEngine engine(sourceManager);
            auto client = std::make_shared<TextDiagnosticClient>();
            engine.addClient(client);
            for (auto& diag : errors)
                engine.issue(diag);
            resultBuffer = "{\"error\":\"" + jsonEscape(client->getString()) + "\"}";
            return resultBuffer.c_str();
        }

        auto topInstances = compilation.getRoot().topInstances;
        if (topInstances.empty()) {
            resultBuffer = "{\"error\":\"no top-level modules found\"}";
            return resultBuffer.c_str();
        }

        std::map<std::string, std::string> modules;
        std::vector<std::string> order;
        for (auto inst : topInstances)
            visitInstance(*inst, true, modules, order);

        std::ostringstream out;
        out << "{\"creator\":\"diagramgen (slang-wasm)\",\"modules\":{";
        for (size_t i = 0; i < order.size(); i++) {
            if (i)
                out << ",";
            out << "\"" << jsonEscape(order[i]) << "\":" << modules[order[i]];
        }
        out << "}}";
        resultBuffer = out.str();
    }
    catch (const std::exception& e) {
        resultBuffer = "{\"error\":\"internal error: " +
                       jsonEscape(e.what()) + "\"}";
    }
    return resultBuffer.c_str();
}

} // extern "C"
