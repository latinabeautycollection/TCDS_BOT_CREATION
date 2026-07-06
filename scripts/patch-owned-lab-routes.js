const fs = require("fs");
const path = "apps/pqp-api/src/routes/pqp.ts";

if (!fs.existsSync(path)) {
  throw new Error("Missing route file: " + path);
}

let s = fs.readFileSync(path, "utf8");

if (!s.includes("registerPqpOwnedLabRoutes")) {
  s = 'import { registerPqpOwnedLabRoutes } from "../labs/pqpOwnedLabRoutes.js";\n' + s;
}

if (!s.includes("await registerPqpOwnedLabRoutes(app);")) {
  const idx = s.lastIndexOf("\n}");
  if (idx === -1) throw new Error("Could not patch pqp.ts safely");
  s = s.slice(0, idx) + "\n  await registerPqpOwnedLabRoutes(app);\n" + s.slice(idx);
}

fs.writeFileSync(path, s);
console.log("Owned PQP lab routes patched.");
