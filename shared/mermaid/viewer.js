import './renderer.js';

const byId = id => document.getElementById(id);
const viewport = byId('viewport'), surface = byId('surface'), stage = byId('stage');
const query = byId('query'), highlights = byId('highlights');
let width = 0, height = 0, zoom = 1, fitting = true, fullScreen = false;
let labels = [], matches = [], current = -1, opening = false;
const clamp = value => Math.min(4, Math.max(0.05, value));

function nativeAction(action) {
  const message = { action };
  if (window.webkit?.messageHandlers?.ssmvViewer) window.webkit.messageHandlers.ssmvViewer.postMessage(message);
  else if (window.chrome?.webview) window.chrome.webview.postMessage(message);
}
function layout() {
  const w = Math.max(viewport.clientWidth, width * zoom + 48);
  const h = Math.max(viewport.clientHeight, height * zoom + 48);
  surface.style.width = `${w}px`; surface.style.height = `${h}px`;
  stage.style.left = `${(w - width * zoom) / 2}px`;
  stage.style.top = `${(h - height * zoom) / 2}px`;
  stage.style.transform = `scale(${zoom})`;
  byId('zoom-value').textContent = `${Math.round(zoom * 100)}%`;
  byId('zoom-out').disabled = !width || zoom <= 0.05;
  byId('zoom-in').disabled = !width || zoom >= 4;
}
function setZoom(value, x = viewport.clientWidth / 2, y = viewport.clientHeight / 2) {
  if (!width) return;
  const beforeX = (viewport.scrollLeft + x - stage.offsetLeft) / zoom;
  const beforeY = (viewport.scrollTop + y - stage.offsetTop) / zoom;
  zoom = clamp(value); fitting = false; layout();
  viewport.scrollLeft = beforeX * zoom + stage.offsetLeft - x;
  viewport.scrollTop = beforeY * zoom + stage.offsetTop - y;
}
function fit() {
  if (!width) return;
  fitting = true;
  zoom = clamp(Math.min(1, (viewport.clientWidth - 48) / width, (viewport.clientHeight - 48) / height));
  layout(); viewport.scrollLeft = 0; viewport.scrollTop = 0;
}
function showCurrent() {
  [...highlights.children].forEach((el, i) => el.classList.toggle('current', i === current));
  const found = matches[current];
  if (found) {
    const box = found.getBoundingClientRect(), area = viewport.getBoundingClientRect();
    viewport.scrollLeft += box.left + box.width / 2 - area.left - area.width / 2;
    viewport.scrollTop += box.top + box.height / 2 - area.top - area.height / 2;
  }
  byId('matches').textContent = query.value.trim() ? (matches.length ? `${current + 1}/${matches.length}` : '0/0') : '';
  byId('matches').setAttribute('aria-label', matches.length ? `Matching label ${current + 1} of ${matches.length}` : 'No matching labels');
  byId('previous').disabled = byId('next').disabled = !matches.length;
}
function search() {
  const term = query.value.trim().toLocaleLowerCase();
  matches = term ? labels.filter(el => el.textContent.toLocaleLowerCase().includes(term)) : [];
  highlights.replaceChildren();
  const origin = stage.getBoundingClientRect();
  for (const label of matches) {
    const box = label.getBoundingClientRect(), mark = document.createElement('div');
    mark.className = 'match';
    mark.style.left = `${(box.left - origin.left) / zoom - 3}px`;
    mark.style.top = `${(box.top - origin.top) / zoom - 3}px`;
    mark.style.width = `${box.width / zoom + 6}px`;
    mark.style.height = `${box.height / zoom + 6}px`;
    highlights.append(mark);
  }
  current = matches.length ? 0 : -1; showCurrent();
}
function moveMatch(backwards) {
  if (!matches.length) return;
  current = (current + (backwards ? -1 : 1) + matches.length) % matches.length;
  showCurrent();
}
window.ssmvFocusSearch = () => { query.focus(); query.select(); };
window.ssmvSetFullscreen = value => {
  fullScreen = Boolean(value);
  byId('fullscreen').setAttribute('aria-label', fullScreen ? 'Exit full screen' : 'Enter full screen');
  byId('fullscreen').title = fullScreen ? 'Exit full screen' : 'Full screen';
};
window.ssmvOpenDiagram = async (source, dark = false) => {
  if (opening) throw new Error('A diagram is already opening.');
  opening = true; width = height = 0; labels = []; query.value = ''; search(); layout();
  document.documentElement.classList.toggle('dark', dark);
  byId('message').textContent = 'Loading diagram…';
  try {
    const size = await window.ssmvRender(source, dark);
    width = size.width; height = size.height;
    // Each HTML or SVG label is one result, avoiding duplicate nested span/tspan hits.
    labels = [...document.querySelectorAll('#diagram foreignObject, #diagram svg text')]
      .filter(el => el.textContent.trim() && el.getBoundingClientRect().width > 0);
    byId('message').textContent = ''; fit(); viewport.focus();
    return size;
  } catch (error) {
    byId('message').textContent = 'This diagram could not be displayed. Close this view to read its source.';
    throw error;
  } finally { opening = false; }
};
window.ssmvViewerCommand = action => {
  if (action === 'find') window.ssmvFocusSearch();
  else if (action === 'zoom-in') setZoom(zoom * 1.25);
  else if (action === 'zoom-out') setZoom(zoom / 1.25);
  else if (action === 'actual-size') setZoom(1);
  else if (action === 'fit') fit();
};
byId('zoom-in').onclick = () => setZoom(zoom * 1.25);
byId('zoom-out').onclick = () => setZoom(zoom / 1.25);
byId('actual-size').onclick = () => setZoom(1);
byId('fit').onclick = fit;
byId('fullscreen').onclick = () => nativeAction('fullscreen');
byId('close').onclick = () => nativeAction('close');
query.addEventListener('input', search);
byId('previous').onclick = () => moveMatch(true);
byId('next').onclick = () => moveMatch(false);
query.addEventListener('keydown', event => {
  if (event.key === 'Enter') { event.preventDefault(); moveMatch(event.shiftKey); }
});
window.addEventListener('keydown', event => {
  const command = event.metaKey || event.ctrlKey;
  if (event.ctrlKey && event.metaKey && event.key.toLowerCase() === 'f') { event.preventDefault(); nativeAction('fullscreen'); return; }
  if (command && event.key.toLowerCase() === 'f') { event.preventDefault(); window.ssmvFocusSearch(); return; }
  if (event.key === 'F11') { event.preventDefault(); nativeAction('fullscreen'); return; }
  if (event.key === 'Escape') {
    event.preventDefault();
    if (query.value || document.activeElement === query) { query.value = ''; search(); viewport.focus(); }
    else nativeAction(fullScreen ? 'fullscreen' : 'close');
    return;
  }
  if (event.key === 'F3' || (command && event.key.toLowerCase() === 'g')) { event.preventDefault(); moveMatch(event.shiftKey); return; }
  if (document.activeElement === query) return;
  if (['+', '='].includes(event.key)) { event.preventDefault(); setZoom(zoom * 1.25); }
  else if (event.key === '-') { event.preventDefault(); setZoom(zoom / 1.25); }
  else if (event.key === '0') { event.preventDefault(); fit(); }
  else if (event.key === '1') { event.preventDefault(); setZoom(1); }

});
viewport.addEventListener('wheel', event => {
  if (!event.ctrlKey && !event.metaKey) return;
  event.preventDefault();
  const area = viewport.getBoundingClientRect();
  setZoom(zoom * Math.exp(-event.deltaY * 0.005), event.clientX - area.left, event.clientY - area.top);
}, { passive: false });
let drag;
viewport.addEventListener('pointerdown', event => {
  if (event.button !== 0) return;
  drag = { x: event.clientX, y: event.clientY, left: viewport.scrollLeft, top: viewport.scrollTop };
  viewport.setPointerCapture(event.pointerId); viewport.classList.add('dragging'); viewport.focus();
});
viewport.addEventListener('pointermove', event => {
  if (!drag) return;
  viewport.scrollLeft = drag.left - event.clientX + drag.x;
  viewport.scrollTop = drag.top - event.clientY + drag.y;
});
function endDrag() { drag = null; viewport.classList.remove('dragging'); }
viewport.addEventListener('pointerup', endDrag);
viewport.addEventListener('pointercancel', endDrag);
viewport.addEventListener('lostpointercapture', endDrag);
window.addEventListener('resize', () => fitting ? fit() : layout());
layout();
