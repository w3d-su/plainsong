import type { PreviewMathSlots } from "./math-fragments";

const liveMath = new WeakMap<Element, string>();

export class MathDOMPatch {
  private readonly nextMath = new WeakMap<Element, string>();
  private readonly changed = new Map<Element, string>();

  constructor(root: HTMLElement, slots?: PreviewMathSlots) {
    if (!slots?.html.length) return;
    for (const slot of root.querySelectorAll<HTMLElement>("[data-plainsong-math-slot]")) {
      const wrapper = slot.parentElement!;
      const html = slots.html[Number(slot.dataset.plainsongMathSlot)];
      this.nextMath.set(wrapper, html);
      slot.remove();
    }
  }

  updateChildren(live: Element, next: Element): boolean {
    const html = this.nextMath.get(next);
    if (html === undefined) {
      liveMath.delete(live);
      return true;
    }
    if (liveMath.get(live) !== html) this.changed.set(live, html);
    return false;
  }

  added(node: Node): void {
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const element = node as Element;
    const html = this.nextMath.get(element);
    if (html !== undefined) this.changed.set(element, html);
  }

  finish(): void {
    const templates = new Map<string, HTMLTemplateElement>();
    for (const [element, html] of this.changed) {
      let template = templates.get(html);
      if (!template) {
        template = document.createElement("template");
        template.innerHTML = html;
        templates.set(html, template);
      }
      element.replaceChildren(template.content.cloneNode(true));
      liveMath.set(element, html);
    }
  }
}
