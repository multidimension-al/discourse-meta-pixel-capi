// Registers the extensionless resolver hook for the standalone test run.
// See extensionless-resolver.mjs.
import { register } from "node:module";
import { pathToFileURL } from "node:url";

register("./extensionless-resolver.mjs", pathToFileURL(import.meta.filename));
