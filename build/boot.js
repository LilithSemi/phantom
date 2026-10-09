import { createHost } from "@runtime_import@";

const host = createHost();
let instance;

// HTTP. The wasm side writes an ordinary HTTP/1.1 request into what
// it believes is a socket and then blocks reading the reply, so this
// import is the one call in the whole page that has to not return
// until the answer is in.
//
// JSPI is how that is done without freezing anything: the wasm stack
// parks and the page keeps drawing. Without it the only way to block
// is a synchronous XMLHttpRequest, which does freeze the page for the
// length of the request. Both fill the same struct and the wasm side
// cannot tell which one answered.
//
// Gecko is skipped. Firefox 155 and 156 crash the content process on any
// call through `WebAssembly.promising`, even into a function that does
// nothing. `mozInnerScreenX` exists only in Gecko.
const gecko = "mozInnerScreenX" in window;
const jspi =
  !gecko &&
  typeof WebAssembly.Suspending === "function" &&
  typeof WebAssembly.promising === "function";

const dec = new TextDecoder();
const enc = new TextEncoder();
const mem = () => instance.exports.memory.buffer;
const str = (ptr, len) => (len === 0 ? "" : dec.decode(new Uint8Array(mem(), ptr, len)));

// Headers a browser owns. Setting one throws, and the browser fills
// every one of them itself, so they are dropped rather than passed on.
const forbidden = new Set([
  "host", "connection", "content-length", "transfer-encoding",
  "upgrade", "keep-alive", "te", "trailer",
]);
const parseHeaders = (block) => {
  const out = {};
  for (const line of block.split("\r\n")) {
    const i = line.indexOf(":");
    if (i <= 0) continue;
    const name = line.slice(0, i).trim().toLowerCase();
    if (forbidden.has(name)) continue;
    out[name] = line.slice(i + 1).trim();
  }
  return out;
};

