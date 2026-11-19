import type { CloudflareConfig } from "cf/config";

export default {
  worker: {
    name: "freedocx-website",
    compatibilityDate: "2026-11-19",
    domains: ["freedocx.thirdeyeds.com"],
    workersDev: false,
  },
} satisfies CloudflareConfig;
