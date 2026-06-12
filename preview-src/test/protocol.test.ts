import { describe, expect, it } from "vitest";
import { PROTOCOL_VERSION } from "../src/index";

describe("bridge protocol", () => {
  it("declares protocol version 1", () => {
    expect(PROTOCOL_VERSION).toBe(1);
  });
});
