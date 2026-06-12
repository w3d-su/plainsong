import { describe, expect, it } from "vitest";
import { workspaceRelativeAssetPath } from "../src/asset-path";

describe("workspace asset paths", () => {
  it("joins image sources against the workspace-relative base directory", () => {
    expect(workspaceRelativeAssetPath("images/pixel.png", "content/posts")).toBe(
      "content/posts/images/pixel.png",
    );
  });

  it("normalizes parent-directory segments before building asset URLs", () => {
    expect(workspaceRelativeAssetPath("../images/pixel.png", "content/posts")).toBe(
      "content/images/pixel.png",
    );
  });

  it("normalizes backslashes and current-directory segments", () => {
    expect(workspaceRelativeAssetPath(".\\images\\pixel.png", "content/posts/")).toBe(
      "content/posts/images/pixel.png",
    );
  });

  it("preserves leading parent segments so native containment still rejects escapes", () => {
    expect(workspaceRelativeAssetPath("../secret.png", null)).toBe("../secret.png");
  });
});
