type Theme = 'graphite' | 'ivory';

const root = document.documentElement;
const themeToggle = document.querySelector<HTMLButtonElement>('[data-toggle-theme]');

function setTheme(theme: Theme, persist = true) {
  root.dataset.theme = theme;
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', theme === 'graphite' ? '#1C1D1C' : '#DDDEDC');
  document.querySelectorAll<HTMLElement>('[data-current-theme]').forEach((label) => {
    label.textContent = label.dataset[theme] ?? theme;
  });
  if (themeToggle) {
    themeToggle.setAttribute('aria-checked', String(theme === 'ivory'));
    themeToggle.title = theme === 'graphite' ? themeToggle.dataset.labelIvory! : themeToggle.dataset.labelGraphite!;
  }
  if (persist) {
    try { localStorage.setItem('phosdeck.website.theme', theme); } catch { /* The controls also work without persistent storage. */ }
  }
}

setTheme(root.dataset.theme === 'ivory' ? 'ivory' : 'graphite', false);
themeToggle?.addEventListener('click', () => setTheme(root.dataset.theme === 'graphite' ? 'ivory' : 'graphite'));

const tabs = [...document.querySelectorAll<HTMLButtonElement>('[data-workflow-tab]')];
const panels = [...document.querySelectorAll<HTMLElement>('[data-workflow-panel]')];

function selectTab(index: number, focus = false) {
  tabs.forEach((tab, i) => {
    tab.setAttribute('aria-selected', String(i === index));
    tab.tabIndex = i === index ? 0 : -1;
    panels[i].hidden = i !== index;
  });
  if (focus) tabs[index].focus();
}

if (tabs.length && tabs.length === panels.length) {
  panels.forEach((panel, i) => {
    panel.setAttribute('role', 'tabpanel');
    panel.setAttribute('aria-labelledby', tabs[i].id);
    panel.tabIndex = 0;
  });
  selectTab(0);
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => selectTab(index));
    tab.addEventListener('keydown', (event) => {
      const next = event.key === 'ArrowRight' ? (index + 1) % tabs.length
        : event.key === 'ArrowLeft' ? (index - 1 + tabs.length) % tabs.length
        : event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : undefined;
      if (next !== undefined) {
        event.preventDefault();
        selectTab(next, true);
      }
    });
  });
  document.querySelector<HTMLElement>('[data-workflow-tabs]')!.hidden = false;
}

const copyButton = document.querySelector<HTMLButtonElement>('[data-copy-commands]');
copyButton?.addEventListener('click', async () => {
  const feedback = document.querySelector<HTMLElement>('[data-copy-feedback]')!;
  try {
    await navigator.clipboard.writeText(document.querySelector('[data-build-commands]')!.textContent!);
    feedback.textContent = copyButton.dataset.copied!;
  } catch {
    feedback.textContent = copyButton.dataset.failed!;
  }
});

document.querySelectorAll<HTMLElement>('[data-enhance]').forEach((element) => { element.hidden = false; });
