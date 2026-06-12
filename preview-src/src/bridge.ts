export const PROTOCOL_VERSION = 3;

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
  version: number;
  fileKind: PreviewFileKind;
  text: string;
  baseDir: string | null;
  theme: string;
}

export interface RenderCompletePayload {
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
    BlogEditorBridge: {
      receive(message: BridgeMessage): void;
    };
    BlogEditorPreview: {
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
