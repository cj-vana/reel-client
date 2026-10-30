/** Remote targets stay focusable without opening the system keyboard until selected. */
export function installTVConnectionForm(form: HTMLFormElement): () => void {
  form.noValidate = true;
  form.classList.add('tv-connect-form');
  const fields = new Map<HTMLInputElement, HTMLButtonElement>();
  let editor: HTMLElement | undefined;
  let editing: HTMLInputElement | undefined;
  let entry: HTMLInputElement | undefined;
  let keyboardVisible = false;

  const describe = (field: HTMLInputElement, button: HTMLButtonElement) => {
    const name = field.name === 'server' ? 'Server address' : field.name === 'username' ? 'Username' : 'Password';
    const value = field.type === 'password' ? (field.value ? 'Password entered' : 'Enter password') : field.value || (field.name === 'server' ? 'Your Jellyfin address' : 'Your username');
    button.querySelector('.tv-field-value')!.textContent = value;
    button.setAttribute('aria-label', name + ': ' + value + '. Select to edit');
  };
  const close = (save: boolean, restore = true) => {
    if (!editor || !editing || !entry) return;
    const field = editing, button = fields.get(field)!;
    if (save) field.value = entry.value;
    entry.value = ''; entry.blur();
    editor.remove(); editor = undefined; editing = undefined; entry = undefined;
    describe(field, button);
    if (restore && button.isConnected) button.focus({ preventScroll: true });
  };
  const open = (field: HTMLInputElement) => {
    if (field.disabled || editor) return;
    editing = field;
    editor = document.createElement('section'); editor.id = 'tv-entry-editor';
    editor.className = 'tv-entry-editor'; editor.setAttribute('role', 'dialog'); editor.setAttribute('aria-modal', 'true'); editor.setAttribute('aria-labelledby', 'tv-entry-title');
    editor.innerHTML = '<div class="tv-entry-panel"><div class="tv-entry-heading"><h2 id="tv-entry-title"></h2></div><label class="tv-entry-label"><span class="sr-only">Text entry</span><input id="tv-entry-input" /></label><div class="tv-entry-actions"><button type="button" class="button primary" id="tv-entry-done">Done</button><button type="button" class="button quiet" id="tv-entry-cancel">Cancel</button></div><p class="field-note">Finish typing, then choose Done. Back returns to your connection.</p></div>';
    const title = field.name === 'server' ? 'Server address' : field.name === 'username' ? 'Username' : 'Password';
    editor.querySelector('#tv-entry-title')!.textContent = title;
    entry = editor.querySelector<HTMLInputElement>('#tv-entry-input')!;
    entry.type = field.type; entry.value = field.value; entry.placeholder = field.placeholder;
    entry.autocomplete = field.autocomplete; entry.setAttribute('aria-label', title);
    entry.spellcheck = false; entry.setAttribute('autocapitalize', 'none');
    if (field.type === 'password') {
      const reveal = document.createElement('button'); reveal.type = 'button'; reveal.className = 'button quiet'; reveal.id = 'tv-entry-reveal';
      reveal.textContent = 'Show password'; reveal.setAttribute('aria-pressed', 'false');
      reveal.addEventListener('click', () => {
        if (!entry) return;
        const showing = entry.type === 'password'; entry.type = showing ? 'text' : 'password';
        reveal.textContent = showing ? 'Hide password' : 'Show password'; reveal.setAttribute('aria-pressed', String(showing));
      });
      editor.querySelector('.tv-entry-actions')!.append(reveal);
    }
    editor.querySelector('#tv-entry-done')!.addEventListener('click', () => close(true));
    editor.querySelector('#tv-entry-cancel')!.addEventListener('click', () => close(false));
    document.querySelector('#app')!.append(editor);
    entry.focus();
  };
  for (const field of form.querySelectorAll<HTMLInputElement>('input:not([type="checkbox"])')) {
    const label = field.closest('label'); if (!label) continue;
    const wrapper = document.createElement('div'); wrapper.className = 'tv-field-wrap';
    const button = document.createElement('button'); button.type = 'button'; button.className = 'tv-field'; button.dataset.tvField = field.name;
    const caption = document.createElement('span'); caption.className = 'tv-field-label'; caption.textContent = field.name === 'server' ? 'Server address' : field.name === 'username' ? 'Username' : 'Password';
    const value = document.createElement('strong'); value.className = 'tv-field-value';
    const edit = document.createElement('span'); edit.className = 'tv-field-edit'; edit.textContent = 'Edit'; edit.setAttribute('aria-hidden', 'true');
    button.append(caption, value, edit); button.disabled = field.disabled;
    field.hidden = true; field.tabIndex = -1;
    wrapper.append(button, field); label.replaceWith(wrapper); fields.set(field, button); describe(field, button);
    button.addEventListener('click', () => open(field));
  }
  const remember = form.querySelector<HTMLInputElement>('input[name="remember"]')!;
  const rememberLabel = remember.closest('label')!;
  const rememberButton = document.createElement('button'); rememberButton.type = 'button'; rememberButton.id = 'tv-remember-connection'; rememberButton.className = 'tv-remember'; rememberButton.setAttribute('role', 'checkbox'); rememberButton.setAttribute('aria-label', 'Remember this connection on this TV'); rememberButton.disabled = remember.disabled;
  rememberButton.innerHTML = '<span class="tv-check" aria-hidden="true"></span><span>Remember on this TV<small>Your password is never saved.</small></span>';
  const updateRemember = () => { rememberButton.setAttribute('aria-checked', String(remember.checked)); rememberButton.classList.toggle('checked', remember.checked); };
  remember.hidden = true; remember.tabIndex = -1;
  const rememberWrap = document.createElement('div'); rememberWrap.append(rememberButton, remember); rememberLabel.replaceWith(rememberWrap); updateRemember();
  rememberButton.addEventListener('click', () => { if (!remember.disabled) { remember.checked = !remember.checked; updateRemember(); } });

  const validate = (event: Event) => {
    for (const [field, button] of fields) {
      if ((field.required && !field.value.trim()) || (field.type === 'url' && field.value && !field.validity.valid)) {
        event.preventDefault(); event.stopImmediatePropagation();
        form.querySelector('#connection-error')!.textContent = field.name === 'server' ? 'Enter your complete Jellyfin address, including http:// or https://.' : 'Enter your Jellyfin username.';
        button.focus(); return;
      }
    }
  };
  const keyboard = (event: KeyboardEvent) => {
    if (!editor) return;
    const isBack = event.key === 'Escape' || event.key === 'BrowserBack' || event.keyCode === 461;
    if (event.isComposing) {
      if (isBack) event.stopImmediatePropagation();
      return;
    }
    if (isBack) {
      event.preventDefault(); event.stopImmediatePropagation(); close(true);
    } else if ((event.key === 'Enter' || event.keyCode === 13) && event.target === entry && !keyboardVisible) {
      event.preventDefault(); event.stopImmediatePropagation(); close(true);
    } else if (event.key === 'ArrowDown' && event.target === entry && !keyboardVisible) {
      // The TV consumes arrows while its keyboard is open. After it closes,
      // the input must also have a remote route to Done and Cancel.
      event.preventDefault(); event.stopImmediatePropagation();
      editor.querySelector<HTMLButtonElement>('#tv-entry-done')!.focus();
    }
  };
  const keyboardVisibility = (event: Event) => {
    const visible = (event as CustomEvent<{ visibility?: boolean }>).detail?.visibility;
    if (typeof visible === 'boolean') keyboardVisible = visible;
    // Do not blur on false: the voice-input UI temporarily hides the keyboard.
  };
  form.addEventListener('submit', validate, true);
  document.addEventListener('keydown', keyboard, true);
  document.addEventListener('keyboardStateChange', keyboardVisibility);
  return () => { close(false, false); document.removeEventListener('keydown', keyboard, true); document.removeEventListener('keyboardStateChange', keyboardVisibility); form.removeEventListener('submit', validate, true); };
}
