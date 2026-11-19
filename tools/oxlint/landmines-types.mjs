import { relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import landmines from "@interfere/landmines/types";

const ruleName = "no-explicit-return-types";
const upstream = landmines.rules[ruleName];
const repository = fileURLToPath(new URL("../../", import.meta.url));
const publishedRoots = ["expo/src/", "expo/plugin/src/"];
const testDirectories = new Set(["__tests__", "test", "tests"]);

function allowsExportAnnotations(context) {
  const parts = relative(repository, context.physicalFilename).split(sep);
  if (parts.some(part => testDirectories.has(part)) || /\.(test|spec)\.[cm]?[jt]sx?$/.test(parts.at(-1))) return false;
  const path = parts.join("/");
  return publishedRoots.some(root => path.startsWith(root));
}

function exportedNames(program) {
  const names = new Set();
  for (const statement of program.body) {
    if (statement.type === "ExportDefaultDeclaration" && statement.declaration.type === "Identifier") {
      names.add(statement.declaration.name);
    }
    if (statement.type === "ExportNamedDeclaration" && !statement.source && statement.exportKind !== "type") {
      for (const { local, exportKind } of statement.specifiers) {
        if (local.type === "Identifier" && exportKind !== "type") names.add(local.name);
      }
    }
  }
  return names;
}

function isExported(node, names) {
  const parent = node.parent;
  switch (parent?.type) {
    case "ExportDefaultDeclaration":
    case "ExportNamedDeclaration":
      return parent.declaration === node;
    case "Program":
      return node.id?.type === "Identifier" && names.has(node.id.name);
    case "VariableDeclarator": {
      const declaration = parent.parent;
      return parent.init === node && (
        isExported(declaration, names) ||
        (declaration.parent?.type === "Program" && parent.id.type === "Identifier" && names.has(parent.id.name))
      );
    }
    case "MethodDefinition":
    case "PropertyDefinition":
      return parent.value === node && parent.accessibility !== "private" &&
        parent.key.type !== "PrivateIdentifier" && isExported(parent.parent.parent, names);
    case "Property":
      return parent.value === node && parent.parent.type === "ObjectExpression" &&
        isExported(parent.parent, names);
    case "TSAsExpression":
    case "TSNonNullExpression":
    case "TSSatisfiesExpression":
    case "TSTypeAssertion":
    case "TSInstantiationExpression":
      return parent.expression === node && isExported(parent, names);
    default:
      return false;
  }
}

export default {
  ...landmines,
  rules: {
    ...landmines.rules,
    [ruleName]: {
      ...upstream,
      create(context) {
        const upstreamVisitors = upstream.create(context);
        if (!allowsExportAnnotations(context)) return upstreamVisitors;
        const names = exportedNames(context.sourceCode.ast);
        const visitors = {};
        for (const [selector, visit] of Object.entries(upstreamVisitors)) {
          visitors[selector] = node => {
            if (!isExported(node, names)) visit(node);
          };
        }
        return visitors;
      },
    },
  },
};
