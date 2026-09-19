BEGIN;

-- V1 exposes mutable product enrichment columns that V2 intentionally removes.
DROP VIEW IF EXISTS retail.r1e_effective_qualified_products;

COMMIT;
