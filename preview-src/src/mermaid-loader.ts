import type {
  MermaidInitialization,
  MermaidRenderResult,
} from "./mermaid-renderer";

/** The slice of the Mermaid API the preview uses. */
export interface MermaidAPI {
  initialize(configuration: MermaidInitialization): void;
  render(id: string, source: string): Promise<MermaidRenderResult>;
}

declare global {
  interface Window {
    /** Set by `mermaid.js` (an IIFE built from `mermaid-entry.ts`) once it has run. */
    PlainsongMermaid?: { default: MermaidAPI };
  }
}

export const MERMAID_SCRIPT_SOURCE = "mermaid.js";

/** Mermaid and its dependencies are three quarters of the preview JavaScript, and most
 * documents have no diagram. They ship as a separate classic script that is loaded the
 * first time a diagram renders, so every WebView no longer parses them at start-up.
 *
 * Theme configuration may arrive before the script: the latest one is kept and applied
 * when it loads. A failed load rejects the pending renders (they become `.mermaid-error`,
 * like any render failure) and the next render tries again. */
export class LazyMermaid {
  private api: MermaidAPI | undefined;
  private loading: Promise<MermaidAPI> | undefined;
  private configuration: MermaidInitialization | undefined;

  constructor(private readonly load: () => Promise<MermaidAPI>) {}

  get isLoaded(): boolean {
    return this.api !== undefined;
  }

  readonly initialize = (configuration: MermaidInitialization): void => {
    this.configuration = configuration;
    this.api?.initialize(configuration);
  };

  readonly render = async (id: string, source: string): Promise<MermaidRenderResult> => {
    const api = await this.loaded();
    return api.render(id, source);
  };

  private loaded(): Promise<MermaidAPI> {
    if (this.api) return Promise.resolve(this.api);
    this.loading ??= this.load().then(
      (api) => {
        if (this.configuration) api.initialize(this.configuration);
        this.api = api;
        return api;
      },
      (error: unknown) => {
        this.loading = undefined;
        throw error;
      },
    );
    return this.loading;
  }
}

/** Loads `mermaid.js` next to the preview page with a classic script element. ES module
 * splitting is avoided on purpose: the preview is a file: URL, where module scripts are
 * subject to CORS. The page CSP (`script-src 'self'`) already admits sibling scripts. */
export function loadMermaidScript(
  document: Document,
  source: string = MERMAID_SCRIPT_SOURCE,
): Promise<MermaidAPI> {
  const window = document.defaultView;
  const existing = window?.PlainsongMermaid?.default;
  if (existing) return Promise.resolve(existing);

  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = source;
    script.async = true;
    script.addEventListener("load", () => {
      const api = window?.PlainsongMermaid?.default;
      if (api) {
        resolve(api);
      } else {
        script.remove();
        reject(new Error("Mermaid failed to load"));
      }
    });
    script.addEventListener("error", () => {
      script.remove();
      reject(new Error("Mermaid failed to load"));
    });
    document.head.append(script);
  });
}