// Copy a string into the module's own heap and hand back its address.
// The wasm side frees both of these, so they must come from the same
// allocator the runtime uses.
const give = (s) => {
  const bytes = enc.encode(s);
  if (bytes.length === 0) return [0, 0];
  const ptr = instance.exports.webidl_rt_alloc(bytes.length);
  if (ptr === 0) return [0, 0];
  new Uint8Array(mem(), ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
};
// Server-sent events. What a stream receives waits in `pending` until
// the next frame hands it over, so an event never lands in the middle
// of a build.
const sources = new Map();
const pending = [];
const openSource = (id, urlPtr, urlLen, typesPtr, typesLen) => {
  let es;
  try {
    es = new EventSource(str(urlPtr, urlLen));
  } catch (e) {
    console.warn("phantom: the event source could not open", e);
    return 0;
  }
  const push = (kind, e) =>
    pending.push([id, kind, e?.type ?? "", e?.data ?? "", e?.lastEventId ?? ""]);
  es.onopen = () => push(0);
  es.onmessage = (e) => push(1, e);
  const types = str(typesPtr, typesLen);
  // `onmessage` already receives "message", so listing it again would deliver
  // each default event twice.
  if (types) for (const t of types.split("\n")) {
    if (t !== "message") es.addEventListener(t, (e) => push(1, e));
  }
  es.onerror = () => push(es.readyState === EventSource.CLOSED ? 3 : 2);
  sources.set(id, es);
  return 1;
};
const closeSource = (id) => {
  sources.get(id)?.close();
  sources.delete(id);
};

// Five u32s: status, headers ptr and len, body ptr and len. Written
// last, after every allocation, because allocating can grow the heap
// and detach any view made before it.
const reply = (out, status, headers, body) => {
  const h = give(headers);
  const b = give(body);
  new Uint32Array(mem(), out, 5).set([status, h[0], h[1], b[0], b[1]]);
  return 1;
};

// A request that a Content Security Policy refused and a network that is
// simply down reject a fetch the same way, with an opaque TypeError, and
// both reach the application as "the request did not happen". The most
// common cause of the first is a redirect to ANOTHER ORIGIN, which the
// browser follows and `connect-src` then refuses, so the application is
// told the network failed when what really happened is that the server
// redirected somewhere the page is not allowed to go.
//
// The browser does say which it was, just not through the fetch: it fires
// `securitypolicyviolation`. Recording the last one lets the failure path
// name the real cause, with the URI that was refused.
let lastViolation = null;
document.addEventListener("securitypolicyviolation", (e) => {
  lastViolation = {
    uri: e.blockedURI,
    directive: e.effectiveDirective || e.violatedDirective,
    at: performance.now(),
  };
});
const explainFailure = (method, url, startedAt) => {
  const v = lastViolation;
  if (!v || v.at < startedAt) return;
  // `blockedURI` is NOT always the address that was refused, and the case
  // where it is not is the case this whole message exists for.
  //
  // A refusal inside a redirect the browser followed is reported by
  // Firefox as the ORIGINAL request url, because naming the target would
  // hand a cross-origin address to a page that was just forbidden from
  // seeing it. Other browsers withhold it as "" or as a keyword. Printing
  // it verbatim in the first case says the page's policy refused the
  // page's own same-origin url, which sends a reader off to check a
  // `connect-src 'self'` that is perfectly correct: exactly the wasted
  // afternoon this line is here to prevent.
  //
  // Matching it against what was actually asked for is what tells the two
  // apart. Equal means the browser substituted, so it disclosed nothing.
  let asked = url;
  try {
    asked = new URL(url, location.href).href;
  } catch {}
  const disclosed =
    v.uri && v.uri !== "inline" && v.uri !== "eval" && v.uri !== asked;
  const what = disclosed
    ? "refused " + v.uri
    : "refused it without saying where: a browser names the request's own " +
      "address, or none at all, when it will not disclose where a redirect led";
  console.error(
    "phantom: " + method + " " + url + " did not fail on the network. This " +
    "page's Content-Security-Policy " + what + " (" + v.directive +
    "). A redirect to another origin is the usual cause. Your application " +
    "sees this as a transport failure, because fetch does not tell the two " +
    "apart; a route whose redirect IS the answer has to be navigated to " +
    "rather than requested.",
  );
};

const sendAsync = async (mp, ml, up, ul, hp, hl, bp, bl, out) => {
  const method = str(mp, ml), url = str(up, ul);
  const headers = parseHeaders(str(hp, hl));
  const body = bl === 0 ? undefined : str(bp, bl);
  const startedAt = performance.now();
  try {
    // same-origin sends the page's cookies, which is what a session
    // rides on. manual leaves a redirect visible as a status instead
    // of following it into an opaque response nothing can read.
    //
    // "manual" was tried and is WORSE than following. The spec makes
    // it an opaque-redirect response: status 0, no headers, no body.
    // So a 303 would reach the wasm as `HTTP/1.1 0` with nothing in
    // it, which is less use than the page the redirect led to. The
    // browser follows it instead, which also means the client's own
    // redirect handling never sees a 3xx and never engages.
    //
    // WHAT AN APPLICATION LOSES: it cannot see that a redirect happened
    // at all, only where it ended up. A route whose 3xx IS the answer, a
    // sign-in that answers 303 to an identity provider, cannot be driven
    // through the client and has to be reached by navigating instead.
    const res = await fetch(url, {
      method, headers, body,
      credentials: "same-origin",
      redirect: "follow",
    });
    return reply(out, res.status, headerBlock(res.headers), await res.text());
  } catch {
    // The request never happened. Zero here is NOT a status: the wasm
    // side reads it as "nothing answered", which is a different thing
    // to report than any reply a server could send.
    explainFailure(method, url, startedAt);
    return 0;
  }
};
const headerBlock = (h) => {
  let s = "";
  for (const [k, v] of h) s += k + ": " + v + "\r\n";
  return s;
};

const sendSync = (mp, ml, up, ul, hp, hl, bp, bl, out) => {
  const method = str(mp, ml), url = str(up, ul);
  const headers = parseHeaders(str(hp, hl));
  const body = bl === 0 ? null : str(bp, bl);
  const startedAt = performance.now();
  try {
    const xhr = new XMLHttpRequest();
    xhr.open(method, url, false);
    xhr.withCredentials = true;
    for (const k of Object.keys(headers)) xhr.setRequestHeader(k, headers[k]);
    xhr.send(body);
    return reply(out, xhr.status, xhr.getAllResponseHeaders(), xhr.responseText);
  } catch {
    explainFailure(method, url, startedAt);
    return 0;
  }
};

// Styling, through the CSSOM. A `style` ATTRIBUTE and the TEXT of a
// `<style>` element are both markup, and a Content Security Policy without
// `'unsafe-inline'` refuses both, which blanks a page that positions every
// node with one. Assignment through `element.style` is not refused: the
// policy's `script-src` already decided whether script runs at all, so a
// script reaching the CSSOM adds nothing an attacker did not already have.
//
// The declaration is split here rather than in wasm so that a node still
// costs ONE crossing, exactly as the attribute did, instead of one per
// property. Splitting on ";" is safe for what this backend emits: colours
// are `rgba(1,2,3,0.5)`, which carries commas and never a semicolon.
const setStyle = (node, ptr, len) => {
  const el = host.value(node);
  // Never silently: a node that cannot be styled is a node drawn at the
  // wrong place, or not drawn at all, and a page of those with nothing in
  // the console is the hardest kind of wrong to chase.
  if (!el) {
    console.warn("phantom: no element for handle " + node + ", so its style was dropped");
    return;
  }
  for (const part of str(ptr, len).split(";")) {
    const i = part.indexOf(":");
    if (i <= 0) continue;
    el.style.setProperty(part.slice(0, i).trim(), part.slice(i + 1).trim());
  }
};

// Rules go into a CONSTRUCTABLE sheet, one the document adopts, and never
// into a `<style>` element.
//
// A style element cannot be used under a strict policy at all. It is
// markup, so `style-src 'self'` refuses the ELEMENT the moment it enters
// the document, while it is still empty: a browser reports that against
// `style-src-elem` and names the hash of the empty string, which is what
// an empty style element hashes to. A refused element gets no `.sheet`,
// so putting rules in it through the CSSOM never runs either. That is
// how `@font-face` silently never applied and no font was ever fetched.
//
// A constructed sheet has no element, so there is nothing to refuse.
let pageSheet;
const sheet = () => {
  if (pageSheet !== undefined) return pageSheet;
  try {
    pageSheet = new CSSStyleSheet();
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, pageSheet];
  } catch (e) {
    // Null, not undefined, so this is attempted once rather than on every
    // frame. Hover and active states are lost; nothing else is.
    pageSheet = null;
    console.warn("phantom: no constructable stylesheet, so hover and active rules are dropped", e);
  }
  return pageSheet;
};

