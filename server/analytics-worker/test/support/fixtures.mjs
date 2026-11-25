export const NOW = new Date("2026-11-15T12:00:00Z");
export const INSTALL = "5F0C2A9E-1B3D-4C5E-8F70-9A1B2C3D4E5F";

export function event(name, fields = {}, envelope = {}) {
  return { v: 1, install: INSTALL, day: "2026-11-15", app: "1.0 (42)", name, ...envelope, ...fields };
}

export function post(body, { headers = {}, path = "/v1/events" } = {}) {
  return new Request(`https://analytics.example.workers.dev${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

export function del(id) {
  return new Request(`https://analytics.example.workers.dev/v1/installs/${id}`, { method: "DELETE" });
}
