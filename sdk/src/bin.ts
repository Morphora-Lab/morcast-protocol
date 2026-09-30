#!/usr/bin/env node
// Entry point of the morcast-verify command. See cli.ts.
import { main } from "./cli.js";

process.exitCode = await main(process.argv.slice(2));
