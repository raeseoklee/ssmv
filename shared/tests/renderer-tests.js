// Run this function in the bundled renderer page after ssmvRender is ready.
async function testMermaidRenderer() {
  const fixtures = {
    flowchart: 'flowchart TB\n A["사용자<br/>자동화 서비스"] <--> B["에이전트 실행"]',
    sequence: 'sequenceDiagram\n Alice->>Bob: Hello',
    mindmap: 'mindmap\n  root((SSMV))\n    macOS\n    Windows',
    architecture: 'architecture-beta\n service db(database)[Database]\n service server(server)[Server]\n db:R -- L:server',
    math: 'flowchart LR\n A["$$x^2 + y^2 = z^2$$"] --> B["수학"]',
    class: 'classDiagram\n class Document\n Document : +open()',
    state: 'stateDiagram-v2\n [*] --> Reading\n Reading --> [*]',
    er: 'erDiagram\n AUTHOR ||--o{ DOCUMENT : writes',
    gantt: 'gantt\n dateFormat YYYY-MM-DD\n section Build\n Render :2026-01-01, 2d',
    pie: 'pie\n "Read" : 70\n "Navigate" : 30',
  };
  const results = [];
  for (const [name, source] of Object.entries(fixtures)) {
    for (const dark of [false, true]) {
      const result = await window.ssmvRender(source, dark);
      if (!(result.width > 16 && result.height > 16) || !document.querySelector('#diagram svg')) throw new Error(name);
      if (name === 'math' && !document.querySelector('#diagram .katex')) throw new Error('Missing math');
      if (document.querySelector('#diagram script, #diagram iframe, #diagram image')) throw new Error('Unsafe output');
      results.push({name, dark, ...result});
    }
  }
  for (const source of ['not a diagram', 'x'.repeat(65537), '%%{init: {"securityLevel":"loose"}}%%\nflowchart LR\nA-->B', '---\nconfig: {}\n---\nflowchart LR\nA-->B']) {
    let rejected = false;
    try { await window.ssmvRender(source); } catch { rejected = true; }
    if (!rejected) throw new Error('Unsafe/invalid input accepted');
  }
  // A failed input must not poison the next diagram.
  await window.ssmvRender(fixtures.flowchart);
  return {passed: results.length + 5, diagrams: results};
}
