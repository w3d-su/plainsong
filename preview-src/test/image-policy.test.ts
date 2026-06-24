import { describe, expect, it } from "vitest";
import { imageSourcePolicy } from "../src/image-policy";

describe("preview image source policy", () => {
  it("rewrites workspace-relative images through asset URLs", () => {
    expect(imageSourcePolicy("../images/pixel.png", "content/posts", false)).toEqual({
      action: "rewrite",
      src: "asset://content/images/pixel.png",
    });
  });

  it("keeps bundled asset and data images", () => {
    expect(imageSourcePolicy("asset://content/image.png", null, false)).toEqual({ action: "keep" });
    expect(imageSourcePolicy("data:image/png;base64,AAA=", null, false)).toEqual({ action: "keep" });
  });

  it("blocks https images unless the user enables remote images", () => {
    expect(imageSourcePolicy("https://example.com/image.png", null, false)).toEqual({
      action: "block",
      reason: "remote-disabled",
    });
    expect(imageSourcePolicy("https://example.com/image.png", null, true)).toEqual({ action: "keep" });
  });

  it("blocks http and script-like schemes even when remote images are enabled", () => {
    expect(imageSourcePolicy("http://example.com/image.png", null, true)).toEqual({
      action: "block",
      reason: "unsupported-scheme",
    });
    expect(imageSourcePolicy("javascript:alert(1)", null, true)).toEqual({
      action: "block",
      reason: "unsupported-scheme",
    });
  });
});
