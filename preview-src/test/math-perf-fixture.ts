export function distinctFormulas(source: string): string {
  return source.split("## Section\n").map((section, index) => {
    const exponent = `{${index}}`;
    return section.replaceAll("mc^2", "mc^" + exponent)
      .replaceAll("x^2", "x^" + exponent)
      .replace(" a & b", ` ${index} & b`)
      .replace("x_i^2", "x_i^" + exponent)
      .replace("\\sum_{k=1}^{n}", `\\sum_{k=1}^${exponent}`);
  }).join("## Section\n");
}
