import mermaid from './mermaid.esm.min.mjs';

// This page has no document file/network access. Hosts allow only bundled assets
// and enforce a deadline by disposing the web view on cancellation or timeout.
let active = false;
window.ssmvRender = async function (source, dark = false) {
  if (active) throw new Error('A diagram is already rendering.');
  if (typeof source !== 'string' || new TextEncoder().encode(source).length > 65536)
    throw new Error('Diagram exceeds the 64 KiB limit.');
  // Document-controlled configuration can override resource and security limits.
  if (/%%\s*\{/.test(source) || /^\s*---(?:\r?\n|$)/.test(source))
    throw new Error('Diagram configuration directives are not supported.');
  active = true;
  const host = document.getElementById('diagram');
  host.replaceChildren();
  document.body.style.background = dark ? '#1e1e1e' : '#ffffff';
  try {
    if (source.includes('$$')) {
      await Promise.race([Promise.all([...document.fonts].map(font => font.load())),
        new Promise(resolve => setTimeout(resolve, 2000))]);
    }
    mermaid.initialize({
      startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
      maxTextSize: 65536, maxEdges: 500, theme: dark ? 'dark' : 'default',
      legacyMathML: true,
      fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      // Native capture preserves HTML line breaks and KaTeX labels without
      // SVG-to-canvas restrictions. CSP blocks all external resources.
      htmlLabels: true, flowchart: { htmlLabels: true, useMaxWidth: false, wrappingWidth: 420 },
    });
    const { svg } = await mermaid.render('ssmv-diagram', source);
    // Mermaid HTML labels contain HTML void elements such as <br>; parse in
    // an inert template rather than an XML parser that rejects those labels.
    const template = document.createElement('template');
    template.innerHTML = svg;
    const root = template.content.querySelector('svg');
    if (!root) throw new Error('Invalid diagram output.');
    // Defense in depth beyond strict Mermaid sanitization and the page CSP.
    root.querySelectorAll('script, iframe, object, embed, image').forEach(el => el.remove());
    for (const el of [root, ...root.querySelectorAll('*')]) {
      for (const attribute of [...el.attributes]) {
        if (/^on/i.test(attribute.name)) el.removeAttributeNode(attribute);
        else if (['href', 'xlink:href', 'src'].includes(attribute.name) && !attribute.value.startsWith('#'))
          el.removeAttributeNode(attribute);
      }
    }
    const viewBox = root.viewBox.baseVal;
    const width = Math.ceil(viewBox.width || Number.parseFloat(root.getAttribute('width')));
    const height = Math.ceil(viewBox.height || Number.parseFloat(root.getAttribute('height')));
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 || width > 2032 || height > 4080 || width * height > 4_000_000)
      throw new Error('Diagram exceeds the image size limit.');
    root.setAttribute('width', String(width));
    root.setAttribute('height', String(height));
    host.append(document.importNode(root, true));
    await Promise.race([document.fonts.ready, new Promise(resolve => setTimeout(resolve, 2000))]);
    // Offscreen web views may throttle animation frames; the native host also
    // waits for layout before capture, so never depend on a visible browser.
    await new Promise(resolve => {
      setTimeout(resolve, 100);
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    });
    return { width: width + 16, height: height + 16 };
  } catch (error) {
    host.replaceChildren();
    throw error;
  } finally { active = false; }
};
