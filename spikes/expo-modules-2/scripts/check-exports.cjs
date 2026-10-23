const assert = require('node:assert/strict');
const path = require('node:path');
const ts = require('typescript');
const { scanExports } = require('expo-modules-macros');

const root = path.resolve(__dirname, '..');
const filename = path.resolve(process.argv[2] || path.join(root, 'modules/expo2-spike/index.ts'));
const swift = path.resolve(process.argv[3] || path.join(root, 'modules/expo2-spike/apple'));
const program = ts.createProgram([filename], {
  strict: true, skipLibCheck: true, target: ts.ScriptTarget.ESNext,
  module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler,
});
const checker = program.getTypeChecker();
const source = program.getSourceFile(filename);
const coreImport = source.statements.find((s) => ts.isImportDeclaration(s) && ['expo', 'expo-modules-core'].includes(s.moduleSpecifier.text));
const core = coreImport && checker.getSymbolAtLocation(coreImport.moduleSpecifier);
const baseSymbol = (name) => {
  const symbol = core && checker.getExportsOfModule(core).find((s) => s.name === name);
  const resolved = symbol?.flags & ts.SymbolFlags.Alias ? checker.getAliasedSymbol(symbol) : symbol;
  const signature = resolved && checker.getTypeOfSymbolAtLocation(resolved, source).getConstructSignatures()[0];
  return signature && checker.getReturnTypeOfSignature(signature).symbol;
};
const fail = (message) => { throw new Error(message); };
const key = (value) => JSON.stringify(value);
const union = (values) => {
  const flat = values.flatMap((v) => Array.isArray(v) && v[0] === 'union' ? v[1] : [v]);
  const unique = [...new Map(flat.map((v) => [key(v), v])).values()].sort((a, b) => key(a).localeCompare(key(b)));
  return unique.length === 1 ? unique[0] : ['union', unique];
};
const object = (fields) => ['object', fields.sort((a, b) => a[0].localeCompare(b[0]))];
const compare = (actual, expected, context) => assert.deepEqual(actual, expected, context);

