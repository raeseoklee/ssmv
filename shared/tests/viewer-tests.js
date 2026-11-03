// Run in viewer.html after ssmvOpenDiagram is ready. Tests require no network.
async function testMermaidViewer() {
  const checks = [];
  const assert = (condition, name) => { if (!condition) throw new Error(name); checks.push(name); };
  const el = id => document.getElementById(id);
  const input = value => { el('query').value = value; el('query').dispatchEvent(new Event('input')); };
  const key = (value, options = {}) => window.dispatchEvent(new KeyboardEvent('keydown', {key: value, bubbles: true, cancelable: true, ...options}));
  const sources = {
    flowchart: 'flowchart TB\n N["노마디안 (BtoC)<br/>사용자에게 에이전트·자동화 서비스 제공"]\n A["AOS (에이전틱OS)<br/>에이전트 실행, Integration Hub를 통한 외부 서비스 인증 관리"]\n O["OG (오케스트레이션그리드)<br/>사전 구성된 워크플로우를 웹훅으로 실행"]\n N <--> A\n A <--> O',
    c4: 'C4Context\n title SSMV system context\n Person(reader, "Reader", "Reads Markdown documents")\n System(viewer, "SSMV", "Native Markdown viewer")\n System_Ext(source, "Document source", "Local files and HTTPS")\n Rel(reader, viewer, "Reads documents")\n Rel(viewer, source, "Opens documents")',
  };
  for (const [name, source] of Object.entries(sources)) {
    for (const dark of [false, true]) {
      await window.ssmvOpenDiagram(source, dark);
      assert(Boolean(document.querySelector('#diagram svg')), `${name}/${dark}: SVG`);
      assert(document.documentElement.classList.contains('dark') === dark, `${name}/${dark}: theme`);
      input(name === 'flowchart' ? '에이전트' : 'documents');
      assert(el('highlights').children.length >= 2, `${name}/${dark}: label search`);
      assert(el('matches').textContent.startsWith('1/'), `${name}/${dark}: first result`);
      el('next').click();
      assert(el('matches').textContent.startsWith('2/'), `${name}/${dark}: next result`);
      el('previous').click();
      assert(el('matches').textContent.startsWith('1/'), `${name}/${dark}: previous result`);
      window.ssmvViewerCommand('actual-size');
      assert(el('zoom-value').textContent === '100%', `${name}/${dark}: actual size`);
      el('zoom-in').click();
      assert(el('zoom-value').textContent === '125%', `${name}/${dark}: zoom in`);
      el('zoom-out').click();
      assert(el('zoom-value').textContent === '100%', `${name}/${dark}: zoom out`);
      window.ssmvViewerCommand('fit');
      assert(parseInt(el('zoom-value').textContent) <= 100, `${name}/${dark}: fit`);
    }
  }
  input('documents'); window.ssmvFocusSearch();
  key('F3'); assert(el('matches').textContent.startsWith('2/'), 'F3 in search');
  key('g', {metaKey: true, shiftKey: true}); assert(el('matches').textContent.startsWith('1/'), 'Cmd+Shift+G in search');
  input('no-such-label'); assert(el('matches').textContent === '0/0' && el('next').disabled, 'no matches');
  input(''); assert(el('highlights').children.length === 0, 'clear search');
  window.ssmvViewerCommand('find'); assert(document.activeElement === el('query'), 'native find command');
  key('Escape'); assert(document.activeElement === el('viewport'), 'escape search');
  key('f', {ctrlKey: true}); assert(document.activeElement === el('query'), 'Ctrl+F');
  key('Escape'); key('f', {metaKey: true}); assert(document.activeElement === el('query'), 'Cmd+F');
  key('Escape');
  for (let i = 0; i < 40; i++) window.ssmvViewerCommand('zoom-in');
  assert(el('zoom-value').textContent === '400%' && el('zoom-in').disabled, 'maximum zoom');
  for (let i = 0; i < 40; i++) window.ssmvViewerCommand('zoom-out');
  assert(el('zoom-value').textContent === '5%' && el('zoom-out').disabled, 'minimum zoom');
  window.ssmvSetFullscreen(true); assert(el('fullscreen').getAttribute('aria-label') === 'Exit full screen', 'fullscreen state');
  window.ssmvSetFullscreen(false);
  let rejected = false;
  try { await window.ssmvOpenDiagram('invalid diagram'); } catch { rejected = true; }
  assert(rejected && el('message').textContent.includes('could not'), 'error feedback');
  await window.ssmvOpenDiagram(sources.flowchart, false);
  assert(Boolean(document.querySelector('#diagram svg')) && !el('message').textContent, 'recovery');
  assert(!performance.getEntriesByType('resource').some(entry => !entry.name.startsWith(location.origin + '/')), 'offline resources');
  return {passed: checks.length, checks};
}
