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
