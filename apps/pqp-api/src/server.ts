import Fastify from "fastify";
import cors from "@fastify/cors";
import fastifyStatic from "@fastify/static";
import path from "node:path";
import dotenv from "dotenv";
import { pqpRoutes } from "./routes/pqp.js";
import { registerPqpPhase4Routes } from "./phase4/pqpPhase4Routes.js";
import { registerPqpQaReportRoutes } from "./phase4/pqpQaReportRoutes.js";
import { labRoutes } from "./lab/labRoutes.js";

dotenv.config();

const app = Fastify({
  logger: true,
  trustProxy: true
});

await app.register(cors, {
  origin: process.env.PQP_ALLOWED_ORIGIN || true,
  methods: ["GET", "POST"]
});

await app.register(fastifyStatic, {
  root: path.join(process.cwd(), "apps/pqp-api/src/public"),
  prefix: "/pqp/"
});

app.get("/health", async () => ({
  ok: true,
  service: "pqp-api"
}));

await app.register(pqpRoutes);
await registerPqpPhase4Routes(app);
await registerPqpQaReportRoutes(app);
await app.register(labRoutes);

const port = Number(process.env.PORT || 8088);
await app.listen({ port, host: "0.0.0.0" });
