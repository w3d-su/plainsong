import { describe, expect, it } from "vitest";
import { rewriteImageSources } from "../src/image-rewrite";

class FakeImage {
  dataset: Record<string, string> = {};
  private attributes = new Map<string, string>();

  constructor(source: string) {
    this.src = source;
  }

  get src(): string {
    return this.attributes.get("src") ?? "";
  }

  set src(value: string) {
    this.attributes.set("src", value);
  }

  getAttribute(name: string): string | null {
    return this.attributes.get(name) ?? null;
  }

  removeAttribute(name: string): void {
    this.attributes.delete(name);
  }
}

class FakeRoot {
  constructor(private readonly images: FakeImage[]) {}

  querySelectorAll(selector: string): NodeListOf<HTMLImageElement> {
    if (selector === "picture > source") return [] as unknown as NodeListOf<HTMLImageElement>;
    expect(selector).toBe("img");
    return this.images as unknown as NodeListOf<HTMLImageElement>;
  }
}

describe("preview image source rewriting", () => {
  it("blocks disabled remote images on the detached render root before morphdom", () => {
    const image = new FakeImage("https://example.com/pixel.png");
    const nextRoot = new FakeRoot([image]) as unknown as ParentNode;

    rewriteImageSources(nextRoot, null, false);

    expect(image.getAttribute("src")).toBeNull();
    expect(image.dataset.plainsongOriginalSrc).toBe("https://example.com/pixel.png");
    expect(image.dataset.plainsongBlockedSrc).toBe("https://example.com/pixel.png");
  });

  it("rewrites workspace-relative images against the supplied root", () => {
    const image = new FakeImage("../images/pixel.png");
    const nextRoot = new FakeRoot([image]) as unknown as ParentNode;

    rewriteImageSources(nextRoot, "content/posts", false);

    expect(image.getAttribute("src")).toBe("asset://content/images/pixel.png");
    expect(image.dataset.plainsongOriginalSrc).toBe("../images/pixel.png");
    expect(image.dataset.plainsongBlockedSrc).toBeUndefined();
  });
});

import { test as reviewTest, expect as reviewExpect } from "vitest";
import { rewriteImageSources as rewriteForReview } from "../src/image-rewrite";
import { imageSourcePolicy as policyForReview } from "../src/image-policy";

reviewTest("drops picture sources and srcset candidates that bypass the image policy", () => {
  const root = document.createElement("main");
  root.innerHTML =
    '<picture><source srcset="https://example.com/a.png"><source srcset="data:image/svg+xml,%3Csvg/%3E">' +
    '<img src="a.png" srcset="https://example.com/b.png 2x"></picture>';
  rewriteForReview(root, null, false);
  reviewExpect(root.querySelector("source")).toBeNull();
  reviewExpect(root.querySelector("img")?.hasAttribute("srcset")).toBe(false);
  reviewExpect(root.querySelector("img")?.getAttribute("src")).toBe("asset://a.png");
});

reviewTest("keeps authority-unsafe first segments inside the asset URL", () => {
  for (const [source, host] of [
    ["[slug]/cover.png", "%5Bslug%5D"],
    ["screenshot@2x.png", "screenshot%402x.png"],
    ["./foo:80/a.png", "foo%3A80"],
  ]) {
    const policy = policyForReview(source, null, false, "root-1");
    reviewExpect(policy.action).toBe("rewrite");
    if (policy.action !== "rewrite") continue;
    const url = new URL(policy.src);
    reviewExpect(url.host).toBe(host);
    reviewExpect(url.username).toBe("");
  }
});
