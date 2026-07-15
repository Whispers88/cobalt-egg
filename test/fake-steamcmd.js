#!/usr/bin/env node
"use strict";
// Fake steamcmd for tests (wrapper runs it via the COBALT_STEAMCMD seam).
//  +download_depot <app> <depot> <manifest>  -> writes fake depot content
//  +app_info_print <app>                     -> prints a public buildid VDF
const fs = require("fs");
const path = require("path");
const a = process.argv.slice(2);
const HOME = process.env.COBALT_HOME || process.cwd();

const i = a.indexOf("+download_depot");
if (i !== -1) {
  const app = a[i + 1], dep = a[i + 2], man = a[i + 3];
  const dir = path.join(HOME, "steamcmd", "steamapps", "content", `app_${app}`, `depot_${dep}`);
  fs.mkdirSync(path.join(dir, "RustDedicated_Data"), { recursive: true });
  fs.writeFileSync(path.join(dir, "RustDedicated_Data", `rolled-back-${man}.marker`), man);
  fs.writeFileSync(path.join(dir, "RustDedicated"), "#!/bin/sh\n");
  console.log(`Depot download complete : ${dir} (manifest ${man})`);
  process.exit(0);
}
if (a.includes("+app_info_print")) {
  console.log('"258550" { "depots" { "branches" { "public" { "buildid" "99999" } } } }');
  process.exit(0);
}
process.exit(0);
