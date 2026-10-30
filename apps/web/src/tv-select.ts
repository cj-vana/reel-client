/** TV choice lists use the same remote focus system as the surrounding screen. */
export function installTVChoices() {
  let open: { select: HTMLSelectElement; layer: HTMLElement; observer: MutationObserver; siblings: { node: HTMLElement; inert: boolean }[] } | undefined;
  const isTV = () => document.documentElement.dataset.layout === 'tv';
  function close(restore = true) {
    const current = open; if (!current) return;
    open = undefined; current.observer.disconnect(); current.layer.remove();
    for (const sibling of current.siblings) if (sibling.node.isConnected) sibling.node.toggleAttribute('inert', sibling.inert);
    current.select.removeAttribute('aria-expanded');
    if (restore && current.select.isConnected && !current.select.closest('[hidden],[inert]')) current.select.focus({ preventScroll: true });
  }
  function change(select: HTMLSelectElement, index: number) {
    const option = select.options[index];
    if (!option || option.disabled || select.disabled || select.selectedIndex === index) return;
    select.selectedIndex = index;
    select.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function show(select: HTMLSelectElement) {
    if (select.disabled || select.multiple || select.closest('[hidden],[inert]')) return;
    close(false);
    const layer = document.createElement('section'); layer.className = 'tv-choice-layer'; layer.setAttribute('role', 'dialog'); layer.setAttribute('aria-modal', 'true');
    const name = select.getAttribute('aria-label') || select.labels?.[0]?.childNodes[0]?.textContent?.trim() || 'Choose an option';
    layer.setAttribute('aria-label', name);
    const panel = document.createElement('div'); panel.className = 'tv-choice-panel'; layer.append(panel);
    const header = document.createElement('header'), heading = document.createElement('h2'), dismiss = document.createElement('button');
    heading.textContent = name; dismiss.textContent = 'Done'; dismiss.className = 'button quiet'; dismiss.setAttribute('aria-label', 'Close choices');
    dismiss.addEventListener('click', () => close()); header.append(heading, dismiss); panel.append(header);
    const list = document.createElement('div'); list.className = 'tv-choice-options'; list.setAttribute('role', 'listbox'); list.setAttribute('aria-label', name); panel.append(list);
    let selected: HTMLButtonElement | undefined;
    for (const [index, option] of [...select.options].entries()) {
      const button = document.createElement('button'); button.type = 'button'; button.textContent = option.label; button.disabled = option.disabled;
      button.setAttribute('role', 'option'); button.setAttribute('aria-selected', String(index === select.selectedIndex));
      button.addEventListener('click', () => { if (open?.layer !== layer) return; close(); if (select.isConnected && !select.closest('[hidden],[inert],[aria-hidden="true"]')) change(select, index); }); list.append(button);
      if (index === select.selectedIndex && !option.disabled) selected = button;
    }
    const host = document.fullscreenElement instanceof HTMLElement ? document.fullscreenElement : document.body;
    const siblings = [...host.children].filter((node): node is HTMLElement => node instanceof HTMLElement).map(node => ({ node, inert: node.hasAttribute('inert') }));
    host.append(layer); for (const sibling of siblings) sibling.node.setAttribute('inert', '');
    select.setAttribute('aria-expanded', 'true');
    const observer = new MutationObserver(() => {
      const inheritedInert = [...select.ownerDocument.querySelectorAll<HTMLElement>('[inert]')].some(node => node.contains(select) && !siblings.some(sibling => sibling.node === node && !sibling.inert));
      if (!select.isConnected || select.disabled || select.closest('[hidden],[aria-hidden="true"]') || inheritedInert || !select.getClientRects().length || getComputedStyle(select).visibility === 'hidden') close(false);
    });
    open = { select, layer, observer, siblings }; observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['disabled', 'hidden', 'inert', 'aria-hidden', 'style', 'class'] });
    layer.addEventListener('click', event => { if (event.target === layer) close(); });
    (selected ?? list.querySelector<HTMLButtonElement>('button:not([disabled])') ?? dismiss).focus();
    selected?.scrollIntoView({ block: 'nearest' });
  }
  document.addEventListener('pointerdown', event => {
    if (!isTV() || !(event.target instanceof HTMLSelectElement)) return;
    event.preventDefault(); show(event.target);
  });
  return {
    scope: () => open?.layer,
    key(event: KeyboardEvent): boolean {
      if (!isTV()) return false;
      if (open && (event.key === 'Escape' || event.key === 'BrowserBack' || event.keyCode === 461)) { event.preventDefault(); close(); return true; }
      const select = document.activeElement;
      if (!(select instanceof HTMLSelectElement) || select.disabled || select.multiple) return false;
      if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); show(select); return true; }
      if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
        event.preventDefault(); const step = event.key === 'ArrowLeft' ? -1 : 1;
        let index = select.selectedIndex + step;
        while (index >= 0 && index < select.options.length && select.options[index].disabled) index += step;
        change(select, index); return true;
      }
      return false;
    }
  };
}
