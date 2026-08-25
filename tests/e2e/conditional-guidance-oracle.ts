export const CANONICAL_BUILTIN_NAMES = [
  "read_file",
  "glob_files",
  "grep_files",
  "list_files",
  "file_info",
  "semantic_search",
  "edit_file",
  "write_file",
  "delete_file",
  "rename_file",
  "copy_file",
  "create_folder",
  "terminal",
  "subagent",
  "skill",
  "install_skill",
  "mcp_search_tools",
  "mcp_select_tool",
  "mcp_features",
  "memory",
  "ask_user_question",
  "open_file",
  "web_fetch",
  "web_search",
  "read_tool_result",
  "vision",
] as const;

export const READ_ONLY_SERIALIZED_TOOL_NAMES = [
  "read_file",
  "glob_files",
  "grep_files",
  "list_files",
] as const;

export const VERIFY_SERIALIZED_TOOL_NAMES = [
  ...READ_ONLY_SERIALIZED_TOOL_NAMES,
  "terminal",
] as const;

export const AUTO_RESPONSES_SERIALIZED_TOOL_NAMES = CANONICAL_BUILTIN_NAMES.filter(
  (name) => name !== "web_search" && name !== "vision",
);

// Durable-only tools are capability-gated on a writable session. `terminal`
// remains available because its exec action does not require a session store.
export const AUTO_RESPONSES_WITHOUT_DURABLE_TOOLS_SERIALIZED_TOOL_NAMES =
  AUTO_RESPONSES_SERIALIZED_TOOL_NAMES.filter((name) =>
    name !== "subagent"
  );

export const AMBIGUOUS_CAPABILITY_CLAUSES = {
  terminal: ["terminal"],
  subagent: [
    "use a subagent only for focused work",
    "Delegate focused work to a specialized subagent",
    "skill changes, subagents, and user questions may require approval",
  ],
  skill: [
    "Load a skill only when the task clearly matches it",
    "Read an installed skill",
    "load an already-installed skill",
    "skill changes, subagents, and user questions may require approval",
    "memory, skill, or ask-user work",
  ],
  memory: [
    "Use memory to save durable user preferences",
    "Save, list, or clear durable user preferences",
    "memory, skill, or ask-user work",
  ],
} as const;

export type GatewayPromptMessage = {
  role?: unknown;
  content?: unknown;
  [key: string]: unknown;
};

export type GatewayToolAdvertisement = {
  type?: unknown;
  name?: unknown;
  id?: unknown;
  description?: unknown;
  parameters?: unknown;
  [key: string]: unknown;
};

export type GatewayRequest = {
  instructions?: string;
  input?: GatewayPromptMessage[];
  tools?: GatewayToolAdvertisement[];
  [key: string]: unknown;
};

export type GuidanceFragment = {
  source: string;
  text: string;
};

export type CapabilityReferenceFinding = {
  capability: string;
  source: string;
  clause: string;
};

export function parseGatewayRequest(body: string): GatewayRequest {
  return JSON.parse(body) as GatewayRequest;
}

export function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [value.text, value.value, value.content].map(contentText).join("");
  }
  return "";
}

export function serializedToolNames(request: GatewayRequest): string[] {
  return (request.tools ?? []).flatMap((tool) =>
    typeof tool.name === "string" ? [tool.name] : []
  );
}

export function canonicalAdvertisedToolNames(request: GatewayRequest): Set<string> {
  return new Set(serializedToolNames(request));
}

function isCanonicalBuiltin(name: string): boolean {
  return CANONICAL_BUILTIN_NAMES.includes(
    name as typeof CANONICAL_BUILTIN_NAMES[number],
  );
}

function collectDescriptions(value: unknown, result: string[] = []): string[] {
  if (Array.isArray(value)) {
    for (const item of value) collectDescriptions(item, result);
    return result;
  }
  if (!value || typeof value !== "object") return result;

  for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
    if (key === "description" && typeof nested === "string") {
      result.push(nested);
    } else {
      collectDescriptions(nested, result);
    }
  }
  return result;
}

export function fxOwnedGuidanceFragments(request: GatewayRequest): GuidanceFragment[] {
  const fragments: GuidanceFragment[] = [];
  if (typeof request.instructions === "string") {
    fragments.push({ source: "instructions", text: request.instructions });
  }

  for (const tool of request.tools ?? []) {
    if (typeof tool.name !== "string") continue;
    if (!isCanonicalBuiltin(tool.name)) continue;
    for (const description of collectDescriptions(tool)) {
      fragments.push({ source: `tool:${tool.name}`, text: description });
    }
  }
  return fragments;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function hasExactSymbolToken(text: string, name: string): boolean {
  return new RegExp(
    `(^|[^A-Za-z0-9_])${escapeRegExp(name)}([^A-Za-z0-9_]|$)`,
  ).test(text);
}

export function findUnavailableCapabilityReferences(
  request: GatewayRequest,
): CapabilityReferenceFinding[] {
  const advertised = canonicalAdvertisedToolNames(request);
  const fragments = fxOwnedGuidanceFragments(request);
  const findings: CapabilityReferenceFinding[] = [];

  for (const name of CANONICAL_BUILTIN_NAMES) {
    if (advertised.has(name) || !name.includes("_")) continue;
    for (const fragment of fragments) {
      if (hasExactSymbolToken(fragment.text, name)) {
        findings.push({
          capability: name,
          source: fragment.source,
          clause: name,
        });
      }
    }
  }

  for (const name of ["terminal", "subagent", "skill", "memory"] as const) {
    if (advertised.has(name)) continue;
    for (const clause of AMBIGUOUS_CAPABILITY_CLAUSES[name]) {
      for (const fragment of fragments) {
        const matches = name === "terminal"
          ? hasExactSymbolToken(fragment.text, clause)
          : fragment.text.includes(clause);
        if (matches) {
          findings.push({
            capability: name,
            source: fragment.source,
            clause,
          });
        }
      }
    }
  }
  return findings;
}

export function toolByName(
  request: GatewayRequest,
  name: string,
): GatewayToolAdvertisement | undefined {
  return (request.tools ?? []).find((tool) => tool.name === name);
}

export function withoutDescriptions(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(withoutDescriptions);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .filter(([key]) => key !== "description")
      .map(([key, nested]) => [key, withoutDescriptions(nested)]),
  );
}

export function toolShapesWithoutDescriptions(request: GatewayRequest): unknown {
  return withoutDescriptions(request.tools ?? []);
}
