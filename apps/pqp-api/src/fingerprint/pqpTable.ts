export function pqpTable(tableName: string): string {
  const safe = tableName.replace(/[^a-zA-Z0-9_]/g, "");

  if (!safe) {
    throw new Error("Invalid PQP table name");
  }

  return `pqp.${safe}`;
}