// A rule the browser will not parse throws rather than being ignored, and
// one bad rule must not cost the rest of the frame, so each is tried alone.
const addRule = (ptr, len) => {
  const s = sheet();
  if (!s) return;
  for (const rule of splitRules(str(ptr, len))) {
    try {
      s.insertRule(rule, s.cssRules.length);
    } catch (e) {
      console.warn("phantom: a style rule was refused: " + rule, e);
    }
  }
};

// A font, through `document.fonts`, with no stylesheet involved at all.
// The rules above need a sheet to live in; a face does not, and this is
// the one that must not fail quietly. A font that never registers means
// the browser substitutes another, and then the glyphs on screen and the
// rectangles taps are tested against describe two different pages.
const addFont = (fp, fl, sp, sl) => {
  const family = str(fp, fl);
  try {
    const face = new FontFace(family, str(sp, sl));
    document.fonts.add(face);
    // Fetched now rather than when some text first wants it, so a failure
    // is reported once, here, instead of appearing later as the wrong
    // letterforms.
    face.load().catch((e) => console.warn("phantom: the font " + family + " did not load", e));
  } catch (e) {
    console.warn("phantom: the font " + family + " could not be registered", e);
  }
};
// One rule per `}` at nesting depth zero. `@font-face { ... }` and
// `.pb0:hover { ... }` both come through here, so a plain split on "}"
// would cut an at-rule in half.
const splitRules = (css) => {
  const out = [];
  let depth = 0, start = 0;
  for (let i = 0; i < css.length; i++) {
    if (css[i] === "{") depth++;
    else if (css[i] === "}" && --depth === 0) {
      const rule = css.slice(start, i + 1).trim();
      if (rule) out.push(rule);
      start = i + 1;
    }
  }
  return out;
};