function signature(sig) {
  const parameters = sig.parameters.map((p) => {
    const decl = p.valueDeclaration;
    if (decl?.dotDotDotToken) fail('rest parameters are not modeled');
    const optional = !!(decl?.questionToken || decl?.initializer);
    return [optional, typescript(checker.getTypeOfSymbolAtLocation(p, decl || source), optional)];
  });
  return ['function', parameters, typescript(checker.getReturnTypeOfSignature(sig))];
}
function typescript(type, omitUndefined = false) {
  const flags = ts.TypeFlags;
  if (type.flags & flags.Boolean) return 'boolean';
  for (const [flag, name] of [[flags.String, 'string'], [flags.Number, 'number'], [flags.Void, 'void'],
    [flags.Undefined, 'undefined'], [flags.Null, 'null'], [flags.BigInt, 'bigint']]) {
    if (type.flags & flag) return name;
  }
  if (type.flags & flags.StringLiteral) return ['literal', type.value];
  if (type.flags & flags.NumberLiteral) return ['literal', type.value];
  if (type.flags & flags.BooleanLiteral) return ['literal', type.intrinsicName === 'true'];
  if (type.isUnion()) return union(type.types.filter((t) => !omitUndefined || !(t.flags & flags.Undefined)).map((t) => typescript(t)));
  // Brands refine the TS API but have no wire representation. Only unique-symbol string brands qualify.
  if (type.isIntersection() && type.types.some((t) => t.flags & flags.String)) {
    const brands = type.types.filter((t) => !(t.flags & flags.String));
    if (brands.every((t) => t.getProperties().length && t.getProperties().every((p) =>
      checker.getTypeOfSymbolAtLocation(p, p.valueDeclaration || source).flags & flags.UniqueESSymbol))) return 'string';
  }
  if (checker.isArrayType(type)) return ['array', typescript(checker.getTypeArguments(type)[0])];
  if (type.symbol?.name === 'Promise') return ['promise', typescript(checker.getTypeArguments(type)[0])];
  if (surface.sharedObjects.some((s) => s.jsName === type.symbol?.name)) return ['shared', type.symbol.name];
  const calls = type.getCallSignatures();
  if (calls.length) { compare(calls.length, 1, 'overloaded callable'); return signature(calls[0]); }
  if (!(type.flags & flags.Object)) fail(`unmodeled TypeScript type ${checker.typeToString(type)}`);
  const index = type.getStringIndexType();
  if (index && !type.getProperties().length) return ['dictionary', 'string', typescript(index)];
  return object(type.getProperties().map((p) => {
    const optional = !!(p.flags & ts.SymbolFlags.Optional);
    return [p.name, optional, typescript(checker.getTypeOfSymbolAtLocation(p, p.valueDeclaration || source), optional)];
  }));
}
let surface;
function native(type) {
  if (!type) return 'void';
  switch (type.kind) {
    case 'primitive': return type.typeof;
    case 'array': return ['array', native(type.element)];
    case 'optional': return union([native(type.wrapped), 'null']);
    case 'promise': return ['promise', native(type.value)];
    case 'dictionary': return ['dictionary', native(type.key), native(type.value)];
    case 'function': return callable(type.parameters.map((type) => ({ type, optional: false })), type.returns, type.async);
    case 'ref': {
      // CachedSnapshot retains a frozen JSI handle whose wire shape is exactly SnapshotRecord.
      const name = type.name === 'CachedSnapshot' ? 'SnapshotRecord' : type.name;
      const record = surface.records.find((r) => r.name === name);
      if (record) return object(record.properties.map((p) => [p.name, !p.required, native(p.type)]));
      const enumeration = surface.enums.find((e) => e.name === name);
      if (enumeration?.rawType?.typeof === 'string') return union(enumeration.cases.map((c) => ['literal', c.rawValue]));
      const alternatives = surface.unions.find((u) => u.name === name);
      if (alternatives) return union(alternatives.members.map((m) => native(m.type)));
      const shared = surface.sharedObjects.find((s) => s.name === name);
      if (shared) return ['shared', shared.jsName];
      fail(`unresolved Swift type ${name}`);
    }
    default: fail(`unmodeled Swift type ${key(type)}`);
  }
}
function callable(parameters, returns, async) {
  const result = native(returns);
  return ['function', parameters.map((p) => [p.optional, native(p.type)]), async ? ['promise', result] : result];
}
const hasModifier = (node, kind) => node.modifiers?.some((m) => m.kind === kind) || false;
function owner(exported, actual, constructor) {
  const declaration = actual.symbol?.declarations?.find(ts.isClassDeclaration);
  if (!declaration) fail(`missing declared class for ${exported.jsName}`);
  const heritage = declaration.heritageClauses?.find((h) => h.token === ts.SyntaxKind.ExtendsKeyword)?.types;
  const expectedBase = surface.modules.includes(exported) ? 'NativeModule' : 'SharedObject';
  compare(heritage?.length, 1, `${exported.jsName} base class`);
  compare(checker.getTypeAtLocation(heritage[0]).symbol === baseSymbol(expectedBase), true, `${exported.jsName} ${expectedBase} base`);
  const constructorType = constructor || checker.getTypeOfSymbolAtLocation(actual.symbol, declaration);
  for (const isStatic of [false, true]) {
    const members = declaration.members.filter((m) => m.name && hasModifier(m, ts.SyntaxKind.StaticKeyword) === isStatic);
    if (members.some((m) => [ts.SyntaxKind.PrivateKeyword, ts.SyntaxKind.ProtectedKeyword].some((k) => hasModifier(m, k)))) fail(`${exported.jsName} has inaccessible exports`);
    const functions = exported.functions.filter((m) => m.static === isStatic);
    const properties = exported.properties.filter((m) => m.static === isStatic);
    const classes = isStatic ? [] : exported.classes || [];
    compare(members.map((m) => m.name.text).sort(), [...functions, ...properties, ...classes].map((m) => m.jsName).sort(), `${exported.jsName} members`);
    const target = isStatic ? constructorType : actual;
    const memberType = (name) => checker.getTypeOfSymbolAtLocation(target.getProperty(name), declaration);
    for (const f of functions) compare(typescript(memberType(f.jsName)), callable(f.parameters, f.returns, f.async), f.jsName);
    for (const p of properties) {
      if (!p.type) fail(`unresolved Swift property ${p.jsName}`);
      compare(typescript(memberType(p.jsName)), native(p.type), p.jsName);
      compare(hasModifier(members.find((m) => m.name.text === p.jsName), ts.SyntaxKind.ReadonlyKeyword), p.readonly, `${p.jsName} readonly`);
    }
    for (const c of classes) {
      const shared = surface.sharedObjects.find((s) => s.name === c.name);
      if (!shared) fail(`unresolved shared class ${c.name}`);
      const ctor = memberType(c.jsName);
      const signatures = ctor.getConstructSignatures();
      const classNode = ctor.symbol?.declarations?.find(ts.isClassDeclaration);
      const init = classNode?.members.find(ts.isConstructorDeclaration);
      const inaccessible = hasModifier(classNode || {}, ts.SyntaxKind.AbstractKeyword) ||
        [ts.SyntaxKind.PrivateKeyword, ts.SyntaxKind.ProtectedKeyword].some((kind) => hasModifier(init || {}, kind));
      compare(inaccessible ? 0 : signatures.length, shared.initializer ? 1 : 0, `${c.jsName} constructor`);
      if (shared.initializer) compare(signature(signatures[0])[1], callable(shared.initializer.parameters)[1], `${c.jsName} arguments`);
      owner(shared, checker.getDeclaredTypeOfSymbol(ctor.symbol), ctor);
    }
  }
  const eventNode = declaration.heritageClauses?.flatMap((h) => h.types).find((t) => t.typeArguments?.length)?.typeArguments[0];
  const events = eventNode ? checker.getTypeFromTypeNode(eventNode).getProperties() : [];
  compare(events.map((p) => p.name).sort(), exported.events.map((e) => e.jsName).sort(), `${exported.jsName} events`);
  for (const event of exported.events) {
    const actualEvent = events.find((p) => p.name === event.jsName);
    compare(typescript(checker.getTypeOfSymbolAtLocation(actualEvent, declaration)),
      callable(event.payload ? [{ type: event.payload, optional: false }] : []), `${event.jsName} event`);
  }
}
(async () => {
  const diagnostics = [...program.getSyntacticDiagnostics(source), ...program.getSemanticDiagnostics(source)];
  if (diagnostics.length) fail(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
    getCurrentDirectory: () => root, getCanonicalFileName: (f) => f, getNewLine: () => '\n',
  }));
  const result = await scanExports([swift], { timeout: 30_000 });
  compare(result.schemaVersion, 8, 'scan-exports schema');
  surface = result.exports;
  const calls = [];
  function visit(node) {
    if (ts.isCallExpression(node) && node.expression.getText(source) === 'requireNativeModule') calls.push(node);
    ts.forEachChild(node, visit);
  }
  visit(source);
  compare(calls.map((c) => c.arguments[0]?.text).sort(), surface.modules.map((m) => m.jsName).sort(), 'module registrations');
  for (const module of surface.modules) {
    const call = calls.find((c) => c.arguments[0]?.text === module.jsName);
    if (!call) fail(`missing requireNativeModule('${module.jsName}')`);
    owner(module, checker.getTypeAtLocation(call));
  }
  console.log(`Export drift: schema 8 matches ${path.relative(root, filename)}`);
})().catch((error) => { console.error(`export drift: ${error.message}`); process.exitCode = 1; });
