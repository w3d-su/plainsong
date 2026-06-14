import { describe, expect, it } from "vitest";
import { MESSAGE_NAMES, PROTOCOL_VERSION } from "../src/bridge";

describe("bridge protocol", () => {
  it("declares protocol version 4", () => {
    expect(PROTOCOL_VERSION).toBe(4);
  });

  it("keeps message names in Swift bridge order", () => {
    expect(MESSAGE_NAMES).toEqual([
      "ready",
      "render",
      "renderComplete",
      "scrollToLine",
      "previewScrolled",
      "linkClicked",
      "checkboxToggled",
      "setTheme",
    ]);
  });
});
