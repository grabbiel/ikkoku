// Progressive enhancement: all component content and documentation work without JS.
(() => {
  const cards = [...document.querySelectorAll('.component')];
  const search = document.querySelector('#search');
  const group = document.querySelector('#group');
  const stage = document.querySelector('#stage');
  const count = document.querySelector('#result-count');
  const text = new Map(cards.map(card => [card, card.textContent.toLowerCase()]));
  function filter() {
    const terms = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    let shown = 0;
    for (const card of cards) {
      const match = (group.value === 'all' || card.dataset.group === group.value)
        && (stage.value === 'all' || card.dataset.stage === stage.value)
        && terms.every(term => text.get(card).includes(term));
      card.hidden = !match;
      shown += Number(match);
    }
    count.textContent = `${shown} of ${cards.length} components shown`;
    document.querySelector('#empty').hidden = shown !== 0;
  }
  function clear() { search.value = ''; group.value = 'all'; stage.value = 'all'; filter(); }
  function revealHash() {
    const id = location.hash.slice(1);
    const target = cards.find(card => card.id === id);
    if (target && target.hidden) { clear(); target.scrollIntoView(); }
  }
  document.querySelector('.filters').hidden = false;
  search.addEventListener('input', filter);
  group.addEventListener('change', filter);
  stage.addEventListener('change', filter);
  document.querySelector('#reset').addEventListener('click', () => { clear(); search.focus(); });
  document.querySelectorAll('.sidebar a').forEach(link => link.addEventListener('click', clear));
  window.addEventListener('hashchange', revealHash);
  filter(); revealHash();
})();
