export const PROTOCOL_VERSION = 5;

export const MESSAGE_NAMES = [
  "ready",
  "render",
  "renderComplete",
  "scrollToLine",
  "previewScrolled",
  "linkClicked",
  "checkboxToggled",
  "setTheme",
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

export type BridgeMessage =
  | { name: "ready"; payload: ReadyPayload }
  | { name: "render"; payload: RenderPayload }
  | { name: "renderComplete"; payload: RenderCompletePayload }
  | { name: "scrollToLine"; payload: ScrollToLinePayload }
  | { name: "previewScrolled"; payload: PreviewScrolledPayload }
  | { name: "linkClicked"; payload: LinkClickedPayload }
  | { name: "checkboxToggled"; payload: CheckboxToggledPayload }
  | { name: "setTheme"; payload: SetThemePayload };

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
