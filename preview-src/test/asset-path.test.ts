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

  it("ignores leading, trailing, and repeated slashes in the base directory", () => {
    expect(workspaceRelativeAssetPath("images/pixel.png", "//content//posts//")).toBe(
      "content/posts/images/pixel.png",
    );
    expect(workspaceRelativeAssetPath("images/pixel.png", "///")).toBe("images/pixel.png");
    expect(workspaceRelativeAssetPath("images/pixel.png", "")).toBe("images/pixel.png");
  });

  it("handles a base directory with a long run of slashes in linear time", () => {
    const baseDir = `content${"/".repeat(200_000)}posts`;
    const start = performance.now();
    const result = workspaceRelativeAssetPath("pixel.png", baseDir);
    const elapsed = performance.now() - start;

    expect(result).toBe("content/posts/pixel.png");
    // The trimming regex this replaced took 56 s on this input (3.5 s at 50,000 slashes).
    expect(elapsed).toBeLessThan(1000);
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
