const legacyRoles: Array<[string, string]> = [
  ['.neo-nav-item', 'nav-item'],
  ['.neo-resource', 'resource'],
  ['.neo-planetbar', 'planetbar'],
  ['.neo-overview-grid', 'overview'],
  ['.neo-planet-row', 'planet-row'],
  ['.neo-owned-planets', 'owned-planets'],
  ['.neo-main-content', 'main-content'],
  ['.neo-definition', 'definition'],
  ['.neo-queue', 'queue'],
  ['.neo-list-row', 'list-row'],
  ['.neo-message-list', 'message-list'],
  ['.neo-panel', 'panel'],
  ['.neo-panel-header', 'panel-header'],
  ['.neo-section-head', 'section-head'],
  ['.neo-page-head', 'page-head'],
  ['.neo-card-grid', 'card-grid'],
  ['.neo-main', 'main'],
  ['.neo-shell', 'shell'],
  ['.neo-sidebar', 'sidebar'],
]

function markLegacyElements() {
  for (const [selector, role] of legacyRoles) {
    document.querySelectorAll<HTMLElement>(selector).forEach((element) => {
      element.dataset.lgRole = role
      element.classList.add(`lg-${role}`)
    })
  }
}

function startLegacyAdapter() {
  markLegacyElements()
  const observer = new MutationObserver(markLegacyElements)
  observer.observe(document.body, { childList: true, subtree: true })
  window.addEventListener('beforeunload', () => observer.disconnect(), { once: true })
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', startLegacyAdapter, { once: true })
} else {
  startLegacyAdapter()
}
