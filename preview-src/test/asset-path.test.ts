import { describe, expect, it } from "vitest";
import { assetURLPath, workspaceRelativeAssetPath } from "../src/asset-path";

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

  it("preserves existing percent escapes when building asset URLs", () => {
    expect(assetURLPath("content/images/spaced%20pixel.png")).toBe(
      "content/images/spaced%20pixel.png",
    );
  });

  it("escapes raw asset URL delimiters without double-encoding valid escapes", () => {
    expect(assetURLPath("content/images/a 100% done?#.png")).toBe(
      "content/images/a%20100%25%20done%3F%23.png",
    );
  });
});
