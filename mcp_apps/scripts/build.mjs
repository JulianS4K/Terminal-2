// Build each lane's app into a single inlined HTML file (JS + CSS bundled in)
// so server.ts can serve it as one ui:// resource. vite-plugin-singlefile
// inlines everything, which keeps the app self-contained inside the host's
// sandboxed iframe (no external asset fetches to trip a strict CSP).
import { build } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const APPS = ["d0", "d1", "d4"];

for (const app of APPS) {
  const appRoot = path.join(root, "apps", app);
  await build({
    root: appRoot,
    plugins: [viteSingleFile()],
    logLevel: "warn",
    build: {
      target: "esnext",
      outDir: path.join(root, "dist", app),
      emptyOutDir: true,
      rollupOptions: { input: path.join(appRoot, "mcp-app.html") },
    },
  });
  console.log(`built app: ${app} -> dist/${app}/mcp-app.html`);
}
