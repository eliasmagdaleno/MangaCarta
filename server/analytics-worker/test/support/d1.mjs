// A small stand-in for Cloudflare D1 over node:sqlite (both are SQLite). It implements the
// part of the D1 client API the Worker uses: prepare → bind → run / all / first, and batch,
// which — as in D1 — runs its statements in one transaction and rolls back if any fails.
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

const SCHEMA = new URL("../../schema.sql", import.meta.url);

class Statement {
  constructor(db, sql, params = []) {
    this.db = db;
    this.sql = sql;
    this.params = params;
  }

  bind(...params) {
    return new Statement(this.db, this.sql, params);
  }

  execute() {
    const statement = this.db.prepare(this.sql);
    if (statement.columns().length > 0) {
      return { success: true, results: statement.all(...this.params), meta: {} };
    }
    const { changes } = statement.run(...this.params);
    return { success: true, results: [], meta: { changes } };
  }

  async run() {
    return this.execute();
  }

  async all() {
    return this.execute();
  }

  async first(column) {
    const [row] = this.execute().results;
    if (row === undefined) return null;
    return column === undefined ? row : row[column];
  }
}

export function makeD1() {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(SCHEMA, "utf8"));
  return {
    sqlite: db,
    prepare(sql) {
      return new Statement(db, sql);
    },
    async batch(statements) {
      db.exec("BEGIN");
      try {
        const results = statements.map((statement) => statement.execute());
        db.exec("COMMIT");
        return results;
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },
    rows(sql = "SELECT * FROM events ORDER BY id") {
      return db.prepare(sql).all().map((row) => ({ ...row }));
    },
  };
}
