import { describe, expect, it } from "vitest";
import { imageSourcePolicy } from "../src/image-policy";

describe("preview image source policy", () => {
  it("rewrites workspace-relative images through asset URLs", () => {
    expect(imageSourcePolicy("../images/pixel.png", "content/posts", false)).toEqual({
      action: "rewrite",
      src: "asset://content/images/pixel.png",
    });
  });

  it("keeps bundled asset and raster data images", () => {
    expect(imageSourcePolicy("asset://content/image.png", null, false)).toEqual({ action: "keep" });
    for (const source of [
      "data:image/png;base64,AAA=",
      "data:image/jpeg;base64,AAA=",
      "data:image/gif;base64,AAA=",
      "data:image/webp;base64,AAA=",
      "data:IMAGE/PNG;base64,AAA=",
    ]) {
      expect(imageSourcePolicy(source, null, false)).toEqual({ action: "keep" });
    }
  });

  it("blocks non-raster data sources", () => {
    for (const source of [
      "data:image/svg+xml;base64,AAA=",
      "data:text/html,<script>alert(1)</script>",
      "data:application/octet-stream;base64,AAA=",
      "data:;base64,AAA=",
      "data:,AAA=",
      "data:image/avif;base64,AAA=",
    ]) {
      expect(imageSourcePolicy(source, null, true)).toEqual({
        action: "block",
        reason: "unsupported-data-image",
      });
    }
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
