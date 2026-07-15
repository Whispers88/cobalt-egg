#!/usr/bin/env node
// Stub wrapper for entrypoint tests: print the argv the entrypoint built, exit.
const i = process.argv.indexOf("--argv");
console.log("STUB_ARGV " + JSON.stringify(process.argv.slice(i + 1)));
console.log("STUB_DOORSTOP " + (process.env.COBALT_DOORSTOP_TARGET || "none"));
process.exit(0);
