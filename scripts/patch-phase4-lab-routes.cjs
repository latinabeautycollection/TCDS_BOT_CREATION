const fs = require("fs");
const path = "apps/pqp-api/src/server.ts";
let s = fs.readFileSync(path, "utf8");

if (!s.includes('labRoutes')) {
  s = s.replace(
    'import { pqpRoutes } from "./routes/pqp.js";',
    'import { pqpRoutes } from "./routes/pqp.js";\nimport { labRoutes } from "./lab/labRoutes.js";'
  );

  s = s.replace(
    'await app.register(pqpRoutes);',
    'await app.register(pqpRoutes);\nawait app.register(labRoutes);'
  );
}

fs.writeFileSync(path, s);
