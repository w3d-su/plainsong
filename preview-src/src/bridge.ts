export const PROTOCOL_VERSION = 6;

export const MESSAGE_NAMES = [
  "ready",
  "render",
  "renderComplete",
  "scrollToLine",
  "previewScrolled",
  "linkClicked",
  "checkboxToggled",
  "setTheme",
  "exportHTML",
  "exportHTMLResult",
] as const;

export type BridgeMessageName = (typeof MESSAGE_NAMES)[number];
export type PreviewFileKind = "md" | "mdx";

export interface ReadyPayload {
  protocolVersion: number;
}

export interface RenderPayload {
  // Globally monotonic render-request id (stale-drop key); ordered across
  // document switches. `version` resets per document and must not drive dropping.
  renderID: number;
  // Document version, used only for checkbox writeback round-tripping.
  version: number;
  fileKind: PreviewFileKind;
  text: string;
  baseDir: string | null;
  theme: string;
  allowRemoteImages: boolean;
}

export interface RenderCompletePayload {
  renderID: number;
  version: number;
  blockCount: number;
}

export interface ScrollToLinePayload {
  line: number;
  animated: boolean;
}

export interface PreviewScrolledPayload {
  topVisibleLine: number;
}

export interface LinkClickedPayload {
  href: string;
}

export interface CheckboxToggledPayload {
  line: number;
  checked: boolean;
  version: number;
}

export interface SetThemePayload {
  theme: string;
  allowRemoteImages: boolean;
}

export type ExportHTMLPhase = "discovery" | "finalization";
export type ExportResourceKind = "image" | "font";
export type ExportResourceAction = "embed" | "omit";

export interface ExportResourceDescriptor {
  resourceID: string;
  kind: ExportResourceKind;
  src: string;
}

export interface ExportResourceOutcome {
  resourceID: string;
  kind: ExportResourceKind;
  action: ExportResourceAction;
  dataURI?: string | null;
  reason?: string | null;
}

export interface ExportHTMLPayload {
  exportID: number;
  renderID: number;
  phase: ExportHTMLPhase;
  resourceOutcomes: ExportResourceOutcome[];
}

export type ExportHTMLResultState =
  | { kind: "resourcesNeeded"; resources: ExportResourceDescriptor[] }
  | { kind: "ready"; html: string }
  | { kind: "failed"; reason: string };

export interface ExportHTMLResultPayload {
  exportID: number;
  renderID: number;
  state: ExportHTMLResultState;
}

export type BridgeMessage =
  | { name: "ready"; payload: ReadyPayload }
  | { name: "render"; payload: RenderPayload }
  | { name: "renderComplete"; payload: RenderCompletePayload }
  | { name: "scrollToLine"; payload: ScrollToLinePayload }
  | { name: "previewScrolled"; payload: PreviewScrolledPayload }
  | { name: "linkClicked"; payload: LinkClickedPayload }
  | { name: "checkboxToggled"; payload: CheckboxToggledPayload }
  | { name: "setTheme"; payload: SetThemePayload }
  | { name: "exportHTML"; payload: ExportHTMLPayload }
  | { name: "exportHTMLResult"; payload: ExportHTMLResultPayload };

declare global {
  interface Window {
    PlainsongBridge: {
      receive(message: BridgeMessage): void;
    };
    PlainsongPreview: {
      PROTOCOL_VERSION: number;
    };
    webkit?: {
      messageHandlers?: {
        bridge?: {
          postMessage(message: BridgeMessage): void;
        };
      };
    };
  }
}

export function postBridgeMessage(message: BridgeMessage): void {
  window.webkit?.messageHandlers?.bridge?.postMessage(message);
}