const imports = {
  ...host.imports,
  phantom: {
    __phantom_http_send: jspi ? new WebAssembly.Suspending(sendAsync) : sendSync,
    __phantom_set_style: setStyle,
    __phantom_add_rule: addRule,
    __phantom_add_font: addFont,
    __phantom_event_source_open: openSource,
    __phantom_event_source_close: closeSource,
  },
};
({ instance } = await WebAssembly.instantiateStreaming(fetch("./@wasm_name@.wasm"), imports));
host.attach(instance);

// Under JSPI an export that can reach a suspending import has to be
// wrapped, and it then returns a promise. Everything that can run
// application code can reach one, so all of them are wrapped.
const wrap = (f) => (jspi ? WebAssembly.promising(f) : f);
const ex = instance.exports;
const w = {
  init: wrap(ex.init), tick: wrap(ex.tick), resize: wrap(ex.resize),
  dispatchTap: wrap(ex.dispatchTap), dispatchKey: wrap(ex.dispatchKey),
  dispatchChar: wrap(ex.dispatchChar), dispatchText: wrap(ex.dispatchText),
  locationChanged: wrap(ex.locationChanged), serverEvent: wrap(ex.serverEvent),
};

// True while the tree is on the stack, which under JSPI includes the
// whole time a request is parked. Re-entering it there would build and
// paint from inside a half-finished frame, so events that arrive
// meanwhile are dropped. The synchronous path cannot deliver an event
// mid-call at all, so this costs it nothing.
let busy = false;
const enter = async (f) => {
  if (busy) return 0;
  busy = true;
  try { return await f(); } finally { busy = false; }
};

const documentHandle = host.intern(document);
const bodyHandle = host.intern(document.body);
const windowHandle = host.intern(window);
const app = await w.init(documentHandle, bodyHandle, windowHandle);
document.body.addEventListener("click", (e) => enter(() => w.dispatchTap(app, e.clientX, e.clientY)));

