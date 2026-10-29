"use strict";

// The published lightningcss native bindings are linked with AArch64 TLS
// descriptors (R_AARCH64_TLSDESC) that the OpenHarmony musl loader cannot
// relocate, so dlopen'ing them crashes the Node process.
//
// lightningcss resolves `lightningcss-<platform>-<arch>` first and only falls
// back to the adjacent `.node` file, so this package keeps the module loadable
// on OpenHarmony. CSS optimization becomes a no-op; Vite/esbuild still
// minifies the final stylesheet.

function transform(options = {}) {
  const { code, inputSourceMap } = options;

  return {
    code: Buffer.isBuffer(code) ? code : Buffer.from(code ?? ""),
    map: inputSourceMap ? Buffer.from(inputSourceMap) : undefined,
    warnings: [],
  };
}

// Mirrors lightningcss' `Features` enum. Only used as transform options, which
// this fallback ignores, but the object must exist for option construction.
const Features = {
  Nesting: 1,
  NotSelector: 2,
  DirSelector: 4,
  LangSelectorList: 8,
  IsSelector: 16,
  TextDecorationThicknessPercent: 32,
  MediaIntervalSyntax: 64,
  MediaRangeSyntax: 128,
  CustomMediaQueries: 256,
  ClampFunction: 512,
  ColorFunction: 1024,
  OklabColors: 2048,
  LabColors: 4096,
  P3Colors: 8192,
  HexAlphaColors: 16384,
  SpaceSeparatedColorNotation: 32768,
  FontFamilySystemUi: 65536,
  DoublePositionGradients: 131072,
  VendorPrefixes: 262144,
  LogicalProperties: 524288,
  Selectors: 1048576,
  MediaQueries: 2097152,
  LightDark: 4194304,
};

module.exports = { transform, Features };
