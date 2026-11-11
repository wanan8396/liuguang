// Rebuild: npm install --prefix <TEMP_DIR> esbuild@0.25.10
// node tool/build_drpy.mjs <TEMP_DIR>/node_modules/esbuild/lib/main.js
// No npm dependency/cache is kept in this repository.
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const esbuild = require(path.resolve(process.argv[2]));
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const assets = path.join(root, 'android/source_engine/src/main/assets');
const result = await esbuild.build({
  stdin: {
    contents: `import * as cheerio from 'assets://drpy/libs/cheerio.min.js';
import CryptoJS from 'assets://drpy/libs/crypto-js.js';
import JSEncrypt from 'assets://drpy/libs/jsencrypt.js';
import drpy from 'assets://drpy/libs/drpy2.js';
globalThis.__lgCheerio = cheerio;
globalThis.CryptoJS = CryptoJS;
globalThis.JSEncrypt = JSEncrypt;
export default drpy;`,
    resolveDir: root, sourcefile: 'drpy-entry.js',
  },
  bundle: true, format: 'iife', globalName: '__drpyGlobal',
  platform: 'neutral', target: ['es2020'], charset: 'utf8',
  legalComments: 'none', minifyWhitespace: true, write: false,
  logLevel: 'silent',
  plugins: [{ name: 'android-assets', setup(build) {
    build.onResolve({ filter: /^assets:\/\// }, args => ({
      path: args.path.slice('assets://'.length), namespace: 'drpy',
    }));
    build.onResolve({ filter: /^\./, namespace: 'drpy' }, args => ({
      path: path.posix.join(path.posix.dirname(args.importer), args.path),
      namespace: 'drpy',
    }));
    build.onLoad({ filter: /.*/, namespace: 'drpy' }, async args => {
      let contents = await fs.readFile(path.join(assets, args.path), 'utf8');
      if (args.path.endsWith('/drpy2.js')) {
        contents = contents.replace("import cheerio from", "import * as cheerio from");
      }
      return { contents, loader: 'js' };
    });
  }}],
});
await fs.mkdir(path.join(root, 'assets/js'), { recursive: true });
await fs.writeFile(path.join(root, 'assets/js/drpy.bundle.js'),
  '// Generated from bundled drpy assets (LGPL-3.0); see tool/build_drpy.mjs.\n' + result.outputFiles[0].text);
console.log('Generated assets/js/drpy.bundle.js');