// The keyboard. These numbers are X11 keysyms, which is what
// phantom.input.Keysym holds: the wasm side takes each one as it is, so
// this table is the whole keymap. A pair is [left, right].
const KEYSYMS = {
  Backspace: 0xff08, Tab: 0xff09, Enter: 0xff0d, Escape: 0xff1b,
  Home: 0xff50, ArrowLeft: 0xff51, ArrowUp: 0xff52, ArrowRight: 0xff53,
  ArrowDown: 0xff54, PageUp: 0xff55, PageDown: 0xff56, End: 0xff57,
  Insert: 0xff63, Delete: 0xffff,
  F1: 0xffbe, F2: 0xffbf, F3: 0xffc0, F4: 0xffc1, F5: 0xffc2, F6: 0xffc3,
  F7: 0xffc4, F8: 0xffc5, F9: 0xffc6, F10: 0xffc7, F11: 0xffc8, F12: 0xffc9,
  Shift: [0xffe1, 0xffe2], Control: [0xffe3, 0xffe4],
  Alt: [0xffe9, 0xffea], Meta: [0xffeb, 0xffec],
};
const keysymOf = (e) => {
  const sym = KEYSYMS[e.key];
  if (sym === undefined) return undefined;
  // DOM_KEY_LOCATION_RIGHT is 2, which is the right hand key of a pair.
  return Array.isArray(sym) ? sym[e.location === 2 ? 1 : 0] : sym;
};
const modsOf = (e) =>
  (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
const onKey = (e, action) => {
  // An IME owns the keys that compose a word. They arrive here as well,
  // and typing them would put the raw keys next to the word the IME
  // commits. keyCode 229 is what a browser sends while composing.
  if (e.isComposing || e.keyCode === 229) return;
  const sym = keysymOf(e);
  // preventDefault has to be called during the event, and under JSPI
  // the dispatch answers with a promise, so its answer arrives too
  // late to decide with. `focusHeld` is the synchronous stand-in: a
  // tree holding the keyboard is a tree the key belongs to, which is
  // the same rule a browser applies to a focused input. Tab is added
  // because it enters the tree even when nothing is focused yet.
  const claimed = jspi
    ? ex.focusHeld(app) !== 0 || e.key === "Tab"
    : null;
  let used;
  if (sym !== undefined) {
    used = w.dispatchKey(app, sym, modsOf(e), action);
  } else {
    // Everything else that is one character long is printable. `key`
    // holds the character the layout and the shift state resolved to.
    const chars = [...e.key];
    if (chars.length !== 1) return;
    used = w.dispatchChar(app, chars[0].codePointAt(0), modsOf(e), action);
  }
  if (claimed === null ? used : claimed) e.preventDefault();
};
window.addEventListener("keydown", (e) => enter(() => onKey(e, e.repeat ? 1 : 0)));
window.addEventListener("keyup", (e) => enter(() => onKey(e, 2)));

// A whole string at once. The wasm side owns the bytes, so it hands back
// an address to write them into. Read `memory.buffer` AFTER that call:
// growing the heap detaches the ArrayBuffer that was there before.
const sendText = (text) => {
  if (!text) return false;
  const bytes = new TextEncoder().encode(text);
  const ptr = ex.textBuffer(bytes.length);
  if (ptr === 0) return false;
  new Uint8Array(mem(), ptr, bytes.length).set(bytes);
  return w.dispatchText(app, ptr, bytes.length);
};
// A paste fires no keydown at all. An invite code, a password or a URL is
// pasted far more often than it is typed, so a page that only reads keys
// looks broken rather than unfinished.
window.addEventListener("paste", (e) => {
  // No clipboardData at all on a paste a browser will not let a page
  // read. `sendText` refuses the empty string, so both end the same way.
  // A paste is always the tree's to take when a field holds the
  // keyboard, and the answer under JSPI arrives too late to ask.
  if (ex.focusHeld(app) !== 0) e.preventDefault();
  enter(() => sendText(e.clipboardData?.getData("text")));
});
// The IME commits its finished word here, after the keys that composed it
// went to the IME and never reached the page.
window.addEventListener("compositionend", (e) => enter(() => sendText(e.data)));

// The back/forward buttons move the address bar and then fire this,
// with no string to pass in: the wasm side reads the new location
// back itself, so the JS host never allocates inside the module.
window.addEventListener("popstate", () => enter(() => w.locationChanged(app)));
const onResize = () => enter(() => w.resize(app, window.innerWidth, window.innerHeight, window.devicePixelRatio));
window.addEventListener("resize", onResize);
matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`).addEventListener("change", onResize);
// t is the rAF timestamp: monotonic, same origin as performance.now.
// Date.now is the wall clock and can step backwards. They are passed
// separately because the scheduler must never arm against the second.
// A stream closed while its events waited drops them here. The wasm side
// checks the id again, because a sink can close a stream mid-drain.
const drainEvents = async () => {
  while (pending.length > 0) {
    const [id, kind, type, data, lastId] = pending.shift();
    if (!sources.has(id)) continue;
    const ty = give(type);
    const da = give(data);
    const li = give(lastId);
    await w.serverEvent(app, id, kind, ty[0], ty[1], da[0], da[1], li[0], li[1]);
  }
};
const frame = (t) => {
  enter(async () => {
    await drainEvents();
    return w.tick(app, Date.now(), t);
  });
  requestAnimationFrame(frame);
};
requestAnimationFrame(frame);